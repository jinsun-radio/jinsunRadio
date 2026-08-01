import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'backend_client.dart';
import 'models.dart';

class MockBackend implements BackendClient {
  MockBackend({
    this.autoVolunteer = false,
    this.autoVolunteerName = '阿明',
    this.escalateAfter = const Duration(seconds: 20),
    this.autoAcceptDelay = const Duration(seconds: 5),
    this.autoArriveDelay = const Duration(seconds: 10),
    this.autoResolveDelay = const Duration(seconds: 4),
    this.followUpThreshold = 3,
    this.followUpWindow = const Duration(days: 7),
  }) {
    _elders.addAll(_seedElders());
  }

  final bool autoVolunteer;
  final String autoVolunteerName;
  final Duration escalateAfter;
  final Duration autoAcceptDelay;
  final Duration autoArriveDelay;
  final Duration autoResolveDelay;

  /// 🟡 注意軌：同一位長輩在 [followUpWindow] 內累積幾次「疑似跌倒但自行回應無恙」，
  /// 達到 [followUpThreshold] 就自動為督導個管／居督開一張督導追蹤待辦（非緊急）。
  final int followUpThreshold;
  final Duration followUpWindow;

  /// 每位長輩近期「疑似跌倒（回應OK）」的時間戳，用來判定趨勢。
  final Map<String, List<DateTime>> _fallTrend = {};

  final List<Elder> _elders = [];
  final List<RadioEvent> _events = [];
  final List<DispatchTask> _tasks = [];
  final List<SocialWorker> _workers = _seedWorkers();
  final List<Volunteer> _volunteers = _seedVolunteers();
  int _points = 0;
  int _idSeq = 0;

  final _eldersCtrl = StreamController<List<Elder>>.broadcast();
  final _eventsCtrl = StreamController<List<RadioEvent>>.broadcast();
  final _tasksCtrl = StreamController<List<DispatchTask>>.broadcast();
  final _notifCtrl = StreamController<AppNotification>.broadcast();
  final _pointsCtrl = StreamController<int>.broadcast();

  final Map<String, Timer> _timers = {};

  @override
  Stream<List<Elder>> get elders => _eldersCtrl.stream;
  @override
  Stream<List<RadioEvent>> get events => _eventsCtrl.stream;
  @override
  Stream<List<DispatchTask>> get tasks => _tasksCtrl.stream;
  @override
  Stream<AppNotification> get notifications => _notifCtrl.stream;
  @override
  Stream<int> get timeBankPoints => _pointsCtrl.stream;

  @override
  List<SocialWorker> get currentWorkers => List.unmodifiable(_workers);

  final _volCtrl = StreamController<List<Volunteer>>.broadcast();
  @override
  Stream<List<Volunteer>> get volunteers => _volCtrl.stream;
  @override
  List<Volunteer> get currentVolunteers => List.unmodifiable(_volunteers);

  final _msgCtrl = StreamController<List<TaskMessage>>.broadcast();
  final List<TaskMessage> _messages = [];
  @override
  Stream<List<TaskMessage>> get messages => _msgCtrl.stream;
  @override
  List<TaskMessage> get currentMessages => List.unmodifiable(_messages);

  // ---- 通話號誌（單一 process loopback；真跨裝置在 SupabaseBackend）----
  final _callCtrl = StreamController<CallSignal>.broadcast();
  final Map<String, CallSignal> _calls = {};
  @override
  Stream<CallSignal> get callSignals => _callCtrl.stream;

  @override
  Future<CallSignal> startCall({
    required String taskId,
    required CallRole from,
    required CallRole to,
    String? fromName,
    String? room,
  }) async {
    final id = _nextId('call');
    final sig = CallSignal(
      id: id,
      taskId: taskId,
      room: room ?? 'jinsun-$id',
      from: from,
      to: to,
      status: CallStatus.ringing,
      fromName: fromName,
      createdAt: DateTime.now(),
    );
    _calls[id] = sig;
    _callCtrl.add(sig);
    return sig;
  }

  @override
  Future<void> setCallStatus(String signalId, CallStatus status) async {
    final s = _calls[signalId];
    if (s == null) return;
    final updated = CallSignal(
      id: s.id,
      taskId: s.taskId,
      room: s.room,
      from: s.from,
      to: s.to,
      status: status,
      fromName: s.fromName,
      createdAt: s.createdAt,
    );
    _calls[signalId] = updated;
    _callCtrl.add(updated);
  }

  @override
  Future<CallSignal?> getCallSignal(String signalId) async => _calls[signalId];

  @override
  Future<void> sendTaskMessage(String taskId,
      {required ChatFromRole from, String? senderId, required String text}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    _messages.add(TaskMessage(
      id: _nextId('msg'),
      taskId: taskId,
      fromRole: from,
      senderId: senderId,
      text: t,
      createdAt: DateTime.now(),
    ));
    _msgCtrl.add(currentMessages);
  }

