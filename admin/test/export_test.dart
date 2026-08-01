/// excel package API verified against pub.dev/packages/excel v4.0.6 docs on
/// 2026-07-11: Excel.createExcel() / sheet.appendRow([TextCellValue]) /
/// excel.save() returns bytes (and triggers browser download on Flutter web).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

import 'package:admin_dashboard/export.dart';

void main() {
  test('export workbook produces non-empty xlsx bytes', () {
    final backend = MockBackend();
    backend.triggerSos('elder-1');
    backend.triggerSupplyRequest('elder-3', ['牛奶', '雞蛋']);

    final excel = buildExportWorkbook(
      elders: backend.currentElders,
      events: backend.currentEvents,
      tasks: backend.currentTasks,
    );

    expect(excel.sheets.keys, containsAll(['事件紀錄', '派遣紀錄']));
    expect(excel.sheets['事件紀錄']!.rows.length, 3);
    expect(excel.sheets['派遣紀錄']!.rows.length, 3);

    final bytes = excel.save();
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(0));
    backend.dispose();
  });
}
