import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'aws_config.dart';
import 'backend_client.dart';
import 'event_notifications.dart';
import 'models.dart';
import 'row_mappers.dart';

/// AWS 平行環境的後端：API Gateway + Lambda（jinsun-data）+ Aurora。
/// 實作與 [SupabaseBackend] 相同的 [BackendClient]，三端 App 換過來不改 UI。
///
/// **即時同步用輪詢，不是訂閱。** 每 [JinsunAws.pollSeconds] 秒打一次 `/data/version`
/// 取六張表的變更指紋，指紋沒變就不抓快照——一次請求回一列六個 md5，比抓整包便宜兩個數量級。
/// 之所以不是 AppSync 訂閱：跌倒升級開單是後端 Lambda 直接寫 Aurora 的，不經過
/// AppSync mutation，訂閱對「最重要的那條鏈路」不會響；要響就得讓每支後端 Lambda 反手
/// 再呼叫一次 AppSync，多一層耦合換 3 秒 → 次秒級。這個系統的黃金窗是 20 秒。
///
/// 每次寫入之後會立刻強制抓一次快照，所以「自己動的」永遠是即時的，
/// 3 秒只發生在「別人動的」。
class AwsBackend extends BackendClient {
  AwsBackend({
    required this.idToken,
    this.dispatchWatchdog = false,
    http.Client? client,
    Duration? pollInterval,
    String? baseUrl,
  })  : _http = client ?? http.Client(),
        _base = baseUrl ?? JinsunAws.apiBase,
        _poll = pollInterval ?? Duration(seconds: JinsunAws.pollSeconds) {
    _timers['poll'] = Timer.periodic(_poll, (_) => _tick());
    _tick();
    // 卡單自動改派看門狗：只有社工後台開（單一權威端，避免多端重複改派互踩）。
    if (dispatchWatchdog) {
      _timers['watchdog'] = Timer.periodic(
          const Duration(seconds: 20), (_) => _reassignStaleEmergencies());
    }
  }

  /// 取一張還沒過期的 Cognito id token。由 CognitoAuthRepository.freshIdToken 提供。
  final Future<String?> Function() idToken;
  final bool dispatchWatchdog;
  final http.Client _http;
  /// API Gateway base url。預設取建置參數；測試會注入假的。
  final String _base;
  final Duration _poll;

  final List<Elder> _elders = [];
  final List<RadioEvent> _events = [];
  final List<DispatchTask> _tasks = [];
  final List<SocialWorker> _workers = [];
  final List<Volunteer> _volunteers = [];
  final List<TaskMessage> _messages = [];
  final List<CallSignal> _calls = [];
  final Set<String> _bindings = {};
  final Map<String, String> _settings = {};
  int _points = 0;

  final _eldersCtrl = StreamController<List<Elder>>.broadcast();
  final _eventsCtrl = StreamController<List<RadioEvent>>.broadcast();
  final _tasksCtrl = StreamController<List<DispatchTask>>.broadcast();
  final _volCtrl = StreamController<List<Volunteer>>.broadcast();
  final _msgCtrl = StreamController<List<TaskMessage>>.broadcast();
  final _notifCtrl = StreamController<AppNotification>.broadcast();
  final _pointsCtrl = StreamController<int>.broadcast();
  final _callCtrl = StreamController<CallSignal>.broadcast();
  final Map<String, Timer> _timers = {};
  int _idSeq = 0;

  /// 上一輪的變更指紋。相同就整輪跳過，不抓快照。
  Map<String, dynamic> _version = const {};
  bool _fetching = false;

  // 通知去重：只對「這一輪新出現／狀態變了」的事件跳通知；初次載入不跳（否則開 App 就洗版）。
  bool _seeded = false;
  final Set<String> _knownEventIds = {};
  final Map<String, DispatchStatus> _knownTaskStatus = {};
  final Map<String, CallStatus> _knownCallStatus = {};

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

  // ═══════════════════ HTTP ═══════════════════