  @override
  Future<String> transcribeAudio(Uint8List audioBytes,
      {required String filename, String? mimeType, String? prompt}) async {
    // 離線 demo：沒有真後端可打，模擬 Whisper 延遲後回傳一句示範文字。
    await Future.delayed(const Duration(milliseconds: 600));
    if (audioBytes.isEmpty) return '';
    return '（語音輸入示範）我等一下就到，長輩再等我五分鐘。';
  }

  /// 志工目前在辦單量（未結案的派遣單）
  @override
  int workerLoad(String workerName) => _tasks
      .where((t) => t.workerName == workerName && t.status != DispatchStatus.resolved)
      .length;

  /// 派遣指派：值班中優先，再取單量最少者；無人值班則全名單取最少者（支援）
  SocialWorker pickWorker({DateTime? now}) {
    final at = now ?? DateTime.now();
    final onDuty = _workers.where((w) => w.onDuty(at)).toList();
    final pool = onDuty.isNotEmpty ? onDuty : _workers;
    pool.sort((a, b) => workerLoad(a.name).compareTo(workerLoad(b.name)));
    return pool.first;
  }

  @override
  List<Elder> get currentElders => List.unmodifiable(_elders);
  @override
  List<RadioEvent> get currentEvents => List.unmodifiable(_events);
  @override
  List<DispatchTask> get currentTasks => List.unmodifiable(_tasks);
  @override
  int get currentTimeBankPoints => _points;

  @override
  void triggerFallSuspected(String elderId) {
    final elder = _elderById(elderId);
    final event = _addEvent(elderId, RadioEventType.fallSuspected,
        Severity.attention, RadioEventStatus.open);
    _setElderSeverity(elderId, Severity.attention);
    _notify('${elder.name} 疑似跌倒，收音機語音確認中', Severity.attention);
    _timers['confirm-${event.id}'] = Timer(escalateAfter, () {
      _timers.remove('confirm-${event.id}');
      _escalate(event.id);
    });
  }

  @override
  void triggerSos(String elderId) {
    final event = _addEvent(
        elderId, RadioEventType.sos, Severity.emergency, RadioEventStatus.escalated);
    _setElderSeverity(elderId, Severity.emergency);
    final elder = _elderById(elderId);
    _notify('${elder.name} 按下 SOS，已開立緊急派遣單', Severity.emergency);
    _createTask(event, DispatchKind.emergency);
  }

  @override
  void triggerSupplyRequest(String elderId, List<String> items) {
    final elder = _elderById(elderId);
    final event = _addEvent(elderId, RadioEventType.supplyRequest,
        Severity.normal, RadioEventStatus.open,
        transcript: '我想買${items.join('跟')}');
    _notify('${elder.name} 需要物資：${items.join('、')}', Severity.normal);
    _createTask(event, DispatchKind.supply, items: items);
  }

  @override
  void confirmElderOk(String elderId) {
    final event = _openFallEventOf(elderId);
    if (event == null) return;
    _timers.remove('confirm-${event.id}')?.cancel();
    _updateEvent(event.copyWith(
        status: RadioEventStatus.confirmedOk, severity: Severity.normal));
    _setElderSeverity(elderId, Severity.normal);
    _notify('${_elderById(elderId).name} 回應「我沒事」，事件解除', Severity.normal);
    // 🟡 注意軌：回應無恙不代表沒事——記一筆趨勢，累積到門檻就轉督導追蹤。
    _recordFallTrend(elderId, event);
  }

  /// 記錄一次「疑似跌倒但回應無恙」；達門檻且尚無未結追蹤單，就開督導追蹤待辦。
  void _recordFallTrend(String elderId, RadioEvent triggerEvent) {
    final now = DateTime.now();
    final hits = _fallTrend.putIfAbsent(elderId, () => <DateTime>[])
      ..add(now)
      ..removeWhere((t) => now.difference(t) > followUpWindow);
    if (hits.length >= followUpThreshold && !_hasOpenFollowUp(elderId)) {
      _createFollowUp(elderId, triggerEvent, hits.length);
      hits.clear();
    }
  }

  bool _hasOpenFollowUp(String elderId) => _tasks.any((t) =>
      t.elderId == elderId &&
      t.kind == DispatchKind.followUp &&
      t.status != DispatchStatus.resolved);

