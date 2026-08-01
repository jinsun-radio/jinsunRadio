import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

/// 林阿春家（信義區松仁路）座標——派單就近排序的基準點。
const _elderLat = 25.0358;
const _elderLng = 121.5665;

Volunteer _vol(String name, double lat, double lng,
        {bool online = true, List<ServiceHourSlot> hours = const []}) =>
    Volunteer(
      id: name,
      name: name,
      lat: lat,
      lng: lng,
      online: online,
      // 預設全天可服務，測試距離/負載時不被時段篩掉。
      serviceHours: hours.isEmpty
          ? const [
              ServiceHourSlot(
                  weekdays: {1, 2, 3, 4, 5, 6, 7}, startHour: 0, endHour: 24)
            ]
          : hours,
    );

void main() {
  group('dispatchScore（距離＋負載）', () {
    test('負載懲罰讓忙碌志工分數升高', () {
      // 同樣 5 分鐘車程，手上 0 件 vs 2 件（每件 +8 分）
      expect(dispatchScore(5, 0), 5);
      expect(dispatchScore(5, 2), 5 + 16);
    });

    test('稍遠但較閒者可勝過近而忙者', () {
      // 近(3 分)但手上 2 件 → 3+16=19；稍遠(8 分)但沒單 → 8。閒者勝出。
      expect(dispatchScore(8, 0) < dispatchScore(3, 2), isTrue);
    });
  });

  group('pickVolunteer（就近＋負載派單）', () {
    test('全部閒置時派給最近的志工', () {
      final vols = [
        _vol('近', 25.0345, 121.5672), // ~信義，最近
        _vol('中', 25.0270, 121.5440), // 大安
        _vol('遠', 25.0630, 121.5150), // 大同，最遠
      ];
      final picked =
          pickVolunteer(vols, _elderLat, _elderLng, (_) => 0);
      expect(picked?.name, '近');
    });

    test('最近志工已有多件在辦時，改派較閒的次近者（負載平衡）', () {
      final vols = [
        _vol('近', 25.0345, 121.5672), // 幾乎在門口
        _vol('次近', 25.0410, 121.5710), // 約 0.7km
      ];
      int loadOf(String n) => n == '近' ? 3 : 0; // 最近的手上 3 件
      final picked =
          pickVolunteer(vols, _elderLat, _elderLng, loadOf);
      expect(picked?.name, '次近');
    });

    test('離線志工不列入派單', () {
      final vols = [
        _vol('近但離線', 25.0345, 121.5672, online: false),
        _vol('遠但在線', 25.0630, 121.5150),
      ];
      final picked =
          pickVolunteer(vols, _elderLat, _elderLng, (_) => 0);
      expect(picked?.name, '遠但在線');
    });

    test('優先服務時段內的志工；全部非時段才放寬', () {
      // 週三 10:00
      final now = DateTime(2026, 7, 22, 10);
      final vols = [
        _vol('近但非時段', 25.0345, 121.5672,
            hours: const [
              ServiceHourSlot(weekdays: {6, 7}, startHour: 8, endHour: 20)
            ]),
        _vol('遠但可服務', 25.0630, 121.5150,
            hours: const [
              ServiceHourSlot(
                  weekdays: {1, 2, 3, 4, 5}, startHour: 8, endHour: 18)
            ]),
      ];
      final picked =
          pickVolunteer(vols, _elderLat, _elderLng, (_) => 0, now: now);
      expect(picked?.name, '遠但可服務');
    });

    test('無上線志工時回 null（呼叫端退回全體廣播）', () {
      final vols = [_vol('離線', 25.0345, 121.5672, online: false)];
      expect(pickVolunteer(vols, _elderLat, _elderLng, (_) => 0), isNull);
    });
  });

  group('MockBackend 緊急單自動派單', () {
    test('SOS 開單後就近派給最適合志工，並落在定向寬限期（未廣播全體）', () {
      final backend = MockBackend();
      backend.triggerSos('elder-1'); // 林阿春（信義）
      final task = backend.currentTasks.single;
      expect(task.kind, DispatchKind.emergency);
      expect(task.status, DispatchStatus.pending);
      // 已就近派給某位在地志工（信義的阿明最近）
      expect(task.assigneeName, isNotNull);
      expect(task.assigneeName, '阿明');
      // 定向寬限期內＝尚未廣播全體
      expect(task.inOfferWindow, isTrue);
      backend.dispose();
    });
  });
}