  Future<Map<String, String>> _headers() async {
    final t = await idToken();
    return {
      'content-type': 'application/json',
      if (t != null) 'authorization': 'Bearer $t',
    };
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await _http.get(
      Uri.parse('$_base$path'),
      headers: await _headers(),
    );
    return _decode(res);
  }

  /// 送出一個具名寫入操作。可寫欄位由後端 ops.mjs 決定，這裡送什麼多餘欄位都不會生效。
  Future<Map<String, dynamic>> _mutate(String op, [Map<String, dynamic> args = const {}]) async {
    final res = await _http.post(
      Uri.parse('$_base/data/mutate'),
      headers: await _headers(),
      body: jsonEncode({'op': op, 'args': args}),
    );
    final out = _decode(res);
    // 寫完立刻抓一次快照：使用者自己按下去的動作不該等下一次輪詢才出現在畫面上。
    unawaited(refresh());
    return out;
  }

  Map<String, dynamic> _decode(http.Response res) {
    final body = res.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      final msg = (body['error'] ?? res.body) as String;
      // 409 是「單被搶走」這種業務衝突，UI 有專門的處理，不能混進一般錯誤。
      if (res.statusCode == 409) throw StateError(msg);
      throw JinsunBackendException(msg, res.statusCode);
    }
    return body;
  }

  // ═══════════════════ 輪詢 ═══════════════════

  Future<void> _tick() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final v = (await _get('/data/version'))['v'] as Map<String, dynamic>?;
      if (v == null) return;
      if (_seeded && _sameVersion(v, _version)) return;
      _version = v;
      await _loadSnapshot();
    } catch (_) {
      // 網路不穩／token 剛過期都會走到這裡。下一輪會再試，不必吵使用者。
    } finally {
      _fetching = false;
    }
  }

  bool _sameVersion(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  /// 強制抓一次最新快照（寫入之後、或 UI 主動要求時用）。
  Future<void> refresh() async {
    try {
      await _loadSnapshot();
      final v = (await _get('/data/version'))['v'] as Map<String, dynamic>?;
      if (v != null) _version = v;
    } catch (_) {}
  }

  Future<void> _loadSnapshot() async {
    final snap = await _get('/data/snapshot');
    _apply(snap);
  }

  List<Map<String, dynamic>> _rows(dynamic raw) =>
      (raw as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  void _apply(Map<String, dynamic> snap) {
    _elders
      ..clear()
      ..addAll(_rows(snap['elders']).map(elderFromRow));
    _eldersCtrl.add(currentElders);

    _workers
      ..clear()
      ..addAll(_rows(snap['workers']).map(workerFromRow));

    _volunteers
      ..clear()
      ..addAll(_rows(snap['volunteers']).map((r) => volunteerFromRow(
            r,
            certificates: _rows(r['certificates']).map(certificateFromRow).toList(),
          )));
    _volCtrl.add(currentVolunteers);

    _bindings
      ..clear()
      ..addAll((snap['bindings'] as List? ?? const []).cast<String>());

    _settings
      ..clear()
      ..addAll(Map<String, dynamic>.from(snap['settings'] as Map? ?? const {})
          .map((k, v) => MapEntry(k, (v ?? '').toString())));

    // ---- 事件：先算通知，再換掉快取（順序反了就比不出「哪些是新的」）----
    final events = _rows(snap['events']).map(eventFromRow).toList();
    if (_seeded) {
      for (final e in events.reversed) {
        if (_knownEventIds.contains(e.id)) continue;
        final n = notificationForEvent(e, _elderName(e.elderId));
        if (n != null) _notify(n.message, n.severity, elderId: e.elderId);
      }
    }
    for (final e in events) {
      _knownEventIds.add(e.id);
    }
    _events
      ..clear()
      ..addAll(events);
    _eventsCtrl.add(currentEvents);

    final tasks = _rows(snap['tasks']).map(taskFromRow).toList();
    if (_seeded) {
      for (final t in tasks.reversed) {
        final prev = _knownTaskStatus[t.id];
        final n = prev == null
            ? notificationForNewTask(t, _elderName(t.elderId))
            : (prev != t.status
                ? notificationForTaskTransition(t, _elderName(t.elderId))
                : null);
        if (n != null) _notify(n.message, n.severity, elderId: t.elderId);
      }
    }
    for (final t in tasks) {
      _knownTaskStatus[t.id] = t.status;
    }
    _tasks
      ..clear()
      ..addAll(tasks);
    _tasksCtrl.add(currentTasks);

    _messages
      ..clear()
      ..addAll(_rows(snap['messages']).map(messageFromRow));
    _msgCtrl.add(currentMessages);

    // ---- 通話號誌：只把「新的或狀態變了的」推進 stream（UI 靠它彈來電畫面）----
    final calls = _rows(snap['calls']).map(callFromRow).toList();
    for (final c in calls) {
      final prev = _knownCallStatus[c.id];
      _knownCallStatus[c.id] = c.status;
      if (_seeded && prev != c.status) _callCtrl.add(c);
    }
    _calls
      ..clear()
      ..addAll(calls);

    _seeded = true;
  }

  // ═══════════════════ 收音機事件 ═══════════════════
  //
  // 這四個動作在 AWS 環境「不直接寫資料庫」，而是打 POST /voice ——
  // 那正是真收音機走的那條路（見 hardware-integration.md §3）。好處是 demo 面板按下去
  // 會真的跑完 Step Functions 逾時階梯、MQTT 下發、進度播報，而不是只在資料表插一列
  // 假裝發生過。壞處是需要長輩的 device_serial，查不到就只能放棄（並吵一聲）。

  String? _serialOf(String elderId) {
    for (final e in _elders) {
      if (e.id == elderId) return e.deviceSerial;
    }
    return null;
  }

  Future<void> _voice(String elderId, Map<String, dynamic> payload) async {
    final serial = _serialOf(elderId);
    if (serial == null) {
      _notify('${_elderName(elderId)} 尚未綁定收音機序號，無法模擬事件', Severity.attention,
          elderId: elderId);
      return;
    }
    try {
      await _http.post(
        Uri.parse('$_base/voice'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'device_serial': serial, ...payload}),
      );
    } catch (_) {
      _notify('收音機事件送出失敗，請確認網路', Severity.attention, elderId: elderId);
    }
    await refresh();
  }

  @override
  void triggerFallSuspected(String elderId) {
    // 20 秒逾時階梯由雲端 Step Functions 跑（不是本機 Timer）——App 關掉也照升級。
    unawaited(_voice(elderId, {'event': 'fall_suspected'}));
  }

  @override
  void triggerSos(String elderId) => unawaited(_voice(elderId, {'event': 'sos'}));

  @override
  void triggerSupplyRequest(String elderId, List<String> items) =>
      unawaited(_voice(elderId, {'text': '我想買${items.join('跟')}'}));

  @override
  void confirmElderOk(String elderId) => unawaited(_voice(elderId, {'text': '我沒事'}));

  // ═══════════════════ 派遣流程 ═══════════════════

  @override
  int workerLoad(String workerName) => _tasks
      .where((t) =>
          t.workerName == workerName && t.status != DispatchStatus.resolved)
      .length;

  int _volunteerLoad(String name) => _tasks
      .where((t) => t.assigneeName == name && t.status != DispatchStatus.resolved)
      .length;

  (double, double)? _elderCoords(String elderId) {
    for (final e in _elders) {
      if (e.id == elderId) {
        return (e.lat == 0 && e.lng == 0) ? null : (e.lat, e.lng);
      }
    }
    return null;
  }

  @override
  Future<void> acceptTask(String taskId,
      {required int etaMinutes, String? assigneeName, String? assigneeId}) async {
    await _mutate('acceptTask', {
      'taskId': taskId,
      'etaMinutes': etaMinutes,
      'assigneeName': ?assigneeName,
      'assigneeId': ?assigneeId,
    });
  }

  @override
  Future<void> markArrived(String taskId) async => await _mutate('markArrived', {'taskId': taskId});

  @override
  Future<void> updateTaskEta(String taskId, int etaMinutes) async => await _mutate('updateTaskEta', {'taskId': taskId, 'etaMinutes': etaMinutes});

  @override
  Future<void> assignVolunteer(String taskId,
      {required String volunteerName, String? volunteerId}) async {
    // 指派時就估 ETA，家屬端才有真實時間、不是「—」（與 SupabaseBackend 同一套算法）。
    await _mutate('assignVolunteer', {
      'taskId': taskId,
      'volunteerName': volunteerName,
      'volunteerId': ?volunteerId,
      if (_estimateEtaFor(taskId, volunteerName) != null)
        'etaMinutes': _estimateEtaFor(taskId, volunteerName),
    });
    _notify('社工已指派 $volunteerName 前往', Severity.attention);
  }

  int? _estimateEtaFor(String taskId, String volunteerName) {
    final ti = _tasks.indexWhere((t) => t.id == taskId);
    if (ti < 0) return null;
    final ei = _elders.indexWhere((e) => e.id == _tasks[ti].elderId);
    final vi = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (ei < 0 || vi < 0) return null;
    final e = _elders[ei];
    final v = _volunteers[vi];
    if ((v.lat == 0 && v.lng == 0) || (e.lat == 0 && e.lng == 0)) return null;
    return estimateEtaMinutes(v.lat, v.lng, e.lat, e.lng);
  }

  // 卡單改派防抖與「試過誰」——與 SupabaseBackend 相同的規則：
  // 拒絕／逾時一律改派「下一位就近志工」，不開放全體，才不會迴力鏢改派回剛拒絕的人。
  final Map<String, DateTime> _reassignGuard = {};
  final Map<String, Set<String>> _triedAssignees = {};

  @override
  Future<void> requestSupport(String taskId) async {
    final ti = _tasks.indexWhere((t) => t.id == taskId);
    final task = ti >= 0 ? _tasks[ti] : null;
    final tried = _triedAssignees.putIfAbsent(taskId, () => <String>{});
    if (task?.assigneeName != null) tried.add(task!.assigneeName!);
    final coords = task != null ? _elderCoords(task.elderId) : null;
    final next = coords == null
        ? null
        : pickVolunteer(_volunteers, coords.$1, coords.$2, _volunteerLoad,
            exclude: tried);
    if (next != null) tried.add(next.name);
    await _mutate('reassignTask', {
      'taskId': taskId,
      'volunteerName': next?.name,
      'windowMinutes': emergencyDispatchWindow.inMinutes,
    });
    _notify(
      next != null ? '已改派就近的 ${next.name} 前往' : '目前無其他就近志工，已轉請社工協助指派',
      Severity.attention,
      elderId: task?.elderId,
    );
  }

  /// 看門狗：緊急・pending・offered_until 已過的卡單自動改派下一位（社工後台專用）。
  Future<void> _reassignStaleEmergencies() async {
    final now = DateTime.now();
    for (final t in List<DispatchTask>.from(_tasks)) {
      if (t.kind != DispatchKind.emergency || t.status != DispatchStatus.pending) {
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
        if (next != null) tried.add(next.name);
        await _mutate('reassignTask', {
          'taskId': t.id,
          'volunteerName': next?.name,
          'windowMinutes': emergencyDispatchWindow.inMinutes,
        });
        _notify(
          next != null
              ? '🚨 請支援 $name（$addr）：原志工逾時未動身，已改派就近的 ${next.name}，其他志工也可接單補位'
              : '🚨 $name（$addr）目前無就近志工可改派，請社工協助指派',
          Severity.emergency,
          elderId: t.elderId,
        );
      } catch (_) {
        // 改派失敗不致命，下一輪 watchdog 會再試。
      }
    }
  }

  @override
  Future<void> cancelSupplyTask(String taskId, {String? note}) async => await _mutate('cancelSupplyTask', {'taskId': taskId, 'note': note});

  @override
  Future<void> resolveTask(String taskId,
      {String? note, String? outcome, String? photoUrl}) async {
    final out = await _mutate('resolveTask', {
      'taskId': taskId,
      'note': ?note,
      'outcome': ?outcome,
      'photoUrl': ?photoUrl,
    });
    // 點數由伺服器依 kind＋eta 算（客戶端算的話志工可自行灌點）。
    _points += ((out['points'] ?? 0) as num).toInt();
    _pointsCtrl.add(_points);
  }

  @override
  Future<String> uploadProofPhoto(String taskId, Uint8List bytes,
      {String contentType = 'image/jpeg'}) async {
    // 照片不經過 Lambda：API Gateway 有 6MB payload 上限，而且來回兩份流量都要付錢。
    // 由後端簽一組 5 分鐘有效的 presigned PUT，App 直接把位元組丟進 S3。
    final res = await _http.post(
      Uri.parse('$_base/data/mutate'),
      headers: await _headers(),
      body: jsonEncode({
        'op': 'proofUploadUrl',
        'args': {'taskId': taskId, 'contentType': contentType},
      }),
    );
    final out = _decode(res);
    final put = await _http.put(
      Uri.parse(out['uploadUrl'] as String),
      headers: {'content-type': contentType},
      body: bytes,
    );
    if (put.statusCode >= 400) {
      throw JinsunBackendException('照片上傳失敗（${put.statusCode}）', put.statusCode);
    }
    return out['publicUrl'] as String;
  }

  // ═══════════════════ 長輩／志工 ═══════════════════

  @override
  Future<void> setElderLang(String elderId, ElderLang lang) async => await _mutate('setElderLang', {'elderId': elderId, 'lang': lang.wire});

  @override
  Future<void> setElderNote(String elderId, String? note) async => await _mutate('setElderNote', {'elderId': elderId, 'note': note ?? ''});

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
    // lat/lng 帶 null＝地理編碼沒成功，此時不送座標，讓後端保留原本的地圖釘，
    // 不要把它拉回 0,0。Supabase 版是同一套語意（見 supabase_backend.dart）。
    await _mutate('updateElderProfile', {
      'elderId': elderId,
      'name': name.trim(),
      'age': age,
      'address': address.trim(),
      'phone': phone,
      'note': note,
      if (lat != null && lng != null) 'lat': lat,
      if (lat != null && lng != null) 'lng': lng,
    });
  }

  @override
  Future<void> setVolunteerLocation(
          String volunteerName, double lat, double lng) async => await _mutate('setVolunteerLocation',
          {'volunteerName': volunteerName, 'lat': lat, 'lng': lng});

  @override
  Future<void> setVolunteerOnline(String volunteerName, bool online) async => await _mutate(
          'setVolunteerOnline', {'volunteerName': volunteerName, 'online': online});

  @override
  Future<void> submitCertificate(String volunteerName, CertKind kind,
          {DateTime? issuedAt, DateTime? expiresAt, String? note}) async => await _mutate('submitCertificate', {
        'volunteerName': volunteerName,
        'kind': kind.wire,
        if (issuedAt != null) 'issuedAt': issuedAt.toIso8601String().split('T').first,
        if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String().split('T').first,
        'note': ?note,
      });

  @override
  Future<int> timeBankMinutesFor(String volunteerName) async {
    final out = await _get('/data/timebank?name=${Uri.encodeQueryComponent(volunteerName)}');
    return ((out['minutes'] ?? 0) as num).toInt();
  }

  @override
  Future<int> redeemTimeBank(
      String volunteerName, int minutes, String reason) async {
    final out = await _mutate('redeemTimeBank',
        {'volunteerName': volunteerName, 'minutes': minutes, 'reason': reason});
    return ((out['remaining'] ?? 0) as num).toInt();
  }

  // ═══════════════════ 聊天／通話 ═══════════════════

  @override
  Future<void> sendTaskMessage(String taskId,
      {required ChatFromRole from, String? senderId, required String text}) async {
    final out = await _mutate('sendTaskMessage',
        {'taskId': taskId, 'fromRole': from.name, 'text': text});
    // 送出者本端樂觀顯示，不必等下一次輪詢。
    final row = out['row'];
    if (row is Map) {
      final m = messageFromRow(Map<String, dynamic>.from(row));
      if (!_messages.any((e) => e.id == m.id)) {
        _messages
          ..add(m)
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _msgCtrl.add(currentMessages);
      }
    }
  }

  @override
  Future<CallSignal> startCall({
    required String taskId,
    required CallRole from,
    required CallRole to,
    String? fromName,
    String? room,
  }) async {
    final theRoom = room ??
        'jinsun-$taskId-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final out = await _mutate('startCall', {
      'taskId': taskId,
      'room': theRoom,
      'fromRole': from.wire,
      'toRole': to.wire,
      'fromName': ?fromName,
    });
    return callFromRow(Map<String, dynamic>.from(out['row'] as Map));
  }

  @override
  Future<void> setCallStatus(String signalId, CallStatus status) async => await _mutate(
          'setCallStatus', {'signalId': signalId, 'status': status.wire});

  @override
  Future<CallSignal?> getCallSignal(String signalId) async {
    for (final c in _calls) {
      if (c.id == signalId) return c;
    }
    return null;
  }

  @override
  Future<String> transcribeAudio(Uint8List audioBytes,
      {required String filename, String? mimeType, String? prompt}) async {
    if (audioBytes.isEmpty) return '';
    // 走 jinsun-voice Lambda 的 POST /asr 代理（上游與 Supabase 版同一個 XCC Gateway，
    // 見 cloud/aws/lambda/voice/index.mjs 的 handleAsr）：金鑰只存 Lambda 環境變數，
    // 前端只送音檔 base64。
    //
    // 這條路徑刻意**不帶 Authorization**——/asr 落在 $default 路由上，沒有 JWT
    // authorizer；長輩端的收音機是裝置身分，不該為了轉一句逐字稿去換 token。
    final res = await _http.post(
      Uri.parse('$_base/asr'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'audio_base64': base64Encode(audioBytes),
        'filename': filename,
        'mime': ?mimeType,
        'prompt': ?prompt,
        'language': 'zh',
      }),
    );
    final body = res.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      final detail = body['detail'];
      throw JinsunBackendException(
        '語音轉文字失敗：${body['error'] ?? res.body}'
        '${detail != null ? '（$detail）' : ''}',
        res.statusCode,
      );
    }
    return (body['text'] as String? ?? '').trim();
  }

  // ═══════════════════ 綁定／設定／推播 token ═══════════════════

  @override
  Future<Set<String>> familyBindings(String familyId) async {
    if (!_seeded) await refresh();
    return Set.unmodifiable(_bindings);
  }

  @override
  Future<void> bindFamily(String familyId, String elderId) async {
    await _mutate('bindFamily', {'elderId': elderId});
    _bindings.add(elderId);
  }

  @override
  Future<String?> appSetting(String key) async {
    if (!_seeded) await refresh();
    return _settings[key];
  }

  @override
  Future<void> setAppSetting(String key, String value) async {
    await _mutate('setAppSetting', {'key': key, 'value': value});
    _settings[key] = value;
  }

  @override
  Future<void> registerDeviceToken({
    required String token,
    required String role,
    String? platform,
    List<String> elderIds = const [],
  }) async => await _mutate('registerDeviceToken',
          {'token': token, 'platform': platform, 'elderIds': elderIds});

  @override
  Future<void> unregisterDeviceToken(String token) async => await _mutate('unregisterDeviceToken', {'token': token});

  // ═══════════════════ helpers ═══════════════════

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

  String _elderAddress(String id) {
    for (final e in _elders) {
      if (e.id == id) return e.address;
    }
    return '';
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _http.close();
    _eldersCtrl.close();
    _eventsCtrl.close();
    _tasksCtrl.close();
    _volCtrl.close();
    _msgCtrl.close();
    _notifCtrl.close();
    _pointsCtrl.close();
    _callCtrl.close();
  }
}

/// 後端回錯時丟這個，帶上 HTTP 狀態碼讓 UI 分辨「權限不足」與「網路不通」。
class JinsunBackendException implements Exception {
  JinsunBackendException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