  /// 開一張督導追蹤待辦：定向給該長輩的督導個管／居督（workerName），
  /// 不派志工、不開放全體、不推播志工端；長輩燈號升為「需要留意」讓後台置頂。
  void _createFollowUp(String elderId, RadioEvent triggerEvent, int trendCount) {
    final elder = _elderById(elderId);
    final supervisor = elder.supervisorWorkerName ?? pickWorker().name;
    final now = DateTime.now();
    final task = DispatchTask(
      id: _nextId('task'),
      elderId: elderId,
      eventId: triggerEvent.id,
      kind: DispatchKind.followUp,
      status: DispatchStatus.pending,
      workerName: supervisor,
      // assignee＝督導本人，代表「已定向負責」，不會落入志工可搶單池。
      assigneeName: supervisor,
      createdAt: now,
    );
    _tasks.add(task);
    _tasksCtrl.add(currentTasks);
    _setElderSeverity(elderId, Severity.attention);
    _notify(
        '${elder.name} 近期第 $trendCount 次疑似跌倒（均自行回應無恙），'
        '已為督導個管 $supervisor 開立追蹤訪視待辦（非緊急、不派志工）',
        Severity.attention);
  }

  @override
  Future<void> acceptTask(String taskId,
      {required int etaMinutes, String? assigneeName, String? assigneeId}) async {
    _acceptTask(taskId, assignee: assigneeName ?? '我', etaMinutes: etaMinutes);
  }

  @override
  Future<void> assignVolunteer(String taskId,
      {required String volunteerName, String? volunteerId}) async {
    final task = _taskById(taskId);
    if (task.status != DispatchStatus.pending) return;
    // 指派時就估 ETA（志工座標→長輩家），家屬端才有真實時間、不是「—」。
    final elder = _elderById(task.elderId);
    final vi = _volunteers.indexWhere((v) => v.name == volunteerName);
    int? eta;
    if (vi >= 0) {
      final v = _volunteers[vi];
      if (!(v.lat == 0 && v.lng == 0) && !(elder.lat == 0 && elder.lng == 0)) {
        eta = estimateEtaMinutes(v.lat, v.lng, elder.lat, elder.lng);
      }
    }
    _updateTask(task.copyWith(assigneeName: volunteerName, etaMinutes: eta));
    _notify('社工已指派 $volunteerName 前往 ${elder.name}', Severity.attention);
  }

  @override
  Future<void> markArrived(String taskId) async {
    final task = _taskById(taskId);
    if (task.status != DispatchStatus.accepted) return;
    _updateTask(task.copyWith(
        status: DispatchStatus.arrived, arrivedAt: DateTime.now()));
    _notify('${task.assigneeName} 已到場，確認 ${_elderById(task.elderId).name} 狀況中',
        Severity.attention);
  }

  @override
  Future<void> setElderLang(String elderId, ElderLang lang) async {
    final i = _elders.indexWhere((e) => e.id == elderId);
    if (i < 0) return;
    _elders[i] = _elders[i].copyWith(preferredLang: lang);
    _eldersCtrl.add(currentElders);
  }

  @override
  Future<void> updateTaskEta(String taskId, int etaMinutes) async {
    final i = _tasks.indexWhere((t) => t.id == taskId);
    if (i < 0) return;
    _tasks[i] = _tasks[i].copyWith(etaMinutes: etaMinutes);
    _tasksCtrl.add(currentTasks);
  }

  @override
  Future<void> setVolunteerLocation(
      String volunteerName, double lat, double lng) async {
    final i = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (i < 0) return;
    final v = _volunteers[i];
    _volunteers[i] = Volunteer(
      id: v.id,
      name: v.name,
      phone: v.phone,
      lat: lat,
      lng: lng,
      online: v.online,
      points: v.points,
      intro: v.intro,
      serviceHours: v.serviceHours,
      certificates: v.certificates,
      locationUpdatedAt: DateTime.now(), // 真實 GPS 回報時間戳
    );
    _volCtrl.add(currentVolunteers);
  }

  @override
  Future<void> setVolunteerOnline(String volunteerName, bool online) async {
    final i = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (i < 0) return;
    final v = _volunteers[i];
    _volunteers[i] = Volunteer(
      id: v.id,
      name: v.name,
      phone: v.phone,
      lat: v.lat,
      lng: v.lng,
      online: online,
      points: v.points,
      intro: v.intro,
      serviceHours: v.serviceHours,
      certificates: v.certificates,
      locationUpdatedAt: v.locationUpdatedAt,
    );
    _volCtrl.add(currentVolunteers);
  }

  @override
  Future<void> submitCertificate(String volunteerName, CertKind kind,
      {DateTime? issuedAt, DateTime? expiresAt, String? note}) async {
    final i = _volunteers.indexWhere((v) => v.name == volunteerName);
    if (i < 0) return;
    final v = _volunteers[i];
    // 同種證件只留一筆：移除舊的、加上一筆「審核中」。
    final certs = List<VolunteerCertificate>.from(v.certificates)
      ..removeWhere((c) => c.kind == kind)
      ..add(VolunteerCertificate(
        kind: kind,
        status: CertStatus.pending,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        note: note ?? '已送出，等待社工審核',
      ));
    _volunteers[i] = Volunteer(
      id: v.id,
      name: v.name,
      phone: v.phone,
      lat: v.lat,
      lng: v.lng,
      online: v.online,
      points: v.points,
      intro: v.intro,
      serviceHours: v.serviceHours,
      certificates: certs,
      locationUpdatedAt: v.locationUpdatedAt,
    );
    _volCtrl.add(currentVolunteers);
  }

