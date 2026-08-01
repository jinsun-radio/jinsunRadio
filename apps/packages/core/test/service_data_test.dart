import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

void main() {
  group('可服務時段（ServiceHourSlot）', () {
    test('平日時段涵蓋週三晚上、不涵蓋週日', () {
      const slot =
          ServiceHourSlot(weekdays: {1, 2, 3, 4, 5}, startHour: 18, endHour: 22);
      expect(slot.covers(DateTime(2026, 7, 22, 20)), isTrue); // 週三 20:00
      expect(slot.covers(DateTime(2026, 7, 22, 17)), isFalse); // 週三 17:00
      expect(slot.covers(DateTime(2026, 7, 26, 20)), isFalse); // 週日 20:00
    });

    test('跨夜時段（22–06）正確判定', () {
      const slot = ServiceHourSlot(weekdays: {6}, startHour: 22, endHour: 6);
      expect(slot.covers(DateTime(2026, 7, 25, 23)), isTrue); // 週六 23:00
      expect(slot.covers(DateTime(2026, 7, 25, 3)), isTrue); // 週六 03:00
      expect(slot.covers(DateTime(2026, 7, 25, 12)), isFalse);
    });

    test('label 產生人類可讀字串', () {
      const weekday =
          ServiceHourSlot(weekdays: {1, 2, 3, 4, 5}, startHour: 18, endHour: 22);
      expect(weekday.label, '平日 18:00–22:00');
      const weekend =
          ServiceHourSlot(weekdays: {6, 7}, startHour: 0, endHour: 24);
      expect(weekend.label, '週末 全天');
    });

    test('toJson / fromJson 往返一致', () {
      const slot =
          ServiceHourSlot(weekdays: {1, 3, 5}, startHour: 9, endHour: 17);
      final back = ServiceHourSlot.fromJson(slot.toJson());
      expect(back.weekdays, slot.weekdays);
      expect(back.startHour, 9);
      expect(back.endHour, 17);
    });

    test('Volunteer.availableAt 依時段判定', () {
      const v = Volunteer(id: 'v', name: 'A', serviceHours: [
        ServiceHourSlot(weekdays: {1, 2, 3, 4, 5}, startHour: 18, endHour: 22),
      ]);
      expect(v.availableAt(DateTime(2026, 7, 22, 20)), isTrue);
      expect(v.availableAt(DateTime(2026, 7, 22, 10)), isFalse);
    });
  });

  group('證件（VolunteerCertificate）', () {
    test('30 天內到期視為 expiringSoon', () {
      final now = DateTime(2026, 7, 20);
      final soon = VolunteerCertificate(
          kind: CertKind.insurance,
          status: CertStatus.valid,
          expiresAt: DateTime(2026, 8, 1));
      final far = VolunteerCertificate(
          kind: CertKind.goodCitizen,
          status: CertStatus.valid,
          expiresAt: DateTime(2027, 6, 1));
      expect(soon.expiringSoon(now), isTrue);
      expect(far.expiringSoon(now), isFalse);
    });

    test('wire 轉換往返', () {
      expect(CertKindLabel.fromWire('basic_training'), CertKind.basicTraining);
      expect(CertStatusLabel.fromWire('valid'), CertStatus.valid);
      expect(CertStatusLabel.fromWire(null), CertStatus.none);
    });
  });

  group('真實時間銀行（MockBackend.timeBankMinutesFor）', () {
    test('初始為種子基底，完成派遣後累加真實時數', () async {
      final backend = MockBackend(
        escalateAfter: const Duration(milliseconds: 30),
      );
      // 種子基底：阿明 points=12
      expect(await backend.timeBankMinutesFor('阿明'), 12);

      // 阿明完成一張 SOS 緊急派遣單 → 累加該單 timeBankMinutes
      backend.triggerSos('elder-1');
      final task = backend.currentTasks.firstWhere((t) => t.elderId == 'elder-1');
      await backend.acceptTask(task.id, etaMinutes: 6, assigneeName: '阿明');
      await backend.markArrived(task.id);
      await backend.resolveTask(task.id, note: '已安全');

      final resolved =
          backend.currentTasks.firstWhere((t) => t.id == task.id);
      expect(await backend.timeBankMinutesFor('阿明'), 12 + resolved.timeBankMinutes);
      // 未參與的志工不受影響
      expect(await backend.timeBankMinutesFor('俊傑'), 20);
      backend.dispose();
    });
  });

  group('長輩注記編輯（setElderNote）', () {
    test('可設定與清空', () async {
      final backend = MockBackend();
      await backend.setElderNote('elder-2', '新注記');
      expect(backend.currentElders.firstWhere((e) => e.id == 'elder-2').note,
          '新注記');
      await backend.setElderNote('elder-2', '   ');
      expect(backend.currentElders.firstWhere((e) => e.id == 'elder-2').note,
          isNull);
      backend.dispose();
    });
  });
}
