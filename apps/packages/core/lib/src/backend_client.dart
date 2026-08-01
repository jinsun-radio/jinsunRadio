import 'dart:typed_data';

import 'models.dart';

/// 三端共用的後端介面。實作：[MockBackend]（記憶體，離線 demo）與
/// SupabaseBackend（真後端，三端即時同步）。App 一律用此型別，換後端不改 UI。
abstract class BackendClient {
  Stream<List<Elder>> get elders;
  Stream<List<RadioEvent>> get events;
  Stream<List<DispatchTask>> get tasks;
  Stream<AppNotification> get notifications;
  Stream<int> get timeBankPoints;

  List<Elder> get currentElders;
  List<RadioEvent> get currentEvents;
  List<DispatchTask> get currentTasks;
  int get currentTimeBankPoints;
  List<SocialWorker> get currentWorkers;
  Stream<List<Volunteer>> get volunteers;
  List<Volunteer> get currentVolunteers;

  /// 派遣單聊天訊息（所有 task；UI 依 taskId 過濾）。即時同步。
  Stream<List<TaskMessage>> get messages;
  List<TaskMessage> get currentMessages;

  /// 志工目前手上未結案的派遣數
  int workerLoad(String workerName);

  // ---- 收音機事件（demo 面板 / 硬體模擬）----
  void triggerFallSuspected(String elderId);
  void triggerSos(String elderId);
  void triggerSupplyRequest(String elderId, List<String> items);
  void confirmElderOk(String elderId);

  // ---- 派遣流程 ----
  Future<void> acceptTask(String taskId,
      {required int etaMinutes, String? assigneeName, String? assigneeId});
  Future<void> markArrived(String taskId);
  Future<void> resolveTask(String taskId,
      {String? note, String? outcome, String? photoUrl});

  /// 上傳結案證明照片（Uber 式拍照結單），回傳可公開存取的照片 URL。
  /// 先上傳、拿到 URL 後再帶進 [resolveTask] 的 photoUrl 寫入任務。
  Future<String> uploadProofPhoto(String taskId, Uint8List bytes,
      {String contentType = 'image/jpeg'});

  /// 「請求支援／拒絕改派」：結束目前的寬限／指派，把單交給下一位志工。
  /// - Supabase（正式）：改派給「下一位就近志工」（排除已試過的人，含拒絕者本人）；
  ///   真的沒有其他就近志工時轉請社工協助指派——刻意不「開放全體」，避免與看門狗的
  ///   單點改派衝突、或迴力鏢改派回剛拒絕的同一人（見 SupabaseBackend.requestSupport）。
  /// - Mock（離線 demo）：直接把 offeredUntil 設為現在＝立即開放全體搶單。
  Future<void> requestSupport(String taskId);

  /// 物資單寬限期內：家屬按「我來處理」→ 取消派工、結案（不派志工、不計時數）。
  Future<void> cancelSupplyTask(String taskId, {String? note});

  /// 社工在後台把待接單指派給指定志工（志工端會即時收到）
  Future<void> assignVolunteer(String taskId,
      {required String volunteerName, String? volunteerId});

  /// 家屬設定長輩偏好語言（國語／台語）；收音機播報依此切換
  Future<void> setElderLang(String elderId, ElderLang lang);

  /// 社工在後台編輯長輩狀況注記（「套餐」備註）。三端即時同步。
  Future<void> setElderNote(String elderId, String? note);

  /// 家屬填寫／更新長輩基本資料（姓名、年齡、地址、家中電話、狀況注記）。
  /// 這是社工後台與志工派遣單上「長輩資訊」的唯一真實來源——家屬不填，下游就只有空白。
  /// [lat]／[lng] 由呼叫端（家屬 App）對地址做地理編碼後帶入；帶 null 表示保留原座標。
  /// 三端即時同步。
  Future<void> updateElderProfile(
    String elderId, {
    required String name,
    required int age,
    required String address,
    String? phone,
    String? note,
    double? lat,
    double? lng,
  });

  /// 某位志工累積的時間銀行時數（分鐘），依實際完成的派遣單／帳本加總。
  /// 與 [timeBankPoints]（本 session 累加）不同：這是持久化的真實總時數。
  Future<int> timeBankMinutesFor(String volunteerName);