  @override
  Future<void> setElderNote(String elderId, String? note) async {
    final i = _elders.indexWhere((e) => e.id == elderId);
    if (i < 0) return;
    final clean = (note == null || note.trim().isEmpty) ? null : note.trim();
    final e = _elders[i];
    // 直接重建（copyWith 無法把 note 設回 null＝清空）
    _elders[i] = Elder(
      id: e.id,
      name: e.name,
      age: e.age,
      address: e.address,
      phone: e.phone,
      lat: e.lat,
      lng: e.lng,
      severity: e.severity,
      preferredLang: e.preferredLang,
      deviceSerial: e.deviceSerial,
      lastActivityAt: e.lastActivityAt,
      note: clean,
      supervisorWorkerName: e.supervisorWorkerName,
      supervisorVolunteerName: e.supervisorVolunteerName,
    );
    _eldersCtrl.add(currentElders);
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
    final i = _elders.indexWhere((e) => e.id == elderId);
    if (i < 0) return;
    String? clean(String? s) =>
        (s == null || s.trim().isEmpty) ? null : s.trim();
    final e = _elders[i];
    // 直接重建（copyWith 蓋不到 name/address 等，也無法把 phone/note 設回 null）。
    _elders[i] = Elder(
      id: e.id,
      name: name.trim(),
      age: age,
      address: address.trim(),
      phone: clean(phone),
      lat: lat ?? e.lat, // 沒帶座標＝保留原本地圖定位
      lng: lng ?? e.lng,
      severity: e.severity,
      preferredLang: e.preferredLang,
      deviceSerial: e.deviceSerial,
      lastActivityAt: e.lastActivityAt,
      note: clean(note),
      supervisorWorkerName: e.supervisorWorkerName,
      supervisorVolunteerName: e.supervisorVolunteerName,
    );
    _eldersCtrl.add(currentElders);
  }

  @override
  Future<int> timeBankMinutesFor(String volunteerName) async {
    // 真實時數：該志工完成（resolved）的派遣單時間銀行分鐘加總 + 種子基底。
    final base = _volunteers
        .where((v) => v.name == volunteerName)
        .fold<int>(0, (s, v) => s + v.points);
    final earned = _tasks
        .where((t) =>
            t.status == DispatchStatus.resolved &&
            t.assigneeName == volunteerName)
        .fold<int>(0, (s, t) => s + t.timeBankMinutes);
    return base + earned - (_redeemed[volunteerName] ?? 0);
  }

  final Map<String, int> _redeemed = {}; // 已兌換扣除的分鐘（name → 累計）

  @override
  Future<int> redeemTimeBank(
      String volunteerName, int minutes, String reason) async {
    _redeemed[volunteerName] = (_redeemed[volunteerName] ?? 0) + minutes;
    return timeBankMinutesFor(volunteerName);
  }

  @override
  Future<void> resolveTask(String taskId,
      {String? note, String? outcome, String? photoUrl}) async {
    final task = _taskById(taskId);
    if (task.status == DispatchStatus.resolved) return;
    final cleanNote =
        (note != null && note.trim().isNotEmpty) ? note.trim() : null;
    final cleanOutcome = (outcome != null && outcome.trim().isNotEmpty)
        ? outcome.trim()
        : null;
    // 🟡 督導追蹤結案：是個管／居督的專業處置，不計時間銀行、不發志工「已安全」通知。
    if (task.kind == DispatchKind.followUp) {
      _updateTask(task.copyWith(
          status: DispatchStatus.resolved,
          resolvedAt: DateTime.now(),
          note: cleanNote,
          outcome: cleanOutcome,
          proofPhotoUrl: photoUrl));
      _updateEvent(
          _eventById(task.eventId).copyWith(status: RadioEventStatus.closed));
      _setElderSeverity(task.elderId, Severity.normal);
      _notify(
          '${_elderById(task.elderId).name} 的督導追蹤已完成'
          '（個管 ${task.workerName}${cleanOutcome != null ? '：$cleanOutcome' : ''}）',
          Severity.normal);
      return;
    }
    _updateTask(task.copyWith(
        status: DispatchStatus.resolved,
        resolvedAt: DateTime.now(),
        note: cleanNote,
        outcome: cleanOutcome,
        proofPhotoUrl: photoUrl));
    _updateEvent(
        _eventById(task.eventId).copyWith(status: RadioEventStatus.closed));
    _setElderSeverity(task.elderId, Severity.normal);
    final mins = task.timeBankMinutes;
    _points += mins;
    _pointsCtrl.add(_points);
    final name = _elderById(task.elderId).name;
    _notify(
        task.kind == DispatchKind.emergency
            ? '$name 已安全，任務完成（時間銀行 +$mins 分）'
            : '$name 物資已送達（時間銀行 +$mins 分）',
        Severity.normal);
  }

