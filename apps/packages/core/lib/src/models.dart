import 'dart:math';

enum Severity { normal, attention, emergency }

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0; // 地球半徑 km
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// 估算道路距離（km）：直線距離×1.3。座標未知時回退 1.0。
double roadDistanceKm(
    double fromLat, double fromLng, double toLat, double toLng) {
  if ((fromLat == 0 && fromLng == 0) || (toLat == 0 && toLng == 0)) return 1.0;
  return _haversineKm(fromLat, fromLng, toLat, toLng) * 1.3;
}

/// 依「志工位置 → 長輩家」的距離估算抵達分鐘數。
/// 機車市區均速（含紅燈）約 18 km/h。回傳 ≥1 分。
int estimateEtaMinutes(double fromLat, double fromLng, double toLat, double toLng,
    {double speedKmh = 18}) {
  if ((fromLat == 0 && fromLng == 0) || (toLat == 0 && toLng == 0)) return 5;
  final roadKm = _haversineKm(fromLat, fromLng, toLat, toLng) * 1.3;
  return (roadKm / speedKmh * 60).ceil().clamp(1, 120);
}

/// 緊急單就近派單的「確認並動身」時效：派給最適合志工後，這段時間內未接單／未動身，
/// 就自動改派給下一位更近的人並廣播「請支援」給全體志工（其他人也能接單補位）。
/// 事件本身的 20 秒黃金升級（偵測→AI 詢問→派單）在此之前已完成，這是「志工回應」的 SLA。
const emergencyDispatchWindow = Duration(minutes: 3);

/// 派單評分：抵達分鐘（距離）＋ 手上在辦任務量的懲罰，分數越低越優先派。
/// [loadPenaltyMinutes]：每多背一件在辦任務等同「多這麼多分鐘車程」的權重，
/// 讓忙碌志工把單讓給較閒、稍遠但整體能更快到位的人（負載平衡）。
double dispatchScore(int etaMinutes, int currentLoad,
        {double loadPenaltyMinutes = 8}) =>
    etaMinutes + currentLoad * loadPenaltyMinutes;

/// 緊急單自動派單：從志工名單挑最適合前往 [elderLat],[elderLng] 的人。
///
/// 篩選：上線且有座標者；優先「目前在可服務時段內」的人，若全部都不在服務時段，
/// 才放寬到全部上線者（保住黃金時效——寧可派非時段志工也要有人前往）。
/// 排序：[dispatchScore]（距離 + 在辦任務量）最低者優先。
/// [loadOf] 回傳某志工目前手上未結案的任務數。無合適志工時回 null（呼叫端退回全體廣播）。
Volunteer? pickVolunteer(
  List<Volunteer> volunteers,
  double elderLat,
  double elderLng,
  int Function(String volunteerName) loadOf, {
  DateTime? now,
  double loadPenaltyMinutes = 8,
  Set<String> exclude = const {},
}) {
  final at = now ?? DateTime.now();
  final onlineWithLoc = volunteers
      .where((v) =>
          v.online && !(v.lat == 0 && v.lng == 0) && !exclude.contains(v.name))
      .toList();
  if (onlineWithLoc.isEmpty) return null;
  final available = onlineWithLoc.where((v) => v.availableAt(at)).toList();
  final pool = available.isNotEmpty ? available : onlineWithLoc;
  double scoreOf(Volunteer v) => dispatchScore(
      estimateEtaMinutes(v.lat, v.lng, elderLat, elderLng), loadOf(v.name),
      loadPenaltyMinutes: loadPenaltyMinutes);
  pool.sort((a, b) => scoreOf(a).compareTo(scoreOf(b)));
  return pool.first;
}

/// 志工是否已抵達長輩家附近（直線距離 ≤ 門檻，預設 60 公尺）。
/// 用即時定位自動判定「到場」，志工不需手動按「我到了」。
bool isNearbyMeters(double fromLat, double fromLng, double toLat, double toLng,
    {double meters = 60}) {
  if ((fromLat == 0 && fromLng == 0) || (toLat == 0 && toLng == 0)) return false;
  return _haversineKm(fromLat, fromLng, toLat, toLng) * 1000 <= meters;
}

