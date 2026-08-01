import 'models.dart';

/// 「資料變化 → 要跳什麼通知」的文案規則，兩套後端共用。
///
/// 為什麼抽出來：通知是三端唯一會吵醒使用者的東西，文案與分級一旦兩套後端不一致，
/// 同一件事在 Render 環境是「🚨 已派遣」、在 AWS 環境變成「⚠️ 確認中」，
/// demo 當場會被問到答不出來。純函式也才測得動。
///
/// 回傳 null＝這個變化不需要打擾使用者。
class FeedNotification {
  const FeedNotification(this.message, this.severity);
  final String message;
  final Severity severity;
}

FeedNotification? notificationForEvent(RadioEvent e, String elderName) {
  switch (e.type) {
    case RadioEventType.sos:
      return FeedNotification(
          '🆘 $elderName 按下 SOS，已派遣志工前往', Severity.emergency);
    case RadioEventType.fallSuspected:
      if (e.status == RadioEventStatus.escalated) {
        return FeedNotification(
            '🚨 $elderName 疑似跌倒且無回應，已派遣', Severity.emergency);
      }
      if (e.status == RadioEventStatus.open) {
        return FeedNotification(
            '⚠️ $elderName 疑似跌倒，收音機確認中…', Severity.attention);
      }
      return null;
    case RadioEventType.supplyRequest:
      return FeedNotification(
        '🛒 $elderName 有物資需求${e.transcript != null ? '：${e.transcript}' : ''}',
        Severity.normal,
      );
  }
}

FeedNotification notificationForNewTask(DispatchTask t, String elderName) {
  if (t.kind == DispatchKind.emergency) {
    return FeedNotification(
        '📋 新緊急派遣單：$elderName，待志工接單', Severity.emergency);
  }
  return FeedNotification(
    '📋 新物資派遣單：$elderName${t.items.isEmpty ? '' : '（${t.items.join('、')}）'}',
    Severity.attention,
  );
}

FeedNotification? notificationForTaskTransition(DispatchTask t, String elderName) {
  final who = t.assigneeName ?? '志工';
  switch (t.status) {
    case DispatchStatus.accepted:
      return FeedNotification(
        '🏃 $who 已接單${t.etaMinutes != null ? '，預計 ${t.etaMinutes} 分鐘到 $elderName 家' : '，前往 $elderName 家'}',
        Severity.attention,
      );
    case DispatchStatus.arrived:
      return FeedNotification('📍 $who 已抵達 $elderName 家', Severity.attention);
    case DispatchStatus.resolved:
      return FeedNotification('✅ $elderName 的任務已完成', Severity.normal);
    case DispatchStatus.pending:
      return null;
  }
}
