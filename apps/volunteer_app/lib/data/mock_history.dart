import 'package:jinsun_core/jinsun_core.dart';

/// 一筆已完成的服務紀錄（外送員 App 風格：服務時長、點數）。
/// 由後端真實結案派遣單轉成的顯示用 view-model（非假資料）。
/// 里程與星等曾寫死假值（1.0 km／5 星），在「全為真實資料」的畫面上誤導，已移除。
class ServiceRecord {
  const ServiceRecord({
    required this.time,
    required this.elderName,
    required this.address,
    required this.kind,
    this.items = const [],
    required this.durationMin,
    this.note,
    this.taskId,
    this.photoUrl,
  });

  final DateTime time;
  final String elderName;
  final String address;
  final DispatchKind kind;
  final List<String> items;
  final int durationMin;
  final String? note;
  final String? taskId; // 對應派遣單 id（可點進歷史聊天）
  final String? photoUrl; // 拍照結單的現場證明照（有才顯示縮圖）

  /// 這筆服務存進時間銀行的分鐘數：服務時長，緊急派遣加成 ×1.5。
  int get minutes => kind == DispatchKind.emergency
      ? (durationMin * 1.5).round()
      : durationMin;
}