  /// 用時間銀行時數兌換（寫一筆負值帳，扣除累積時數）。回傳兌換後剩餘分鐘。
  /// 呼叫前 UI 需自行確認餘額足夠。
  Future<int> redeemTimeBank(String volunteerName, int minutes, String reason);

  /// 志工回報自己的即時定位（家屬地圖即時顯示志工位置與路線）
  Future<void> setVolunteerLocation(String volunteerName, double lat, double lng);

  /// 志工切換工作狀態：工作中（online=true，可被派單）／休息中（online=false，不派新單）。
  /// 已接的任務不受影響；休息中時 pickVolunteer 不會挑到這位志工、來單受理也不彈出。
  Future<void> setVolunteerOnline(String volunteerName, bool online);

  /// 志工送出／更新一張證件供審核。狀態一律寫成 [CertStatus.pending]（審核中）——
  /// 志工不能自行核可（良民證等背景審查不可自助通過），需社工端核可後才 valid。
  /// 同一位志工同一種證件只保留一筆（覆蓋舊的）。
  Future<void> submitCertificate(
    String volunteerName,
    CertKind kind, {
    DateTime? issuedAt,
    DateTime? expiresAt,
    String? note,
  });

  /// 依志工移動即時更新某派遣單的預估抵達分鐘數
  Future<void> updateTaskEta(String taskId, int etaMinutes);

  /// 送出一則派遣單聊天訊息（家屬↔志工）。送出即定案，無法收回。
  Future<void> sendTaskMessage(String taskId,
      {required ChatFromRole from, String? senderId, required String text});

  /// 語音輸入轉文字：把錄好的音檔位元組送去雲端 Whisper 做 ASR，回傳辨識文字。
  /// 用於聊天的「按住說話」——轉出的文字先填回輸入框，讓使用者確認後再送出。
  /// [filename] 需帶正確副檔名（如 audio.webm / audio.m4a），Whisper 靠它判斷格式。
  Future<String> transcribeAudio(Uint8List audioBytes,
      {required String filename, String? mimeType, String? prompt});

  // ---- 限時遮罩通話（Jitsi in-app 通話 + 來電號誌）----
  /// 每次通話號誌 insert/update 都推一筆最新狀態（來電響鈴、接聽、掛斷都靠它）。
  Stream<CallSignal> get callSignals;

  /// 發起通話：建立一個 room 與 ringing 號誌，回傳號誌（含 room）。
  /// [room] 可由呼叫端先產（Web 需在點擊當下就開分頁，避免被瀏覽器擋彈窗）。
  Future<CallSignal> startCall({
    required String taskId,
    required CallRole from,
    required CallRole to,
    String? fromName,
    String? room,
  });

  /// 更新通話狀態（接聽／拒接／取消／結束）。
  Future<void> setCallStatus(String signalId, CallStatus status);

  /// 查單一通話號誌的最新狀態（來電推播點進來時確認還在響鈴）。
  /// 預設回 null＝查不到／後端不支援，呼叫端視為「直接信任推播內容」。
  Future<CallSignal?> getCallSignal(String signalId) async => null;

  // ---- 家屬綁定收音機 ----
  // 這幾件事以前是 App 直接打 Supabase（family_app/app_local.dart、admin/hardware_sim.dart、
  // push_service.dart），換後端時會整個斷掉。收進介面之後，三端才真的「完全沒有直接碰
  // 某一家後端」，換後端只需要換一個實作檔。
  // 預設實作為「什麼都不做」，讓 MockBackend 與測試替身不必被迫實作。

  /// 這位家屬已綁定的長輩 id。
  Future<Set<String>> familyBindings(String familyId) async => const {};

  /// 綁定一台收音機（已綁定視為成功，不擋流程）。
  Future<void> bindFamily(String familyId, String elderId) async {}

  // ---- 系統設定（社工後台可即時切換；例：llm_provider、dispatch_tracking）----
  Future<String?> appSetting(String key) async => null;
  Future<void> setAppSetting(String key, String value) async {}

  // ---- 推播 token（送 push 的 Lambda／Edge Function 依此查收件者）----
  Future<void> registerDeviceToken({
    required String token,
    required String role,
    String? platform,
    List<String> elderIds = const [],
  }) async {}
  Future<void> unregisterDeviceToken(String token) async {}

  void dispose();
}