  @override
  Future<String> uploadProofPhoto(String taskId, Uint8List bytes,
      {String contentType = 'image/jpeg'}) async {
    // 離線 demo：沒有真儲存桶，直接回傳 data URI，UI 一樣顯示得出拍到的照片。
    await Future.delayed(const Duration(milliseconds: 200));
    return 'data:$contentType;base64,${base64Encode(bytes)}';
  }

  @override
  Future<void> requestSupport(String taskId) async {
    final task = _taskById(taskId);
    // offeredUntil 設為現在 → 立即過期 → 全體志工可接單；同時清掉定向指派，
    // 否則緊急單仍只定向給原本那位（demo 才不會出現「按了支援卻沒開放」）。
    _updateTask(task.copyWith(
        offeredUntil: DateTime.now(), clearAssignee: true));
    _notify('已請求支援，開放全體志工接單 ${_elderById(task.elderId).name}',
        Severity.attention);
  }

  @override
  Future<void> cancelSupplyTask(String taskId, {String? note}) async {
    final task = _taskById(taskId);
    if (task.status == DispatchStatus.resolved) return;
    _updateTask(task.copyWith(
        status: DispatchStatus.resolved,
        resolvedAt: DateTime.now(),
        note: note ?? '家屬自行處理，未派工'));
    _updateEvent(
        _eventById(task.eventId).copyWith(status: RadioEventStatus.closed));
    _setElderSeverity(task.elderId, Severity.normal);
    _notify('${_elderById(task.elderId).name} 的物資需求由家屬自行處理，已取消派工',
        Severity.normal);
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _eldersCtrl.close();
    _eventsCtrl.close();
    _tasksCtrl.close();
    _notifCtrl.close();
    _pointsCtrl.close();
    _volCtrl.close();
    _msgCtrl.close();
    _callCtrl.close();
  }