enum RadioEventType { sos, fallSuspected, supplyRequest }

enum RadioEventStatus { open, confirmedOk, escalated, closed }

enum DispatchKind { emergency, supply, followUp }

/// 派遣單類型的中文標籤（社工後台顯示／Excel 匯出用）。
/// followUp＝督導追蹤：由「疑似跌倒趨勢」自動開立、路由給督導個管／居督的
/// 非緊急待辦，不派志工、不推播（對應三軌分流的 🟡 注意軌）。
extension DispatchKindLabel on DispatchKind {
  String get label => switch (this) {
        DispatchKind.emergency => '緊急',
        DispatchKind.supply => '物資',
        DispatchKind.followUp => '督導追蹤',
      };
}

enum DispatchStatus { pending, accepted, arrived, resolved }

/// 長輩偏好語言（收音機 TTS 播報用；家屬 App 設定）
enum ElderLang { mandarin, taigi }

extension ElderLangLabel on ElderLang {
  String get label => this == ElderLang.taigi ? '台語' : '國語';
  String get wire => this == ElderLang.taigi ? 'taigi' : 'mandarin';
}

class Elder {
  final String id;
  final String name;
  final int age;
  final String address;
  final String? phone; // 長輩／家中聯絡電話（家屬緊急撥打用；無則按鈕停用）
  final double lat; // 地圖定位（WGS84）
  final double lng;
  final Severity severity;
  final ElderLang preferredLang; // 偏好語言（國語／台語）
  final String? deviceSerial; // 收音機序號（JS-0001…；硬體模擬頁用）
  final DateTime lastActivityAt;
  final String? note; // 簡單狀況注記（獨居／慢性病／行動狀況等，社工填寫）
  final String? supervisorWorkerName; // 督導社工（長期指定，非單次派遣）
  final String? supervisorVolunteerName; // 督導志工（長期關懷此長輩的志工）

  const Elder({
    required this.id,
    required this.name,
    required this.age,
    required this.address,
    this.phone,
    this.lat = 0,
    this.lng = 0,
    required this.severity,
    this.preferredLang = ElderLang.mandarin,
    this.deviceSerial,
    required this.lastActivityAt,
    this.note,
    this.supervisorWorkerName,
    this.supervisorVolunteerName,
  });

  Elder copyWith({
    Severity? severity,
    ElderLang? preferredLang,
    DateTime? lastActivityAt,
    String? note,
    String? supervisorWorkerName,
    String? supervisorVolunteerName,
  }) =>
      Elder(
        id: id,
        name: name,
        age: age,
        address: address,
        phone: phone,
        lat: lat,
        lng: lng,
        severity: severity ?? this.severity,
        preferredLang: preferredLang ?? this.preferredLang,
        deviceSerial: deviceSerial,
        lastActivityAt: lastActivityAt ?? this.lastActivityAt,
        note: note ?? this.note,
        supervisorWorkerName: supervisorWorkerName ?? this.supervisorWorkerName,
        supervisorVolunteerName:
            supervisorVolunteerName ?? this.supervisorVolunteerName,
      );
}

/// 社工（後台派遣的督導人力）
class SocialWorker {
  final String id;
  final String name;
  final String phone;
  final int shiftStartHour; // 班表（24 小時制，支援跨夜班）
  final int shiftEndHour;

  const SocialWorker({
    required this.id,
    required this.name,
    required this.phone,
    required this.shiftStartHour,
    required this.shiftEndHour,
  });

  String get shiftLabel =>
      '${shiftStartHour.toString().padLeft(2, '0')}:00–${shiftEndHour.toString().padLeft(2, '0')}:00';

  /// 目前是否值班中（支援跨夜，如 22–06）
  bool onDuty(DateTime now) {
    final h = now.hour;
    return shiftStartHour <= shiftEndHour
        ? h >= shiftStartHour && h < shiftEndHour
        : h >= shiftStartHour || h < shiftEndHour;
  }
}

