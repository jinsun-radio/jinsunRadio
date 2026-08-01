import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

MockBackend fastBackend({bool autoVolunteer = false}) => MockBackend(
      autoVolunteer: autoVolunteer,
      escalateAfter: const Duration(milliseconds: 30),
      autoAcceptDelay: const Duration(milliseconds: 10),
      autoArriveDelay: const Duration(milliseconds: 10),
      autoResolveDelay: const Duration(milliseconds: 10),
    );

Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

void main() {
  test('fall suspected escalates to emergency after timeout', () async {
    final backend = fastBackend();
    backend.triggerFallSuspected('elder-1');
    expect(backend.currentElders.first.severity, Severity.attention);
    expect(backend.currentTasks, isEmpty);

    await wait(60);
    expect(backend.currentElders.first.severity, Severity.emergency);
    expect(backend.currentEvents.single.status, RadioEventStatus.escalated);
    final task = backend.currentTasks.single;
    expect(task.kind, DispatchKind.emergency);
    expect(task.status, DispatchStatus.pending);
    backend.dispose();
  });

  test('confirming elder ok cancels escalation', () async {
    final backend = fastBackend();
    backend.triggerFallSuspected('elder-1');
    backend.confirmElderOk('elder-1');

    await wait(60);
    expect(backend.currentElders.first.severity, Severity.normal);
    expect(backend.currentEvents.single.status, RadioEventStatus.confirmedOk);
    expect(backend.currentTasks, isEmpty);
    backend.dispose();
  });

  test('sos creates emergency dispatch immediately', () {
    final backend = fastBackend();
    backend.triggerSos('elder-2');
    expect(backend.currentElders[1].severity, Severity.emergency);
    expect(backend.currentTasks.single.kind, DispatchKind.emergency);
    backend.dispose();
  });

  test('emergency task lifecycle banks service minutes (eta+現場 ×1.5)', () async {
    final backend = fastBackend();
    backend.triggerSos('elder-1');
    final taskId = backend.currentTasks.single.id;

    await backend.acceptTask(taskId, etaMinutes: 6);
    expect(backend.currentTasks.single.status, DispatchStatus.accepted);
    expect(backend.currentTasks.single.etaMinutes, 6);

    await backend.markArrived(taskId);
    expect(backend.currentTasks.single.status, DispatchStatus.arrived);

    await backend.resolveTask(taskId);
    expect(backend.currentTasks.single.status, DispatchStatus.resolved);
    expect(backend.currentElders.first.severity, Severity.normal);
    // eta 6 + 現場 6 = 12 分，緊急 ×1.5 = 18 分
    expect(backend.currentTimeBankPoints, 18);
    expect(backend.currentEvents.single.status, RadioEventStatus.closed);
    backend.dispose();
  });

  test('supply request task banks service minutes (eta+現場)', () async {
    final backend = fastBackend();
    backend.triggerSupplyRequest('elder-3', ['牛奶', '雞蛋']);
    final task = backend.currentTasks.single;
    expect(task.kind, DispatchKind.supply);
    expect(task.items, ['牛奶', '雞蛋']);

    await backend.acceptTask(task.id, etaMinutes: 15);
    await backend.resolveTask(task.id);
    // eta 15 + 現場 6 = 21 分（物資單無加成）
    expect(backend.currentTimeBankPoints, 21);
    backend.dispose();
  });

  test('accepting a non-pending task is a no-op', () async {
    final backend = fastBackend();
    backend.triggerSos('elder-1');
    final taskId = backend.currentTasks.single.id;
    await backend.acceptTask(taskId, etaMinutes: 6);
    await backend.acceptTask(taskId, etaMinutes: 99);
    expect(backend.currentTasks.single.etaMinutes, 6);
    backend.dispose();
  });

  test('auto volunteer runs full chain to resolved', () async {
    final backend = fastBackend(autoVolunteer: true);
    backend.triggerSos('elder-1');

    await wait(80);
    final task = backend.currentTasks.single;
    expect(task.status, DispatchStatus.resolved);
    expect(task.assigneeName, '阿明');
    expect(backend.currentElders.first.severity, Severity.normal);
    backend.dispose();
  });

  group('社工派遣（值班＋單量）', () {
    test('值班中且單量最少者被指派', () {
      final backend = fastBackend();
      final noon = DateTime(2026, 7, 11, 12); // 12:00 → 王淑芬（08–16）值班
      expect(backend.pickWorker(now: noon).name, '王淑芬');
      final night = DateTime(2026, 7, 11, 2); // 02:00 → 張美惠（00–08）值班
      expect(backend.pickWorker(now: night).name, '張美惠');
      final evening = DateTime(2026, 7, 11, 20); // 20:00 → 李建成（16–24）值班
      expect(backend.pickWorker(now: evening).name, '李建成');
      backend.dispose();
    });

    test('建立派遣單時自動帶入社工並累計單量', () {
      final backend = fastBackend();
      backend.triggerSos('elder-1');
      final task = backend.currentTasks.single;
      expect(task.workerName, isNotNull);
      expect(backend.workerLoad(task.workerName!), 1);
      backend.dispose();
    });

    test('結案後單量歸還', () async {
      final backend = fastBackend();
      backend.triggerSos('elder-1');
      final task = backend.currentTasks.single;
      final worker = task.workerName!;
      await backend.acceptTask(task.id, etaMinutes: 6);
      await backend.markArrived(task.id);
      await backend.resolveTask(task.id);
      expect(backend.workerLoad(worker), 0);
      backend.dispose();
    });
  });

  group('🟡 注意軌：疑似跌倒趨勢 → 督導追蹤', () {
    MockBackend trendBackend() => MockBackend(
          escalateAfter: const Duration(milliseconds: 30),
          followUpThreshold: 3,
        );

    // 疑似跌倒 → 長輩立刻回應無恙（同步取消升級，只留一筆趨勢）。
    void fallThenOk(MockBackend b, String elderId) {
      b.triggerFallSuspected(elderId);
      b.confirmElderOk(elderId);
    }

    test('未達門檻不開追蹤單、不升級', () {
      final backend = trendBackend();
      fallThenOk(backend, 'elder-1');
      fallThenOk(backend, 'elder-1');
      expect(backend.currentTasks, isEmpty);
      expect(backend.currentElders.first.severity, Severity.normal);
      backend.dispose();
    });

    test('達門檻自動為督導個管開督導追蹤（非緊急、不派志工、不計時間銀行）', () {
      final backend = trendBackend();
      fallThenOk(backend, 'elder-1');
      fallThenOk(backend, 'elder-1');
      fallThenOk(backend, 'elder-1');

      final follow = backend.currentTasks
          .where((t) => t.kind == DispatchKind.followUp)
          .toList();
      expect(follow, hasLength(1));
      final t = follow.single;
      // 定向給該長輩的督導個管（elder-1 → 王淑芬），不開放志工搶單。
      expect(t.workerName, '王淑芬');
      expect(t.assigneeName, '王淑芬');
      expect(t.status, DispatchStatus.pending);
      // 沒有任何緊急派遣單被開出（沒佔用到場人力）。
      expect(backend.currentTasks.any((x) => x.kind == DispatchKind.emergency),
          isFalse);
      // 長輩升為「需要留意」讓社工後台置頂。
      expect(backend.currentElders.first.severity, Severity.attention);
      // 尚未動用志工時間銀行。
      expect(backend.currentTimeBankPoints, 0);
      backend.dispose();
    });

    test('趨勢期間只開一張追蹤單（去重）', () {
      final backend = trendBackend();
      for (var i = 0; i < 5; i++) {
        fallThenOk(backend, 'elder-1');
      }
      expect(
          backend.currentTasks
              .where((t) => t.kind == DispatchKind.followUp)
              .length,
          1);
      backend.dispose();
    });

    test('個管結案追蹤單：回正常、不加時間銀行點數', () async {
      final backend = trendBackend();
      fallThenOk(backend, 'elder-1');
      fallThenOk(backend, 'elder-1');
      fallThenOk(backend, 'elder-1');
      final t = backend.currentTasks
          .firstWhere((x) => x.kind == DispatchKind.followUp);

      await backend.resolveTask(t.id, outcome: '已安排下週居家訪視');
      expect(backend.currentTasks.firstWhere((x) => x.id == t.id).status,
          DispatchStatus.resolved);
      expect(backend.currentElders.first.severity, Severity.normal);
      expect(backend.currentTimeBankPoints, 0);
      backend.dispose();
    });
  });
}