  static List<Volunteer> _seedVolunteers() => [
        Volunteer(
          id: 'vol-1',
          name: '阿明',
          phone: '0921-000-111',
          lat: 25.0345,
          lng: 121.5672,
          points: 12,
          intro: '信義在地・機車代購快手',
          serviceHours: const [
            ServiceHourSlot(
                weekdays: {1, 2, 3, 4, 5, 6, 7}, startHour: 0, endHour: 24),
          ],
          certificates: [
            VolunteerCertificate(
                kind: CertKind.goodCitizen,
                status: CertStatus.valid,
                issuedAt: DateTime(2025, 6, 1),
                expiresAt: DateTime(2027, 6, 1)),
            VolunteerCertificate(
                kind: CertKind.insurance,
                status: CertStatus.valid,
                issuedAt: DateTime(2026, 1, 1),
                expiresAt: DateTime(2026, 12, 31)),
            VolunteerCertificate(
                kind: CertKind.basicTraining,
                status: CertStatus.valid,
                issuedAt: DateTime(2025, 3, 10),
                note: '已完成 8 小時基礎照護課程'),
          ],
        ),
        Volunteer(
          id: 'vol-2',
          name: '秀蘭',
          phone: '0921-222-333',
          lat: 25.0270,
          lng: 121.5440,
          points: 8,
          intro: '大安・退休護理師',
          serviceHours: const [
            ServiceHourSlot(
                weekdays: {1, 2, 3, 4, 5}, startHour: 9, endHour: 17),
          ],
          certificates: [
            VolunteerCertificate(
                kind: CertKind.goodCitizen,
                status: CertStatus.valid,
                issuedAt: DateTime(2024, 11, 1),
                expiresAt: DateTime(2026, 11, 1)),
            VolunteerCertificate(
                kind: CertKind.insurance, status: CertStatus.pending),
            VolunteerCertificate(
                kind: CertKind.basicTraining,
                status: CertStatus.valid,
                issuedAt: DateTime(2024, 5, 20),
                note: '護理背景，已認列基礎照護'),
          ],
        ),
        Volunteer(
          id: 'vol-3',
          name: '俊傑',
          phone: '0921-444-555',
          lat: 25.0500,
          lng: 121.5580,
          online: false,
          points: 20,
          intro: '松山・週末志工',
          serviceHours: const [
            ServiceHourSlot(weekdays: {6, 7}, startHour: 8, endHour: 20),
          ],
          certificates: const [
            VolunteerCertificate(
                kind: CertKind.goodCitizen, status: CertStatus.none),
            VolunteerCertificate(
                kind: CertKind.insurance, status: CertStatus.none),
            VolunteerCertificate(
                kind: CertKind.basicTraining, status: CertStatus.pending),
          ],
        ),
        Volunteer(
          id: 'vol-4',
          name: '家豪',
          phone: '0921-666-777',
          lat: 25.0410,
          lng: 121.5710,
          points: 5,
          intro: '信義・下班順路幫手',
          serviceHours: const [
            ServiceHourSlot(
                weekdays: {1, 2, 3, 4, 5, 6, 7}, startHour: 0, endHour: 24),
          ],
          certificates: [
            VolunteerCertificate(
                kind: CertKind.goodCitizen,
                status: CertStatus.valid,
                issuedAt: DateTime(2025, 9, 1),
                expiresAt: DateTime(2027, 9, 1)),
            VolunteerCertificate(
                kind: CertKind.insurance,
                status: CertStatus.valid,
                issuedAt: DateTime(2026, 1, 1),
                expiresAt: DateTime(2026, 12, 31)),
            VolunteerCertificate(
                kind: CertKind.basicTraining, status: CertStatus.pending),
          ],
        ),
        Volunteer(
          id: 'vol-5',
          name: '淑惠',
          phone: '0921-888-999',
          lat: 25.0570,
          lng: 121.5330,
          points: 15,
          intro: '中山・全職照服員',
          serviceHours: const [
            ServiceHourSlot(
                weekdays: {1, 2, 3, 4, 5}, startHour: 8, endHour: 18),
          ],
          certificates: [
            VolunteerCertificate(
                kind: CertKind.goodCitizen,
                status: CertStatus.valid,
                issuedAt: DateTime(2025, 2, 15),
                expiresAt: DateTime(2027, 2, 15)),
            VolunteerCertificate(
                kind: CertKind.insurance,
                status: CertStatus.valid,
                issuedAt: DateTime(2026, 1, 1),
                expiresAt: DateTime(2026, 12, 31)),
            VolunteerCertificate(
                kind: CertKind.basicTraining,
                status: CertStatus.valid,
                issuedAt: DateTime(2024, 8, 1),
                note: '照服員資格，已認列基礎照護'),
          ],
        ),
        Volunteer(
          id: 'vol-6',
          name: '志偉',
          phone: '0922-111-000',
          lat: 25.0630,
          lng: 121.5150,
          points: 3,
          intro: '大同・熱血青年',
          serviceHours: const [
            ServiceHourSlot(
                weekdays: {1, 2, 3, 4, 5, 6, 7}, startHour: 0, endHour: 24),
          ],
          certificates: [
            VolunteerCertificate(
                kind: CertKind.goodCitizen,
                status: CertStatus.valid,
                issuedAt: DateTime(2026, 3, 1),
                expiresAt: DateTime(2028, 3, 1)),
            VolunteerCertificate(
                kind: CertKind.insurance, status: CertStatus.pending),
            VolunteerCertificate(
                kind: CertKind.basicTraining, status: CertStatus.none),
          ],
        ),
      ];

  void _escalate(String eventId) {
    final event = _eventById(eventId);
    if (event.status != RadioEventStatus.open) return;
    _updateEvent(event.copyWith(
        status: RadioEventStatus.escalated, severity: Severity.emergency));
    _setElderSeverity(event.elderId, Severity.emergency);
    final elder = _elderById(event.elderId);
    _notify('緊急：${elder.name} 疑似跌倒且 ${escalateAfter.inSeconds} 秒未回應，已派遣志工',
        Severity.emergency);
    _createTask(event, DispatchKind.emergency);
  }

  /// 某位志工目前手上未結案的任務數（含已派給他但未接的單），用於派單負載平衡。
  int _volunteerLoad(String name) => _tasks
      .where((t) => t.assigneeName == name && t.status != DispatchStatus.resolved)
      .length;