/// 志工（時間銀行人力，可被社工指派）
class Volunteer {
  final String id;
  final String name;
  final String phone;
  final double lat;
  final double lng;
  final bool online;
  final int points;
  final String intro;
  final List<ServiceHourSlot> serviceHours; // 可服務時段（真實資料，非寫死）
  final List<VolunteerCertificate> certificates; // 良民證／意外險／基礎證書
  final DateTime? locationUpdatedAt; // 座標最後一次「真實 GPS」回報時間（seed 為 null）

  const Volunteer({
    required this.id,
    required this.name,
    this.phone = '',
    this.lat = 0,
    this.lng = 0,
    this.online = true,
    this.points = 0,
    this.intro = '',
    this.serviceHours = const [],
    this.certificates = const [],
    this.locationUpdatedAt,
  });

  /// 現在（給定時間）是否在可服務時段內
  bool availableAt(DateTime now) => serviceHours.any((s) => s.covers(now));

  /// 座標是否為「近期真實 GPS」（預設 8 分鐘內回報過才算 live；seed／過期回 false）。
  bool hasLiveLocation(DateTime now, {Duration within = const Duration(minutes: 8)}) {
    if (locationUpdatedAt == null) return false;
    if (lat == 0 && lng == 0) return false;
    return now.difference(locationUpdatedAt!) <= within;
  }
}

/// 可服務時段：一週中的哪幾天、幾點到幾點。
/// [weekdays] 用 DateTime.weekday（1=一 … 7=日）。
class ServiceHourSlot {
  final Set<int> weekdays;
  final int startHour; // 24h
  final int endHour; // 24h，24 代表整天到午夜

  const ServiceHourSlot({
    required this.weekdays,
    required this.startHour,
    required this.endHour,
  });

  bool covers(DateTime now) {
    if (!weekdays.contains(now.weekday)) return false;
    final h = now.hour;
    return startHour <= endHour
        ? h >= startHour && h < endHour
        : h >= startHour || h < endHour; // 支援跨夜
  }

  static const _dayNames = ['一', '二', '三', '四', '五', '六', '日'];

  /// 「平日 18:00–22:00」這類人類可讀標籤
  String get label {
    final named = _daysLabel(weekdays);
    final daysLabel = named ??
        '週${(weekdays.toList()..sort()).map((d) => _dayNames[d - 1]).join('、')}';
    final timeLabel = (startHour == 0 && endHour >= 24)
        ? '全天'
        : '${startHour.toString().padLeft(2, '0')}:00–${endHour.toString().padLeft(2, '0')}:00';
    return '$daysLabel $timeLabel';
  }

  static String? _daysLabel(Set<int> d) {
    const weekday = {1, 2, 3, 4, 5};
    const weekend = {6, 7};
    if (d.length == 7) return '每天';
    if (d.difference(weekday).isEmpty && d.length == 5) return '平日';
    if (d.difference(weekend).isEmpty && d.length == 2) return '週末';
    return null;
  }

  Map<String, dynamic> toJson() =>
      {'weekdays': weekdays.toList()..sort(), 'start': startHour, 'end': endHour};

  factory ServiceHourSlot.fromJson(Map<String, dynamic> j) => ServiceHourSlot(
        weekdays: (j['weekdays'] as List).map((e) => (e as num).toInt()).toSet(),
        startHour: (j['start'] as num).toInt(),
        endHour: (j['end'] as num).toInt(),
      );
}

/// 志工證件類型
enum CertKind { goodCitizen, insurance, basicTraining }

extension CertKindLabel on CertKind {
  String get label => switch (this) {
        CertKind.goodCitizen => '良民證',
        CertKind.insurance => '志工意外險',
        CertKind.basicTraining => '基礎照護證書',
      };
  String get wire => switch (this) {
        CertKind.goodCitizen => 'good_citizen',
        CertKind.insurance => 'insurance',
        CertKind.basicTraining => 'basic_training',
      };
  static CertKind fromWire(String w) => switch (w) {
        'insurance' => CertKind.insurance,
        'basic_training' => CertKind.basicTraining,
        _ => CertKind.goodCitizen,
      };
}

