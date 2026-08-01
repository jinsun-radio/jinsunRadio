import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend_client.dart';
import 'event_notifications.dart';
import 'models.dart';
import 'row_mappers.dart';
import 'supabase_config.dart';

/// 真後端：三端共用同一份 Supabase 資料，透過 Realtime 即時同步。
/// 實作與 MockBackend 相同的 [BackendClient] 介面，App 換後端不改 UI。
class SupabaseBackend extends BackendClient {
  SupabaseBackend({
    this.escalateAfter = const Duration(seconds: 20),
    this.dispatchWatchdog = false,
  }) {
    _init();
    // 派遣中心（社工後台）才開「卡單自動改派」看門狗：定期掃描緊急單，逾時未接就
    // 改派更近的人並廣播請支援。只由單一權威端執行，避免多端重複改派互踩。
    if (dispatchWatchdog) {
      _timers['watchdog'] = Timer.periodic(
          const Duration(seconds: 20), (_) => _reassignStaleEmergencies());
    }
  }

  final Duration escalateAfter;
  // true＝本端負責緊急單卡單自動改派（僅社工後台 admin 設為 true）。
  final bool dispatchWatchdog;
  final SupabaseClient _sb = JinsunSupabase.client;

  final List<Elder> _elders = [];
  final List<RadioEvent> _events = [];
  final List<DispatchTask> _tasks = [];
  final List<SocialWorker> _workers = [];
  final List<Volunteer> _volunteers = [];
  final List<TaskMessage> _messages = [];
  int _points = 0;

  final _eldersCtrl = StreamController<List<Elder>>.broadcast();
  final _eventsCtrl = StreamController<List<RadioEvent>>.broadcast();
  final _tasksCtrl = StreamController<List<DispatchTask>>.broadcast();
  final _volCtrl = StreamController<List<Volunteer>>.broadcast();
  final _msgCtrl = StreamController<List<TaskMessage>>.broadcast();
  final _notifCtrl = StreamController<AppNotification>.broadcast();
  final _pointsCtrl = StreamController<int>.broadcast();
  final _callCtrl = StreamController<CallSignal>.broadcast();
  final List<RealtimeChannel> _channels = [];
  // 即時訊號廣播頻道（Broadcast，client→client 次秒級）：來電號誌與聊天訊息走這裡，
  // 比 Postgres Changes（WAL 回放，1~3 秒且行動網路更慢）即時得多；DB 仍照寫做保存。
  RealtimeChannel? _signalCh;
  final Map<String, Timer> _timers = {};
  int _idSeq = 0;

  // 通知去重：Realtime 帶進來的變化（任何來源：硬體模擬 / cloud server / 其它端）
  // 都要讓本端跳通知。初次載入不通知（否則開 App 就洗版）。
  bool _eventsSeeded = false;
  final Set<String> _knownEventIds = {};
  bool _tasksSeeded = false;
  final Map<String, DispatchStatus> _knownTaskStatus = {};

  @override
  Stream<List<Elder>> get elders => _eldersCtrl.stream;
  @override
  Stream<List<RadioEvent>> get events => _eventsCtrl.stream;
  @override
  Stream<List<DispatchTask>> get tasks => _tasksCtrl.stream;
  @override
  Stream<List<Volunteer>> get volunteers => _volCtrl.stream;
  @override
  Stream<List<TaskMessage>> get messages => _msgCtrl.stream;
  @override
  Stream<AppNotification> get notifications => _notifCtrl.stream;
  @override
  Stream<int> get timeBankPoints => _pointsCtrl.stream;
  @override
  Stream<CallSignal> get callSignals => _callCtrl.stream;

  @override
  List<Elder> get currentElders => List.unmodifiable(_elders);
  @override
  List<RadioEvent> get currentEvents => List.unmodifiable(_events);
  @override
  List<DispatchTask> get currentTasks => List.unmodifiable(_tasks);
  @override
  List<SocialWorker> get currentWorkers => List.unmodifiable(_workers);
  @override
  List<Volunteer> get currentVolunteers => List.unmodifiable(_volunteers);
  @override
  List<TaskMessage> get currentMessages => List.unmodifiable(_messages);
  @override
  int get currentTimeBankPoints => _points;