  void _createTask(RadioEvent event, DispatchKind kind,
      {List<String> items = const []}) {
    final now = DateTime.now();
    final worker = pickWorker(now: now);
    final elder = _elderById(event.elderId);
    // 派單：物資單先 offer 給督導志工（3 分鐘寬限）；緊急單依距離＋志工在辦任務量
    // 自動派單給最適合者（emergencyDispatchWindow 內未接再退回全體廣播）。
    String? assignee;
    DateTime? offeredUntil;
    Volunteer? picked;
    if (kind == DispatchKind.supply) {
      assignee = elder.supervisorVolunteerName;
      offeredUntil = now.add(const Duration(minutes: 3));
    } else {
      picked = pickVolunteer(_volunteers, elder.lat, elder.lng, _volunteerLoad,
          now: now);
      if (picked != null) {
        assignee = picked.name;
        offeredUntil = now.add(emergencyDispatchWindow);
      }
    }
    final task = DispatchTask(
      id: _nextId('task'),
      elderId: event.elderId,
      eventId: event.id,
      kind: kind,
      status: DispatchStatus.pending,
      workerName: worker.name,
      items: items,
      createdAt: now,
      assigneeName: assignee,
      offeredUntil: offeredUntil,
    );
    _tasks.add(task);
    _tasksCtrl.add(currentTasks);
    _notify(
        '已指派社工 ${worker.name}（${worker.onDuty(now) ? '值班中' : '非值班支援'}，'
        '目前 ${workerLoad(worker.name)} 件）督導本單',
        Severity.attention);
    if (picked != null) {
      final eta = estimateEtaMinutes(picked.lat, picked.lng, elder.lat, elder.lng);
      _notify(
          '已就近派單給 ${picked.name}（約 $eta 分鐘可到，手上 ${_volunteerLoad(picked.name) - 1} 件），'
          '${emergencyDispatchWindow.inMinutes} 分鐘內未確認前往將自動改派更近的人',
          Severity.attention);
      // 3 分鐘未接單／未動身 → 自動改派下一位更近者並廣播請支援。
      _scheduleReassign(task.id);
    }
    if (autoVolunteer) _scheduleAutoVolunteer(task.id);
  }

  /// 排定「3 分鐘未確認前往就自動改派」的計時器（緊急單卡單防呆）。
  void _scheduleReassign(String taskId) {
    _timers['reassign-$taskId']?.cancel();
    _timers['reassign-$taskId'] =
        Timer(emergencyDispatchWindow, () => _reassignEmergency(taskId));
  }