/// 證件審核狀態
enum CertStatus { none, pending, valid, expired }

extension CertStatusLabel on CertStatus {
  String get label => switch (this) {
        CertStatus.none => '未上傳',
        CertStatus.pending => '審核中',
        CertStatus.valid => '有效',
        CertStatus.expired => '已過期',
      };
  String get wire => name;
  static CertStatus fromWire(String? w) => switch (w) {
        'pending' => CertStatus.pending,
        'valid' => CertStatus.valid,
        'expired' => CertStatus.expired,
        _ => CertStatus.none,
      };
}

/// 志工證件紀錄（一位志工每種證件一筆）
class VolunteerCertificate {
  final CertKind kind;
  final CertStatus status;
  final DateTime? issuedAt;
  final DateTime? expiresAt;
  final String? note;

  const VolunteerCertificate({
    required this.kind,
    this.status = CertStatus.none,
    this.issuedAt,
    this.expiresAt,
    this.note,
  });

  /// 是否即將到期（30 天內）
  bool expiringSoon(DateTime now) =>
      status == CertStatus.valid &&
      expiresAt != null &&
      expiresAt!.difference(now).inDays <= 30;
}

class RadioEvent {
  final String id;
  final String elderId;
  final RadioEventType type;
  final RadioEventStatus status;
  final Severity severity;
  final DateTime occurredAt;
  final String? transcript;

  const RadioEvent({
    required this.id,
    required this.elderId,
    required this.type,
    required this.status,
    required this.severity,
    required this.occurredAt,
    this.transcript,
  });

  RadioEvent copyWith({RadioEventStatus? status, Severity? severity}) =>
      RadioEvent(
        id: id,
        elderId: elderId,
        type: type,
        status: status ?? this.status,
        severity: severity ?? this.severity,
        occurredAt: occurredAt,
        transcript: transcript,
      );
}

/// 時間銀行分鐘數的顯示格式：未滿 60 分顯示「N 分」，滿 60 分改「X.X 小時」。
String formatServiceMinutes(int minutes) => minutes >= 60
    ? '${(minutes / 60).toStringAsFixed(1)} 小時'
    : '$minutes 分';

class DispatchTask {
  final String id;
  final String elderId;
  final String eventId;
  final DispatchKind kind;
  final DispatchStatus status;
  final String? assigneeName; // 到場志工
  final String? workerName; // 督導社工（依值班＋單量自動指派）
  final int? etaMinutes;
  final List<String> items;
  final DateTime createdAt; // 開單時間
  final DateTime? acceptedAt; // 志工接單／出發時間
  final DateTime? arrivedAt; // 志工到場時間
  final DateTime? resolvedAt; // 回報結案時間
  final String? note; // 志工到場回報的現場備註（家屬端可見）
  final String? outcome; // 結案處置（確認沒事／送往醫院…），結構化選項
  final String? proofPhotoUrl; // 結案證明照片（Uber 式拍照結單；家屬／後台可看）
  // 物資單「寬限期」：此時間前只offer給家屬＋督導志工，不廣播給全體志工。
  // 到期（或家屬/社工按「請求支援」把它設為過去）即開放全體接單。emergency 為 null＝立即廣播。
  final DateTime? offeredUntil;

  const DispatchTask({
    required this.id,
    required this.elderId,
    required this.eventId,
    required this.kind,
    required this.status,
    this.assigneeName,
    this.workerName,
    this.etaMinutes,
    this.items = const [],
    required this.createdAt,
    this.acceptedAt,
    this.arrivedAt,
    this.resolvedAt,
    this.note,
    this.outcome,
    this.proofPhotoUrl,
    this.offeredUntil,
  });

