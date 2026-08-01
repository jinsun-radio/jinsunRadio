import 'package:excel/excel.dart';
import 'package:jinsun_core/jinsun_core.dart';

String _fmtTime(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

String eventTypeLabel(RadioEventType t) => switch (t) {
      RadioEventType.sos => 'SOS',
      RadioEventType.fallSuspected => '疑似跌倒',
      RadioEventType.supplyRequest => '物資需求',
    };

String eventStatusLabel(RadioEventStatus s) => switch (s) {
      RadioEventStatus.open => '處理中',
      RadioEventStatus.confirmedOk => '已確認無事',
      RadioEventStatus.escalated => '已升級派遣',
      RadioEventStatus.closed => '已結案',
    };

String severityText(Severity s) => switch (s) {
      Severity.normal => '正常',
      Severity.attention => '注意',
      Severity.emergency => '緊急',
    };

String taskStatusLabel(DispatchStatus s) => switch (s) {
      DispatchStatus.pending => '待接單',
      DispatchStatus.accepted => '前往中',
      DispatchStatus.arrived => '已到場',
      DispatchStatus.resolved => '已完成',
    };

Excel buildExportWorkbook({
  required List<Elder> elders,
  required List<RadioEvent> events,
  required List<DispatchTask> tasks,
}) {
  final excel = Excel.createExcel();
  // 孤兒 elderId（長輩被刪／查詢過濾）不可讓 firstWhere 拋例外整份匯出崩潰——
  // 政府申報是硬需求，寧可標「查無此長輩」也要把檔案產出來。
  Elder elderOf(String id) => elders.firstWhere(
        (e) => e.id == id,
        orElse: () => Elder(
          id: id,
          name: '（查無此長輩 $id）',
          age: 0,
          address: '',
          severity: Severity.normal,
          lastActivityAt: DateTime.now(),
        ),
      );

  // 事件對應的派遣單（處理人員／處理時間由派遣單推導，與後台畫面一致）。
  DispatchTask? taskOf(String eventId) {
    for (final t in tasks) {
      if (t.eventId == eventId) return t;
    }
    return null;
  }

  final eventSheet = excel['事件紀錄'];
  eventSheet.appendRow([
    TextCellValue('時間'),
    TextCellValue('長輩'),
    TextCellValue('事件類型'),
    TextCellValue('分級'),
    TextCellValue('狀態'),
    TextCellValue('處理人員'),
    TextCellValue('處理時間'),
    TextCellValue('內容'),
  ]);
  for (final e in events) {
    final t = taskOf(e.id);
    // 到場社工優先，否則督導社工。
    final handler = t == null ? '' : (t.assigneeName ?? t.workerName ?? '');
    final handledTime = t == null
        ? ''
        : (t.resolvedAt != null ? _fmtTime(t.resolvedAt!) : '處理中');
    eventSheet.appendRow([
      TextCellValue(_fmtTime(e.occurredAt)),
      TextCellValue(elderOf(e.elderId).name),
      TextCellValue(eventTypeLabel(e.type)),
      TextCellValue(severityText(e.severity)),
      TextCellValue(eventStatusLabel(e.status)),
      TextCellValue(handler),
      TextCellValue(handledTime),
      TextCellValue(e.transcript ?? ''),
    ]);
  }

  final taskSheet = excel['派遣紀錄'];
  taskSheet.appendRow([
    TextCellValue('開單時間'),
    TextCellValue('長輩'),
    TextCellValue('類型'),
    TextCellValue('狀態'),
    TextCellValue('社工'),
    TextCellValue('ETA(分)'),
    TextCellValue('完成時間'),
  ]);
  for (final t in tasks) {
    taskSheet.appendRow([
      TextCellValue(_fmtTime(t.createdAt)),
      TextCellValue(elderOf(t.elderId).name),
      TextCellValue(t.kind.label),
      TextCellValue(taskStatusLabel(t.status)),
      TextCellValue(t.assigneeName ?? ''),
      TextCellValue(t.etaMinutes?.toString() ?? ''),
      TextCellValue(t.resolvedAt != null ? _fmtTime(t.resolvedAt!) : ''),
    ]);
  }

  // 長輩名冊（政府申報常需服務對象名冊：地址、年齡、語言、督導人員、狀況）
  final elderSheet = excel['長輩名冊'];
  elderSheet.appendRow([
    TextCellValue('長輩'),
    TextCellValue('年齡'),
    TextCellValue('地址'),
    TextCellValue('聯絡電話'),
    TextCellValue('偏好語言'),
    TextCellValue('目前狀態'),
    TextCellValue('督導社工'),
    TextCellValue('督導志工'),
    TextCellValue('狀況注記'),
  ]);
  for (final e in elders) {
    elderSheet.appendRow([
      TextCellValue(e.name),
      IntCellValue(e.age),
      TextCellValue(e.address),
      TextCellValue(e.phone ?? ''),
      TextCellValue(e.preferredLang.label),
      TextCellValue(severityText(e.severity)),
      TextCellValue(e.supervisorWorkerName ?? ''),
      TextCellValue(e.supervisorVolunteerName ?? ''),
      TextCellValue(e.note ?? ''),
    ]);
  }

  excel.delete('Sheet1');
  return excel;
}