  /// 逾時仍 pending（沒人確認接單）→ 改派下一位更近者；沒有其他人選就開放全體。
  void _reassignEmergency(String taskId) {
    _timers.remove('reassign-$taskId');
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx < 0) return;
    final task = _tasks[idx];
    if (task.kind != DispatchKind.emergency ||
        task.status != DispatchStatus.pending) {
      return; // 已被接單／結案 → 不需改派
    }
    final elder = _elderById(task.elderId);
    final exclude = {if (task.assigneeName != null) task.assigneeName!};
    final next = pickVolunteer(_volunteers, elder.lat, elder.lng, _volunteerLoad,
        exclude: exclude);
    if (next != null) {
      final eta = estimateEtaMinutes(next.lat, next.lng, elder.lat, elder.lng);
      _updateTask(task.copyWith(
          assigneeName: next.name,
          offeredUntil: DateTime.now().add(emergencyDispatchWindow)));
      _notify(
          '🚨 請支援 ${elder.name}（${elder.address}）：'
          '原志工逾時未動身，已改派就近的 ${next.name}（約 $eta 分鐘可到），其他志工也可接單補位',
          Severity.emergency);
      _scheduleReassign(taskId); // 新的一輪計時
    } else {
      // 沒有其他人選 → 開放全體搶單補位。
      _updateTask(task.copyWith(
          clearAssignee: true, offeredUntil: DateTime.now()));
      _notify('🚨 請支援 ${elder.name}（${elder.address}）：目前無就近志工，已開放全體接單',
          Severity.emergency);
    }
  }

  void _scheduleAutoVolunteer(String taskId) {
    _timers['auto-accept-$taskId'] = Timer(autoAcceptDelay, () {
      _timers.remove('auto-accept-$taskId');
      // 派單模擬：由被派到的志工接單（沒派到人才退回預設志工），ETA 依其實際距離估。
      final t = _taskById(taskId);
      final elder = _elderById(t.elderId);
      final assignee = t.assigneeName ?? autoVolunteerName;
      final matches = _volunteers.where((x) => x.name == assignee);
      final eta = matches.isEmpty
          ? 6
          : estimateEtaMinutes(
              matches.first.lat, matches.first.lng, elder.lat, elder.lng);
      _acceptTask(taskId, assignee: assignee, etaMinutes: eta);
      _timers['auto-arrive-$taskId'] = Timer(autoArriveDelay, () {
        _timers.remove('auto-arrive-$taskId');
        markArrived(taskId);
        _timers['auto-resolve-$taskId'] = Timer(autoResolveDelay, () {
          _timers.remove('auto-resolve-$taskId');
          final t = _taskById(taskId);
          resolveTask(taskId,
              note: t.kind == DispatchKind.emergency
                  ? '現場確認長輩狀況穩定，已扶起休息，無明顯外傷'
                  : '物資已送達並放到廚房，長輩已收到');
        });
      });
    });
  }

  void _acceptTask(String taskId,
      {required String assignee, required int etaMinutes}) {
    final task = _taskById(taskId);
    if (task.status != DispatchStatus.pending) return;
    // 有人確認接單 → 取消自動改派計時器（不再視為卡單）。
    _timers.remove('reassign-$taskId')?.cancel();
    _updateTask(task.copyWith(
        status: DispatchStatus.accepted,
        assigneeName: assignee,
        etaMinutes: etaMinutes,
        acceptedAt: DateTime.now()));
    _notify(
        '$assignee 已接單，預計 $etaMinutes 分鐘到達 ${_elderById(task.elderId).name} 家',
        Severity.attention);
  }

  RadioEvent _addEvent(String elderId, RadioEventType type, Severity severity,
      RadioEventStatus status,
      {String? transcript}) {
    final event = RadioEvent(
      id: _nextId('event'),
      elderId: elderId,
      type: type,
      status: status,
      severity: severity,
      occurredAt: DateTime.now(),
      transcript: transcript,
    );
    _events.add(event);
    _eventsCtrl.add(currentEvents);
    return event;
  }

  void _updateEvent(RadioEvent event) {
    final i = _events.indexWhere((e) => e.id == event.id);
    _events[i] = event;
    _eventsCtrl.add(currentEvents);
  }

  void _updateTask(DispatchTask task) {
    final i = _tasks.indexWhere((t) => t.id == task.id);
    _tasks[i] = task;
    _tasksCtrl.add(currentTasks);
  }

  void _setElderSeverity(String elderId, Severity severity) {
    final i = _elders.indexWhere((e) => e.id == elderId);
    _elders[i] = _elders[i]
        .copyWith(severity: severity, lastActivityAt: DateTime.now());
    _eldersCtrl.add(currentElders);
  }

  void _notify(String message, Severity severity) {
    _notifCtrl.add(AppNotification(
      id: _nextId('notif'),
      message: message,
      severity: severity,
      at: DateTime.now(),
    ));
  }

  Elder _elderById(String id) => _elders.firstWhere((e) => e.id == id);

  RadioEvent _eventById(String id) => _events.firstWhere((e) => e.id == id);

  DispatchTask _taskById(String id) => _tasks.firstWhere((t) => t.id == id);

  RadioEvent? _openFallEventOf(String elderId) {
    for (final e in _events.reversed) {
      if (e.elderId == elderId &&
          e.type == RadioEventType.fallSuspected &&
          e.status == RadioEventStatus.open) {
        return e;
      }
    }
    return null;
  }

  String _nextId(String prefix) => '$prefix-${++_idSeq}';

  List<Elder> _seedElders() {
    final now = DateTime.now();
    return [
      Elder(
        id: 'elder-1',
        name: '林阿春',
        age: 82,
        address: '110臺北市信義區安康里松仁路123號',
        phone: '02-2758-1234',
        lat: 25.0358,
        lng: 121.5665,
        severity: Severity.normal,
        preferredLang: ElderLang.taigi,
        deviceSerial: 'JS-0001',
        lastActivityAt: now.subtract(const Duration(minutes: 12)),
        note: '獨居，膝關節退化行動較慢，需注意跌倒',
        supervisorWorkerName: '王淑芬',
        supervisorVolunteerName: '阿明',
      ),
      Elder(
        id: 'elder-2',
        name: '王金火',
        age: 78,
        address: '彰化縣員林市民權街 8 巷 3 號',
        lat: 23.9589,
        lng: 120.5747,
        severity: Severity.normal,
        preferredLang: ElderLang.mandarin,
        deviceSerial: 'JS-0002',
        lastActivityAt: now.subtract(const Duration(minutes: 45)),
        note: '高血壓，與女兒同住但白天獨自在家',
        supervisorWorkerName: '李建成',
        supervisorVolunteerName: '秀蘭',
      ),
      Elder(
        id: 'elder-3',
        name: '陳玉蘭',
        age: 86,
        address: '雲林縣斗六市大學路二段 56 號',
        lat: 23.7126,
        lng: 120.5411,
        severity: Severity.normal,
        preferredLang: ElderLang.taigi,
        deviceSerial: 'JS-0003',
        lastActivityAt: now.subtract(const Duration(hours: 2)),
        note: '獨居，輕度失智，作息日夜顛倒需留意',
        supervisorWorkerName: '張美惠',
        supervisorVolunteerName: '俊傑',
      ),
    ];
  }

  static List<SocialWorker> _seedWorkers() => const [
        SocialWorker(
            id: 'worker-1',
            name: '王淑芬',
            phone: '0921-111-222',
            shiftStartHour: 8,
            shiftEndHour: 16),
        SocialWorker(
            id: 'worker-2',
            name: '李建成',
            phone: '0933-333-444',
            shiftStartHour: 16,
            shiftEndHour: 24),
        SocialWorker(
            id: 'worker-3',
            name: '張美惠',
            phone: '0955-555-666',
            shiftStartHour: 0,
            shiftEndHour: 8),
      ];
}