  DispatchTask copyWith({
    DispatchStatus? status,
    String? assigneeName,
    bool clearAssignee = false, // 開放全體時把定向指派清空（copyWith 無法傳 null）
    String? workerName,
    int? etaMinutes,
    DateTime? acceptedAt,
    DateTime? arrivedAt,
    DateTime? resolvedAt,
    String? note,
    String? outcome,
    String? proofPhotoUrl,
    DateTime? offeredUntil,
  }) =>
      DispatchTask(
        id: id,
        elderId: elderId,
        eventId: eventId,
        kind: kind,
        status: status ?? this.status,
        assigneeName: clearAssignee ? null : (assigneeName ?? this.assigneeName),
        workerName: workerName ?? this.workerName,
        etaMinutes: etaMinutes ?? this.etaMinutes,
        items: items,
        createdAt: createdAt,
        acceptedAt: acceptedAt ?? this.acceptedAt,
        arrivedAt: arrivedAt ?? this.arrivedAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        note: note ?? this.note,
        outcome: outcome ?? this.outcome,
        proofPhotoUrl: proofPhotoUrl ?? this.proofPhotoUrl,
        offeredUntil: offeredUntil ?? this.offeredUntil,
      );

  /// 是否還在物資單寬限期內（只給家屬＋督導志工，未廣播全體）。
  bool get inOfferWindow =>
      offeredUntil != null && DateTime.now().isBefore(offeredUntil!);

  /// 這趟服務的估計時長（分鐘）＝ 志工回報的交通 ETA + 現場處理時間。
  /// 沿用接單紀錄卡的既有慣例（見 volunteer_app/history_page）。
  int get serviceMinutes => (etaMinutes ?? 10) + 6;

  /// 結單存入時間銀行的分鐘數：依服務時長計，緊急派遣加成 ×1.5。
  int get timeBankMinutes => switch (kind) {
        DispatchKind.emergency => (serviceMinutes * 1.5).round(),
        DispatchKind.supply => serviceMinutes,
        // 督導追蹤是個管／居督的專業工時，不計入志工時間銀行。
        DispatchKind.followUp => 0,
      };
}

/// 限時遮罩通話的雙方角色（家屬 ↔ 志工，走 Jitsi in-app 通話）
enum CallRole { family, volunteer }

extension CallRoleWire on CallRole {
  String get wire => this == CallRole.family ? 'family' : 'volunteer';
  static CallRole parse(String s) =>
      s == 'family' ? CallRole.family : CallRole.volunteer;
}

/// 通話號誌狀態：響鈴中 → 接聽／拒接／取消／結束
enum CallStatus { ringing, accepted, declined, canceled, ended }

extension CallStatusWire on CallStatus {
  String get wire => name;
  static CallStatus parse(String s) =>
      CallStatus.values.firstWhere((e) => e.name == s,
          orElse: () => CallStatus.ended);
}

/// 一通限時遮罩通話的號誌（signaling）。
/// 一張派遣單一通話一個 room；結案／掛斷即失效。雙方看不到對方真實號碼，
/// 因為整條鏈路只有 Jitsi room 名稱，沒有電話號碼。
class CallSignal {
  final String id;
  final String taskId;
  final String room; // Jitsi 房間名（不可猜；雙方以此進同一房）
  final CallRole from;
  final CallRole to;
  final CallStatus status;
  final String? fromName; // 來電顯示名（志工可露名；家屬顯示「家屬」）
  final DateTime createdAt;

  const CallSignal({
    required this.id,
    required this.taskId,
    required this.room,
    required this.from,
    required this.to,
    required this.status,
    this.fromName,
    required this.createdAt,
  });
}

/// 派遣單聊天訊息的發送者角色（對應 schema chat_from_t）
enum ChatFromRole { family, volunteer, system }

/// 派遣單上的文字訊息（家屬↔志工，限本次派遣；送出無法收回）
class TaskMessage {
  final String id;
  final String taskId;
  final ChatFromRole fromRole;
  final String? senderId;
  final String text;
  final DateTime createdAt;

  const TaskMessage({
    required this.id,
    required this.taskId,
    required this.fromRole,
    this.senderId,
    required this.text,
    required this.createdAt,
  });
}

class AppNotification {
  final String id;
  final String message;
  final Severity severity;
  final String? elderId; // 關聯長輩（家屬端只跳綁定長輩的通知；null＝不限）
  final DateTime at;

  const AppNotification({
    required this.id,
    required this.message,
    required this.severity,
    this.elderId,
    required this.at,
  });
}
