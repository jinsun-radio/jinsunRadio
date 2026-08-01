import 'models.dart' show Severity;

/// 無鏡頭收音設備：所有事件都由「聲音／語音推論」產生（裝置端本地推論，不外傳影音）。
/// 這一層描述「一起照護事件」從偵測到結束的完整時間軸，供家屬歷史與社工後台 Timeline 共用。
/// 資料一律來自 backend 的真實 RadioEvent + DispatchTask（三端同一份 DB 資料），無展示假資料。

/// 聲音推論觸發類型（裝置端麥克風 + 本地聲學／關鍵字模型）。
enum AcousticTrigger {
  cryForHelp, // 偵測到呼救聲
  loudImpact, // 偵測到大聲撞擊
  noResponseLong, // 長時間沒有回應
  repeatedCalling, // 重複呼喊相同內容
  moaning, // 持續呻吟
  severeCough, // 劇烈咳嗽
  suspectedFall, // 疑似跌倒聲
  helpKeyword, // 求救關鍵字（救命、好痛、快來）
  supplyRequest, // 長輩語音提出物資需求（日常，非緊急）
  routineCheckin, // AI 主動關懷（日常，非緊急）
}

extension AcousticTriggerX on AcousticTrigger {
  String get label => switch (this) {
        AcousticTrigger.cryForHelp => '偵測到呼救聲',
        AcousticTrigger.loudImpact => '偵測到大聲撞擊',
        AcousticTrigger.noResponseLong => '長時間沒有回應',
        AcousticTrigger.repeatedCalling => '重複呼喊相同內容',
        AcousticTrigger.moaning => '持續呻吟聲',
        AcousticTrigger.severeCough => '劇烈咳嗽',
        AcousticTrigger.suspectedFall => '疑似跌倒聲',
        AcousticTrigger.helpKeyword => '聽到求救關鍵字',
        AcousticTrigger.supplyRequest => '物資需求',
        AcousticTrigger.routineCheckin => 'AI 主動關懷',
      };

  /// 是否屬於「需要立即關注」的聲音（物資需求與 routineCheckin 以外都是）。
  bool get isEmergency =>
      this != AcousticTrigger.routineCheckin &&
      this != AcousticTrigger.supplyRequest;
}

/// 事件時間軸的一個步驟（偵測 → AI 確認 → 派遣 → 抵達 → 安全 → 結束）。
enum CareStepKind {
  detected, // 偵測到聲音
  aiConfirming, // AI 主動語音確認中
  elderReplied, // 長輩回應
  noResponse, // 長輩未回應
  notifiedWorker, // 已通知志工
  workerAccepted, // 志工已接案
  workerDeparted, // 志工出發
  workerArrived, // 志工抵達
  confirmedSafe, // 已確認安全
  eventClosed, // 事件結束
}

extension CareStepKindX on CareStepKind {
  String get label => switch (this) {
        CareStepKind.detected => '偵測到聲音',
        CareStepKind.aiConfirming => 'AI 主動確認',
        CareStepKind.elderReplied => '長輩回應',
        CareStepKind.noResponse => '長輩未回應',
        CareStepKind.notifiedWorker => '已通知志工',
        CareStepKind.workerAccepted => '志工接案',
        CareStepKind.workerDeparted => '志工出發',
        CareStepKind.workerArrived => '志工抵達',
        CareStepKind.confirmedSafe => '已確認安全',
        CareStepKind.eventClosed => '事件結束',
      };

  /// 進行中步驟的燈號（給後台 Timeline 圓點上色）。
  Severity get severity => switch (this) {
        CareStepKind.detected ||
        CareStepKind.aiConfirming =>
          Severity.attention,
        CareStepKind.noResponse ||
        CareStepKind.notifiedWorker ||
        CareStepKind.workerAccepted ||
        CareStepKind.workerDeparted ||
        CareStepKind.workerArrived =>
          Severity.emergency,
        CareStepKind.elderReplied ||
        CareStepKind.confirmedSafe ||
        CareStepKind.eventClosed =>
          Severity.normal,
      };
}

class CareStep {
  final CareStepKind kind;
  final DateTime at;
  final String text; // 家屬視角具體文字（不放後台術語）
  const CareStep(this.kind, this.at, this.text);
}

/// 一起完整的照護事件（含整條時間軸）。
class CareEvent {
  final String id;
  final String elderId;
  final String elderName;
  final AcousticTrigger trigger;
  final Severity peakSeverity; // 過程中最高分級
  final List<CareStep> steps;
  final String? detail; // 具體內容（物資品項等），供摘要顯示「到底是什麼事」

  const CareEvent({
    required this.id,
    required this.elderId,
    required this.elderName,
    required this.trigger,
    required this.peakSeverity,
    required this.steps,
    this.detail,
  });

  DateTime get startedAt => steps.isEmpty ? DateTime.now() : steps.first.at;
  DateTime get lastAt => steps.isEmpty ? startedAt : steps.last.at;

  bool get resolved =>
      steps.isNotEmpty && steps.last.kind == CareStepKind.eventClosed;

  /// 目前進行到哪一步（未結束事件用）。
  CareStep? get currentStep => steps.isEmpty ? null : steps.last;

  /// 家屬視角標題（一句話說完發生什麼、現在如何）。
  String get headline {
    if (resolved) {
      final safe = steps.any((s) =>
          s.kind == CareStepKind.confirmedSafe ||
          s.kind == CareStepKind.elderReplied);
      return safe ? '$elderName 已確認安全' : '$elderName 事件已結束';
    }
    // 進行中：依最新步驟講
    final k = currentStep?.kind;
    return switch (k) {
      CareStepKind.detected ||
      CareStepKind.aiConfirming =>
        '$elderName ${trigger.label}，AI 確認中…',
      CareStepKind.noResponse => '$elderName 沒有回應，已派志工前往',
      CareStepKind.notifiedWorker ||
      CareStepKind.workerAccepted ||
      CareStepKind.workerDeparted =>
        '$elderName 需要協助，志工前往中',
      CareStepKind.workerArrived => '志工已抵達 $elderName 家中',
      _ => '$elderName ${trigger.label}',
    };
  }
}

/// ISO-8601 週次（一年中的第幾週）。用於家屬歷史「以週為單位」分組。
int isoWeekNumber(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  // ISO：週四決定年份與週次
  final thursday = d.add(Duration(days: 4 - (d.weekday)));
  final firstThursday = DateTime(thursday.year, 1, 1)
      .add(Duration(days: (4 - DateTime(thursday.year, 1, 1).weekday) % 7));
  final diff = thursday.difference(firstThursday).inDays;
  return 1 + (diff / 7).round().abs();
}