  // ---------- 初始化：載入 + Realtime 訂閱 ----------
  Future<void> _init() async {
    await Future.wait([
      _loadElders(),
      _loadEvents(),
      _loadTasks(),
      _loadWorkers(),
      _loadVolunteers(),
      _loadMessages(),
    ]);
    for (final table in [
      'elders',
      'radio_events',
      'dispatch_tasks',
      'volunteers',
      'task_messages'
    ]) {
      final ch = _sb
          .channel('public:$table')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => _onChange(table),
          )
          // 每次「（重新）訂閱成功」就補抓一次：Realtime 不會重播斷線期間漏掉的
          // INSERT/UPDATE（背景分頁、弱網、切前景都會斷線），靠這個把漏掉的派遣單補進來。
          .subscribe((status, [error]) {
            if (status == RealtimeSubscribeStatus.subscribed) _onChange(table);
          });
      _channels.add(ch);
    }
    // 保險輪詢：就算 Realtime 因背景分頁／弱網漏了事件，最多 8 秒也會補到最新的
    // 事件／派遣單／志工位置，避免「推播收到了、介面卻要等好幾分鐘才出現任務」。
    _timers['poll'] = Timer.periodic(const Duration(seconds: 8), (_) {
      _loadEvents();
      _loadTasks();
      _loadVolunteers();
    });
    // 通話號誌：需要「那一列」的內容（room/from/to/status），用 payload 直接推。
    final callCh = _sb
        .channel('public:call_signals')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'call_signals',
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isNotEmpty) _callCtrl.add(_callFrom(row));
          },
        )
        .subscribe();
    _channels.add(callCh);

    // 即時廣播頻道：來電（call）與聊天訊息（msg）走 Broadcast，收訊端次秒級收到。
    _signalCh = _sb.channel('jinsun-signal');
    _signalCh!
        .onBroadcast(
            event: 'call',
            callback: (payload) {
              try {
                _callCtrl.add(_callFrom(Map<String, dynamic>.from(payload)));
              } catch (_) {}
            })
        .onBroadcast(
            event: 'msg',
            callback: (payload) {
              try {
                _appendMessage(Map<String, dynamic>.from(payload));
              } catch (_) {}
            })
        // 雲端派遣層寫完事件／派遣單後，會用這個 'sync' 廣播（次秒級）通知三端「哪幾張表變了」，
        // 收到就立刻重抓，不必等 1~3 秒的 Postgres Changes → 收音機一觸發、網頁 2 秒內亮任務單。
        .onBroadcast(
            event: 'sync',
            callback: (payload) {
              try {
                final tables = (payload['tables'] as List?)?.cast<String>() ??
                    const ['radio_events', 'dispatch_tasks', 'elders'];
                for (final t in tables) {
                  _onChange(t);
                }
              } catch (_) {}
            })
        .subscribe();
    _channels.add(_signalCh!);
  }

  /// 把一則訊息 row 併入本地訊息（依 id 去重，時間排序）。broadcast/樂觀顯示共用。
  void _appendMessage(Map<String, dynamic> row) {
    final m = _messageFrom(row);
    if (_messages.any((e) => e.id == m.id)) return;
    _messages
      ..add(m)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _msgCtrl.add(currentMessages);
  }

  /// 發一則即時廣播（fire-and-forget，失敗不影響 DB 保存）。
  Future<void> _broadcastRow(String event, Map<String, dynamic> row) async {
    try {
      await _signalCh?.sendBroadcastMessage(
          event: event, payload: Map<String, dynamic>.from(row));
    } catch (_) {}
  }

  void _onChange(String table) {
    switch (table) {
      case 'elders':
        _loadElders();
      case 'radio_events':
        _loadEvents();
      case 'dispatch_tasks':
        _loadTasks();
      case 'volunteers':
        _loadVolunteers();
      case 'task_messages':
        _loadMessages();
    }
  }

  Future<void> _loadElders() async {
    final rows = await _sb.from('elders').select().order('id');
    _elders
      ..clear()
      ..addAll(rows.map(_elderFrom));
    _eldersCtrl.add(currentElders);
  }

  Future<void> _loadEvents() async {
    final rows = await _sb
        .from('radio_events')
        .select()
        .order('occurred_at', ascending: false)
        .limit(2000);
    final list = rows.map(_eventFrom).toList();
    // 對「Realtime 帶進來的新事件」跳通知（初次載入不跳）。由舊到新，順序自然。
    if (_eventsSeeded) {
      for (final e in list.reversed) {
        if (!_knownEventIds.contains(e.id)) _notifyForEvent(e);
      }
    }
    for (final e in list) {
      _knownEventIds.add(e.id);
    }
    _eventsSeeded = true;
    _events
      ..clear()
      ..addAll(list);
    _eventsCtrl.add(currentEvents);
  }

  Future<void> _loadTasks() async {
    final rows = await _sb
        .from('dispatch_tasks')
        .select()
        .order('created_at', ascending: false)
        .limit(2000);
    final list = rows.map(_taskFrom).toList();
    if (_tasksSeeded) {
      for (final t in list.reversed) {
        final prev = _knownTaskStatus[t.id];
        if (prev == null) {
          _notifyForNewTask(t);
        } else if (prev != t.status) {
          _notifyForTaskTransition(t);
        }
      }
    }
    for (final t in list) {
      _knownTaskStatus[t.id] = t.status;
    }
    _tasksSeeded = true;
    _tasks
      ..clear()
      ..addAll(list);
    _tasksCtrl.add(currentTasks);
  }

  // ---- 依 DB 變化跳通知（三端一致，不管事件由誰觸發）----
  // 文案與分級的規則在 event_notifications.dart，與 AwsBackend 共用同一份。
  void _notifyForEvent(RadioEvent e) {
    final n = notificationForEvent(e, _elderName(e.elderId));
    if (n != null) _notify(n.message, n.severity, elderId: e.elderId);
  }

  void _notifyForNewTask(DispatchTask t) {
    final n = notificationForNewTask(t, _elderName(t.elderId));
    _notify(n.message, n.severity, elderId: t.elderId);
  }

  void _notifyForTaskTransition(DispatchTask t) {
    final n = notificationForTaskTransition(t, _elderName(t.elderId));
    if (n != null) _notify(n.message, n.severity, elderId: t.elderId);
  }

  Future<void> _loadWorkers() async {
    final rows = await _sb.from('social_workers').select().order('id');
    _workers
      ..clear()
      ..addAll(rows.map(workerFromRow));
  }

  @override
  Future<void> submitCertificate(String volunteerName, CertKind kind,
      {DateTime? issuedAt, DateTime? expiresAt, String? note}) async {
    final vi = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (vi < 0) return;
    final vid = _volunteers[vi].id;
    final payload = <String, dynamic>{
      'volunteer_id': vid,
      'kind': kind.wire,
      'status': CertStatus.pending.wire,
      'note': note ?? '已送出，等待社工審核',
      if (issuedAt != null) 'issued_at': issuedAt.toIso8601String(),
      if (expiresAt != null) 'expires_at': expiresAt.toIso8601String(),
    };
    // 不依賴 (volunteer_id,kind) 唯一約束：先查有沒有、有就 update、沒有才 insert。
    final existing = await _sb
        .from('volunteer_certificates')
        .select('volunteer_id')
        .eq('volunteer_id', vid)
        .eq('kind', kind.wire)
        .maybeSingle();
    if (existing != null) {
      await _sb
          .from('volunteer_certificates')
          .update(payload)
          .eq('volunteer_id', vid)
          .eq('kind', kind.wire);
    } else {
      await _sb.from('volunteer_certificates').insert(payload);
    }
    await _loadVolunteers(); // 重新載入 → volunteers 串流回推，證件頁狀態變「審核中」
  }

  Future<void> _loadVolunteers() async {
    // 志工基本資料 + 證件（另一張表，依 volunteer_id 分組後掛回）
    final rows = await _sb.from('volunteers').select().order('id');
    final certsByVol = <String, List<VolunteerCertificate>>{};
    try {
      final certRows = await _sb.from('volunteer_certificates').select();
      for (final c in certRows) {
        final vid = (c['volunteer_id'] ?? '') as String;
        (certsByVol[vid] ??= []).add(certificateFromRow(c));
      }
    } catch (_) {
      // 表不存在時（尚未套用新 schema）不擋 App，證件顯示為空。
    }
    _volunteers
      ..clear()
      ..addAll(rows.map((r) =>
          volunteerFromRow(r, certificates: certsByVol[r['id']] ?? const [])));
    _volCtrl.add(currentVolunteers);
  }

  Future<void> _loadMessages() async {
    final rows = await _sb
        .from('task_messages')
        .select()
        .order('created_at')
        .limit(500);
    _messages
      ..clear()
      ..addAll(rows.map(_messageFrom));
    _msgCtrl.add(currentMessages);
  }

  TaskMessage _messageFrom(Map<String, dynamic> r) => messageFromRow(r);

  @override
  Future<void> sendTaskMessage(String taskId,
      {required ChatFromRole from, String? senderId, required String text}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final row = await _sb.from('task_messages').insert({
      'task_id': taskId,
      'from_role': from.name,
      'sender_id': ?senderId,
      'text': t,
    }).select().single();
    // 送出者本端樂觀顯示 + 廣播給對方（次秒級）；Postgres Changes 之後再校準。
    _appendMessage(row);
    await _broadcastRow('msg', row);
    // 不提供刪除＝送出無法收回。
  }

  @override
  Future<String> transcribeAudio(Uint8List audioBytes,
      {required String filename, String? mimeType, String? prompt}) async {
    if (audioBytes.isEmpty) return '';
    // 走 Supabase Edge Function 代理（見 cloud/supabase/functions/whisper）：
    // 金鑰只存後端 secret，前端只送音檔 base64。
    final res = await _sb.functions.invoke('whisper', body: {
      'audio_base64': base64Encode(audioBytes),
      'filename': filename,
      'mime': ?mimeType,
      'prompt': ?prompt,
      'language': 'zh',
    });
    final data = res.data;
    if (data is Map && data['text'] is String) {
      return (data['text'] as String).trim();
    }
    if (data is Map && data['error'] != null) {
      final detail = data['detail'];
      throw Exception(
          'Whisper 轉寫失敗：${data['error']}${detail != null ? '（$detail）' : ''}');
    }
    return '';
  }

  // ---------- 派遣人力 ----------
  @override
  int workerLoad(String workerName) => _tasks
      .where((t) =>
          t.workerName == workerName && t.status != DispatchStatus.resolved)
      .length;

  SocialWorker? _pickWorker(DateTime now) {
    if (_workers.isEmpty) return null;
    final onDuty = _workers.where((w) => w.onDuty(now)).toList();
    final pool = onDuty.isNotEmpty ? onDuty : List.of(_workers);
    pool.sort((a, b) => workerLoad(a.name).compareTo(workerLoad(b.name)));
    return pool.first;
  }

  // ---------- 收音機事件（demo 面板；正式由硬體 HTTP POST）----------
  @override
  void triggerFallSuspected(String elderId) {
    _insertEvent(elderId, 'fall_suspected', 'attention',
            note: '疑似跌倒，收音機語音確認中')
        .then((eventId) {
      if (eventId == null) return;
      _timers['esc-$eventId'] = Timer(escalateAfter, () {
        _timers.remove('esc-$eventId');
        _escalate(eventId, elderId);
      });
    });
  }

  @override
  void triggerSos(String elderId) {
    _insertEvent(elderId, 'sos', 'emergency', status: 'escalated', note: '按下 SOS')
        .then((eventId) {
      if (eventId != null) _createTask(elderId, eventId, 'emergency');
    });
  }

  @override
  void triggerSupplyRequest(String elderId, List<String> items) {
    _insertEvent(elderId, 'supply_request', 'normal',
            transcript: '我想買${items.join('跟')}', note: '物資需求')
        .then((eventId) {
      if (eventId != null) _createTask(elderId, eventId, 'supply', items: items);
    });
  }

  @override
  void confirmElderOk(String elderId) async {
    // 找「這位長輩」最近一筆 open 的跌倒事件 → 標記解除。
    // 找不到就什麼都不做——絕不 orElse 抓「全域最新一筆」，否則會把別的長輩／別型別的事件
    // 誤標成 confirmed_ok，還把本長輩硬降回 normal。
    RadioEvent? open;
    for (final e in _events) {
      if (e.elderId == elderId &&
          e.type == RadioEventType.fallSuspected &&
          e.status == RadioEventStatus.open) {
        open = e; // _events 依 occurred_at 由新到舊，第一筆即最近
        break;
      }
    }
    if (open == null) return;
    _timers.remove('esc-${open.id}')?.cancel();
    await _sb
        .from('radio_events')
        .update({'status': 'confirmed_ok'}).eq('id', open.id);
    await _sb.from('elders').update({'severity': 'normal'}).eq('id', elderId);
    _notify('${_elderName(elderId)} 回應「我沒事」，事件解除', Severity.normal);
    // 🟡 回應無恙不代表沒事——記一筆趨勢，累積到門檻就自動轉督導追蹤。
    await _recordFallTrend(elderId, open.id);
  }

  /// 記一次「疑似跌倒但回應無恙」；7 天內達 3 次且尚無未結追蹤單 → 為督導開追蹤待辦。
  Future<void> _recordFallTrend(String elderId, String eventId) async {
    final now = DateTime.now();
    final hits = _fallTrend.putIfAbsent(elderId, () => <DateTime>[])
      ..add(now)
      ..removeWhere((t) => now.difference(t) > _followUpWindow);
    final hasOpen = _tasks.any((t) =>
        t.elderId == elderId &&
        t.kind == DispatchKind.followUp &&
        t.status != DispatchStatus.resolved);
    if (hits.length < _followUpThreshold || hasOpen) return;
    hits.clear();
    // 定向給督導本人（不派志工、不進搶單池），長輩燈號升「注意」讓後台置頂。
    final supervisor = _supervisorOf(elderId) ?? _pickWorker(now)?.name;
    await _sb.from('dispatch_tasks').insert({
      'elder_id': elderId,
      'event_id': eventId,
      'kind': 'follow_up',
      'status': 'pending',
      'worker_name': supervisor,
      'assignee_name': supervisor,
    });
    await _sb.from('elders').update({'severity': 'attention'}).eq('id', elderId);
    _notify(
        '${_elderName(elderId)} 近期多次疑似跌倒（均自行回應無恙），'
        '已為督導 ${supervisor ?? '個管'} 開立追蹤訪視待辦（非緊急、不派志工）',
        Severity.attention,
        elderId: elderId);
  }

  Future<String?> _insertEvent(String elderId, String type, String severity,
      {String status = 'open', String? transcript, String? note}) async {
    final row = await _sb
        .from('radio_events')
        .insert({
          'elder_id': elderId,
          'type': type,
          'status': status,
          'severity': severity,
          'transcript': ?transcript,
        })
        .select()
        .single();
    // 通知改由 Realtime 變化統一觸發（見 _notifyForEvent），這裡不再本地跳，避免重複。
    return row['id'] as String?;
  }

  Future<void> _escalate(String eventId, String elderId) async {
    // 升級前確認事件仍是 open：長輩可能已在別的端（收音機→server、或另一支 App）
    // 回應「我沒事」→ confirmed_ok。此時本端殘留的 20 秒計時器若照升，會把已解除的
    // 事件蓋回 escalated、開一張假的緊急派遣單。用條件式 UPDATE（status='open' 才改）
    // 原子地把「判斷＋升級」做完；沒有列被改到（已 confirmed_ok／closed／別端先升）就直接收手。
    final updated = await _sb
        .from('radio_events')
        .update({'status': 'escalated', 'severity': 'emergency'})
        .eq('id', eventId)
        .eq('status', 'open')
        .select('id');
    if (updated.isEmpty) return;
    await _sb.from('elders').update({'severity': 'emergency'}).eq('id', elderId);
    await _createTask(elderId, eventId, 'emergency');
  }

  Future<void> _createTask(String elderId, String eventId, String kind,
      {List<String> items = const []}) async {
    // 同長輩已有進行中同類單 → 不重複開
    final k = kind == 'supply' ? DispatchKind.supply : DispatchKind.emergency;
    final dup = _tasks.any((t) =>
        t.elderId == elderId &&
        t.kind == k &&
        t.status != DispatchStatus.resolved);
    if (dup) return;
    final worker = _pickWorker(DateTime.now());
    final row = <String, dynamic>{
      'elder_id': elderId,
      'event_id': eventId,
      'kind': kind,
      'status': 'pending',
      'worker_name': worker?.name,
      'items': items,
    };
    // 派單：物資單 3 分鐘寬限，先 offer 給督導志工＋通知家屬，不廣播全體；到期或
    // 「請求支援」才開放全體，家屬可先「我來處理」取消。緊急單依距離＋志工在辦任務量
    // 自動派單給最適合者（emergencyDispatchWindow 內未接再退回全體廣播）。
    if (k == DispatchKind.supply) {
      row['offered_until'] =
          DateTime.now().add(const Duration(minutes: 3)).toUtc().toIso8601String();
      final supervisor = _supervisorOf(elderId);
      if (supervisor != null) row['assignee_name'] = supervisor;
    } else {
      final elder = _elderCoords(elderId);
      final picked = elder == null
          ? null
          : pickVolunteer(_volunteers, elder.$1, elder.$2, _volunteerLoad);
      if (picked != null) {
        row['assignee_name'] = picked.name;
        row['offered_until'] = DateTime.now()
            .add(emergencyDispatchWindow)
            .toUtc()
            .toIso8601String();
      }
    }
    await _sb.from('dispatch_tasks').insert(row);
    // 新派遣單的通知由 Realtime 統一觸發（見 _notifyForNewTask）。
  }

  String? _supervisorOf(String elderId) {
    for (final e in _elders) {
      if (e.id == elderId) return e.supervisorVolunteerName;
    }
    return null;
  }

  /// 長輩座標 (lat, lng)；查無或未定位回 null（派單時退回全體廣播）。
  (double, double)? _elderCoords(String elderId) {
    for (final e in _elders) {
      if (e.id == elderId) {
        return (e.lat == 0 && e.lng == 0) ? null : (e.lat, e.lng);
      }
    }
    return null;
  }

  /// 某位志工目前手上未結案的任務數（含已派給他但未接的單），用於派單負載平衡。
  int _volunteerLoad(String name) => _tasks
      .where((t) => t.assigneeName == name && t.status != DispatchStatus.resolved)
      .length;

  String _elderAddress(String id) {
    for (final e in _elders) {
      if (e.id == id) return e.address;
    }
    return '';
  }

  // 卡單改派防抖：剛改派過的單，短時間內不重複處理（等 Realtime 回放）。
  final Map<String, DateTime> _reassignGuard = {};
  // 每張單試過的志工，改派時排除，避免又派回同一人。
  final Map<String, Set<String>> _triedAssignees = {};

  // 🟡 注意軌：每位長輩近期「疑似跌倒但回應無恙」時間戳；累積達門檻自動為督導開追蹤待辦。
  final Map<String, List<DateTime>> _fallTrend = {};
  static const _followUpThreshold = 3;
  static const _followUpWindow = Duration(days: 7);

  /// 看門狗：掃描「緊急・pending・offered_until 已過」的卡單，自動改派下一位更近者（排除已試過的人）；
  /// 沒有其他就近人選就交回社工協助指派——不開放全體。只在 dispatchWatchdog=true 端執行。
  Future<void> _reassignStaleEmergencies() async {
    final now = DateTime.now();
    for (final t in List<DispatchTask>.from(_tasks)) {
      if (t.kind != DispatchKind.emergency ||
          t.status != DispatchStatus.pending) {
        continue;
      }
      if (t.offeredUntil == null || now.isBefore(t.offeredUntil!)) continue;
      final g = _reassignGuard[t.id];
      if (g != null && now.difference(g) < const Duration(seconds: 30)) continue;
      _reassignGuard[t.id] = now;

      final coords = _elderCoords(t.elderId);
      final name = _elderName(t.elderId);
      final addr = _elderAddress(t.elderId);
      final tried = _triedAssignees.putIfAbsent(t.id, () => <String>{});
      if (t.assigneeName != null) tried.add(t.assigneeName!);
      final next = coords == null
          ? null
          : pickVolunteer(_volunteers, coords.$1, coords.$2, _volunteerLoad,
              exclude: tried);
      try {
        if (next != null) {
          tried.add(next.name);
          await _sb.from('dispatch_tasks').update({
            'assignee_name': next.name,
            'offered_until':
                now.add(emergencyDispatchWindow).toUtc().toIso8601String(),
          }).eq('id', t.id);
          _notify(
              '🚨 請支援 $name（$addr）：原志工逾時未動身，已改派就近的 ${next.name}，其他志工也可接單補位',
              Severity.emergency,
              elderId: t.elderId);
        } else {
          // 無其他就近志工 → 不開放全體，交回社工協助指派（offered_until 往後推，避免每輪重打）。
          await _sb.from('dispatch_tasks').update({
            'assignee_name': null,
            'offered_until':
                now.add(emergencyDispatchWindow).toUtc().toIso8601String(),
          }).eq('id', t.id);
          _notify('🚨 $name（$addr）目前無就近志工可改派，請社工協助指派',
              Severity.emergency, elderId: t.elderId);
        }
      } catch (e) {
        // 改派失敗不致命，下一輪 watchdog 會再試。
      }
    }
  }

  @override
  Future<void> requestSupport(String taskId) async {
    // 拒絕／請求支援＝改派給「下一位就近志工」（排除已試過的人，含拒絕者本人），
    // 不再「開放全體」——否則會與看門狗的單點改派衝突、甚至迴力鏢改派回剛拒絕的同一人。
    final ti = _tasks.indexWhere((t) => t.id == taskId);
    final task = ti >= 0 ? _tasks[ti] : null;
    final now = DateTime.now();
    final tried = _triedAssignees.putIfAbsent(taskId, () => <String>{});
    if (task?.assigneeName != null) tried.add(task!.assigneeName!);
    final coords = task != null ? _elderCoords(task.elderId) : null;
    final next = coords == null
        ? null
        : pickVolunteer(_volunteers, coords.$1, coords.$2, _volunteerLoad,
            exclude: tried);
    if (next != null) {
      tried.add(next.name);
      await _sb.from('dispatch_tasks').update({
        'assignee_name': next.name,
        'offered_until':
            now.add(emergencyDispatchWindow).toUtc().toIso8601String(),
      }).eq('id', taskId);
      _notify('已改派就近的 ${next.name} 前往', Severity.attention,
          elderId: task?.elderId);
    } else {
      // 真的沒有其他就近志工 → 交回社工協助指派，仍不開放全體。
      await _sb.from('dispatch_tasks').update({
        'assignee_name': null,
        'offered_until':
            now.add(emergencyDispatchWindow).toUtc().toIso8601String(),
      }).eq('id', taskId);
      _notify('目前無其他就近志工，已轉請社工協助指派', Severity.attention,
          elderId: task?.elderId);
    }
  }

  @override
  Future<void> cancelSupplyTask(String taskId, {String? note}) async {
    await _sb.from('dispatch_tasks').update({
      'status': 'resolved',
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
      'note': note ?? '家屬自行處理，未派工',
    }).eq('id', taskId);
    for (final t in _tasks) {
      if (t.id == taskId && t.eventId.isNotEmpty) {
        await _sb
            .from('radio_events')
            .update({'status': 'closed'}).eq('id', t.eventId);
        break;
      }
    }
  }

  // ---------- 派遣流程 ----------
  @override
  Future<void> acceptTask(String taskId,
      {required int etaMinutes, String? assigneeName, String? assigneeId}) async {
    // 只在單仍 pending 時才接得下：兩人同時搶接時，後接者的 update 條件匹配 0 列 →
    // 拋錯讓 UI 顯示「已被他人接走」，不會靜默覆蓋前接者、造成輸家單子無聲消失。
    final rows = await _sb
        .from('dispatch_tasks')
        .update({
          'status': 'accepted',
          'assignee_name': assigneeName ?? '志工',
          'assignee_id': ?assigneeId,
          'eta_minutes': etaMinutes,
          'accepted_at': DateTime.now().toUtc().toIso8601String(), // 出發時間軸點
        })
        .eq('id', taskId)
        .eq('status', 'pending')
        .select();
    if (rows.isEmpty) {
      throw StateError('這張單已被其他志工接走');
    }
    // 接單通知由 Realtime 狀態變化統一觸發（見 _notifyForTaskTransition）。
  }

  @override
  Future<void> assignVolunteer(String taskId,
      {required String volunteerName, String? volunteerId}) async {
    // 指派時就依「志工座標→長輩家」估算 ETA，家屬端才有真實時間、不是「—」。
    final eta = _estimateEtaFor(taskId, volunteerName);
    await _sb.from('dispatch_tasks').update({
      'assignee_name': volunteerName,
      'assignee_id': ?volunteerId,
      'eta_minutes': ?eta,
    }).eq('id', taskId);
    _notify('社工已指派 $volunteerName 前往', Severity.attention);
  }

  /// 依志工目前座標與長輩家距離估算抵達分鐘數；座標不足回 null。
  int? _estimateEtaFor(String taskId, String volunteerName) {
    final ti = _tasks.indexWhere((t) => t.id == taskId);
    if (ti < 0) return null;
    final task = _tasks[ti];
    final ei = _elders.indexWhere((e) => e.id == task.elderId);
    final vi = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (ei < 0 || vi < 0) return null;
    final e = _elders[ei];
    final v = _volunteers[vi];
    if ((v.lat == 0 && v.lng == 0) || (e.lat == 0 && e.lng == 0)) return null;
    return estimateEtaMinutes(v.lat, v.lng, e.lat, e.lng);
  }

  @override
  Future<void> markArrived(String taskId) async {
    await _sb.from('dispatch_tasks').update({
      'status': 'arrived',
      'arrived_at': DateTime.now().toUtc().toIso8601String(), // 到場時間軸點
    }).eq('id', taskId);
  }

  @override
  Future<void> setElderLang(String elderId, ElderLang lang) async {
    await _sb
        .from('elders')
        .update({'preferred_lang': lang.wire}).eq('id', elderId);
    // Realtime 會回推 elders 變化並重載；此處不需手動更新本地快取。
  }

  @override
  Future<void> setElderNote(String elderId, String? note) async {
    final clean = (note == null || note.trim().isEmpty) ? null : note.trim();
    await _sb.from('elders').update({'note': clean}).eq('id', elderId);
    // Realtime 回推 elders 變化並重載。
  }

  @override
  Future<void> updateElderProfile(
    String elderId, {
    required String name,
    required int age,
    required String address,
    String? phone,
    String? note,
    double? lat,
    double? lng,
  }) async {
    String? clean(String? s) =>
        (s == null || s.trim().isEmpty) ? null : s.trim();
    final patch = <String, dynamic>{
      'name': name.trim(),
      'age': age,
      'address': address.trim(),
      'phone': clean(phone),
      'note': clean(note),
    };
    // 只有地理編碼成功（帶入座標）才更新 lat/lng，避免把地圖釘拉回 0,0。
    if (lat != null && lng != null) {
      patch['lat'] = lat;
      patch['lng'] = lng;
    }
    await _sb.from('elders').update(patch).eq('id', elderId);
    // Realtime 回推 elders 變化並重載；三端即時看到新資料。
  }

  @override
  Future<int> timeBankMinutesFor(String volunteerName) async {
    // 真實時數：時間銀行帳本中該志工的 points 加總（每筆 = 一次派遣的服務分鐘）。
    final rows = await _sb
        .from('time_bank_ledger')
        .select('points')
        .eq('volunteer_name', volunteerName);
    var sum = 0;
    for (final r in rows) {
      sum += ((r['points'] ?? 0) as num).toInt();
    }
    return sum;
  }

  @override
  Future<int> redeemTimeBank(
      String volunteerName, int minutes, String reason) async {
    // 兌換＝寫一筆負值帳；timeBankMinutesFor 加總後自然扣除。
    await _sb.from('time_bank_ledger').insert({
      'volunteer_name': volunteerName,
      'points': -minutes,
      'reason': '兌換：$reason',
    });
    return timeBankMinutesFor(volunteerName);
  }

  @override
  Future<void> setVolunteerLocation(
      String volunteerName, double lat, double lng) async {
    await _sb.from('volunteers').update({
      'lat': lat,
      'lng': lng,
      // 標記為「真實 GPS 回報」時間，家屬地圖才能分辨 live 座標 vs seed。
      'location_updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('name', volunteerName);
    // Realtime 回推 volunteers 變化 → 家屬地圖即時更新志工位置。
  }

  @override
  Future<void> setVolunteerOnline(String volunteerName, bool online) async {
    await _sb
        .from('volunteers')
        .update({'online': online}).eq('name', volunteerName);
    // Realtime 回推 → 後台監控與派單即時反映「工作中／休息中」。
  }

  @override
  Future<void> updateTaskEta(String taskId, int etaMinutes) async {
    await _sb
        .from('dispatch_tasks')
        .update({'eta_minutes': etaMinutes}).eq('id', taskId);
  }

  @override
  Future<void> resolveTask(String taskId,
      {String? note, String? outcome, String? photoUrl}) async {
    // 本地快取可能因 Realtime／輪詢汰換而查不到這張單 → 別讓 firstWhere 丟例外導致「按了關不了單」。
    DispatchTask? task;
    for (final t in _tasks) {
      if (t.id == taskId) {
        task = t;
        break;
      }
    }
    // 時間銀行改存「服務分鐘數」（依回報 ETA 計，緊急加成）
    final pts = task?.timeBankMinutes ?? 0;
    // 樂觀本地更新：先把這張單標成 resolved 並推流 → 家屬按「確認平安」後任務卡「即時」消失，
    // 不必等 Realtime 回音或 8 秒保險輪詢（否則要等 4 筆連續寫入＋回音才不見，感覺很慢）。
    // 後續 DB 寫入與 Realtime reconcile 皆冪等；結案通知仍由 _knownTaskStatus 差異在
    // _loadTasks() 統一觸發（此處不動 _knownTaskStatus），故通知一次、不重複、不遺漏。
    final oi = _tasks.indexWhere((t) => t.id == taskId);
    if (oi >= 0) {
      _tasks[oi] = _tasks[oi].copyWith(
        status: DispatchStatus.resolved,
        resolvedAt: DateTime.now(),
        note: (note != null && note.trim().isNotEmpty) ? note.trim() : null,
        outcome: (outcome != null && outcome.trim().isNotEmpty) ? outcome.trim() : null,
        proofPhotoUrl: (photoUrl != null && photoUrl.isNotEmpty) ? photoUrl : null,
      );
      _tasksCtrl.add(currentTasks);
    }
    await _sb.from('dispatch_tasks').update({
      'status': 'resolved',
      'resolved_at': DateTime.now().toUtc().toIso8601String(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      if (outcome != null && outcome.trim().isNotEmpty) 'outcome': outcome.trim(),
      if (photoUrl != null && photoUrl.isNotEmpty) 'proof_photo_url': photoUrl,
    }).eq('id', taskId);
    if (task != null && task.eventId.isNotEmpty) {
      await _sb.from('radio_events').update({'status': 'closed'}).eq('id', task.eventId);
    }
    if (task != null) {
      await _sb.from('elders').update({'severity': 'normal'}).eq('id', task.elderId);
    }
    if (task?.assigneeName != null) {
      await _sb.from('time_bank_ledger').insert({
        'volunteer_name': task!.assigneeName,
        'task_id': taskId,
        'points': pts,
        'reason': task.kind == DispatchKind.emergency ? '緊急派遣完成（分鐘）' : '物資代購完成（分鐘）',
      });
    }
    _points += pts;
    _pointsCtrl.add(_points);
    // 結案通知由 Realtime 狀態變化統一觸發（見 _notifyForTaskTransition）。
  }

  @override
  Future<String> uploadProofPhoto(String taskId, Uint8List bytes,
      {String contentType = 'image/jpeg'}) async {
    final ext = contentType.contains('png') ? 'png' : 'jpg';
    // 用 taskId 當路徑，同一單重拍會覆蓋（upsert），不累積垃圾檔。
    final path = '$taskId.$ext';
    await _sb.storage.from('proofs').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: true),
        );
    return _sb.storage.from('proofs').getPublicUrl(path);
  }

  // ---------- 綁定／設定／推播 token ----------
  // 這幾件事以前散在各 App 裡直接打 Supabase（family_app/app_local.dart、
  // admin/hardware_sim.dart、push_service.dart）。收進 BackendClient 之後，
  // 三端才真的只依賴介面，換 AWS 後端不必逐頁改。

  @override
  Future<Set<String>> familyBindings(String familyId) async {
    try {
      final rows = await _sb
          .from('family_bindings')
          .select('elder_id')
          .eq('family_id', familyId);
      return {for (final r in rows) r['elder_id'] as String};
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> bindFamily(String familyId, String elderId) async {
    try {
      await _sb.from('family_bindings').upsert(
        {'family_id': familyId, 'elder_id': elderId},
        onConflict: 'family_id,elder_id',
      );
    } catch (_) {
      // 已綁定或離線時不擋流程（呼叫端會把 elderId 記進本地）
    }
  }

  @override
  Future<String?> appSetting(String key) async {
    try {
      final row = await _sb
          .from('app_settings')
          .select('value')
          .eq('key', key)
          .maybeSingle();
      return row?['value'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setAppSetting(String key, String value) async {
    await _sb.from('app_settings').upsert({
      'key': key,
      'value': value,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> registerDeviceToken({
    required String token,
    required String role,
    String? platform,
    List<String> elderIds = const [],
  }) async {
    await _sb.from('device_tokens').upsert({
      'token': token,
      'user_id': _sb.auth.currentUser?.id,
      'role': role,
      'platform': ?platform,
      'elder_ids': elderIds,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }

  @override
  Future<void> unregisterDeviceToken(String token) async {
    await _sb.from('device_tokens').delete().eq('token', token);
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    for (final ch in _channels) {
      _sb.removeChannel(ch);
    }
    _eldersCtrl.close();
    _eventsCtrl.close();
    _tasksCtrl.close();
    _volCtrl.close();
    _msgCtrl.close();
    _notifCtrl.close();
    _pointsCtrl.close();
    _callCtrl.close();
  }

  // ---------- helpers ----------
  void _notify(String message, Severity severity, {String? elderId}) =>
      _notifCtrl.add(AppNotification(
        id: 'n-${_idSeq++}',
        message: message,
        severity: severity,
        elderId: elderId,
        at: DateTime.now(),
      ));

  String _elderName(String id) {
    for (final e in _elders) {
      if (e.id == id) return e.name;
    }
    return '長輩';
  }

  CallSignal _callFrom(Map<String, dynamic> r) => callFromRow(r);

  @override
  Future<CallSignal> startCall({
    required String taskId,
    required CallRole from,
    required CallRole to,
    String? fromName,
    String? room,
  }) async {
    // room 不可猜；Web 端會先產好傳進來（點擊當下就要開分頁）。
    final theRoom = room ??
        'jinsun-$taskId-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final row = await _sb
        .from('call_signals')
        .insert({
          'task_id': taskId,
          'room': theRoom,
          'from_role': from.wire,
          'to_role': to.wire,
          'status': 'ringing',
          'from_name': ?fromName,
        })
        .select()
        .single();
    // 即時廣播給對方（來電響鈴次秒級）；DB 已保存。
    await _broadcastRow('call', row);
    return _callFrom(row);
  }

  @override
  Future<void> setCallStatus(String signalId, CallStatus status) async {
    final row = await _sb
        .from('call_signals')
        .update({'status': status.wire})
        .eq('id', signalId)
        .select()
        .maybeSingle();
    // 接聽／掛斷／取消即時廣播，對方立刻反應。
    if (row != null) await _broadcastRow('call', row);
  }

  @override
  Future<CallSignal?> getCallSignal(String signalId) async {
    final row = await _sb
        .from('call_signals')
        .select()
        .eq('id', signalId)
        .maybeSingle();
    return row == null ? null : _callFrom(row);
  }

  // 解析一律走 row_mappers.dart（與 AwsBackend 共用同一份，欄位改動不會只改到一邊）
  Elder _elderFrom(Map<String, dynamic> r) => elderFromRow(r);
  RadioEvent _eventFrom(Map<String, dynamic> r) => eventFromRow(r);
  DispatchTask _taskFrom(Map<String, dynamic> r) => taskFromRow(r);
}
