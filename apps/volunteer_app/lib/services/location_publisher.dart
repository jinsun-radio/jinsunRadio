import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:jinsun_core/jinsun_core.dart';

/// 志工即時定位發信器。
///
/// 隱私與省電原則：**只在志工手上有進行中的任務（自己接的、accepted/arrived）時**
/// 才開啟 GPS 並回報位置；任務結案就停止。回報寫進 volunteers 表，
/// 家屬 App 透過 Realtime 即時看到志工位置與路線。
class LocationPublisher {
  LocationPublisher({
    required this.backend,
    required this.volunteerName,
    this.onLocationUnavailable,
  }) {
    _taskSub = backend.tasks.listen((tasks) => _sync(tasks));
    _sync(backend.currentTasks);
  }

  final BackendClient backend;
  final String volunteerName;

  /// 定位無法使用時回呼（權限被拒／服務關閉）→ UI 顯示提示，並提醒到場後仍可手動回報結案。
  /// 不再靜默失敗，志工才知道為何沒自動到場/家屬看不到位置。
  final void Function(String message)? onLocationUnavailable;

  StreamSubscription<List<DispatchTask>>? _taskSub;
  StreamSubscription<Position>? _posSub;
  bool _publishing = false;
  // 權限/服務不可用時設 true，暫停自動重試——否則每次 tasks tick 都會重打權限框（狂彈窗）。
  bool _blocked = false;

  bool _hasActiveTask(List<DispatchTask> tasks) => tasks.any((t) =>
      t.assigneeName == volunteerName &&
      (t.status == DispatchStatus.accepted ||
          t.status == DispatchStatus.arrived));

  void _sync(List<DispatchTask> tasks) {
    final active = _hasActiveTask(tasks);
    if (active && !_publishing && !_blocked) {
      _start();
    } else if (!active) {
      _blocked = false; // 沒有進行中任務了 → 解除封鎖，下次新任務重新嘗試取得定位
      if (_publishing) _stop();
    }
  }

  /// 定位不可用：停止發布、暫停自動重試、通知 UI（一次），避免狂彈權限框。
  void _block(String message) {
    _publishing = false;
    _blocked = true;
    onLocationUnavailable?.call(message);
  }

  Future<void> _start() async {
    _publishing = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _block('定位服務未開啟，家屬將看不到你的位置；到場後仍可在任務卡按綠色「回報」完成關單。');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        _block('定位權限已被永久拒絕，請至系統設定開啟；到場後仍可在任務卡按綠色「回報」完成關單。');
        return;
      }
      if (perm == LocationPermission.denied) {
        _block('未取得定位權限，家屬將看不到你的位置；到場後仍可在任務卡按綠色「回報」完成關單。');
        return;
      }
      // 先送一次目前位置，之後每移動 ~20m 更新
      final now = await Geolocator.getCurrentPosition();
      await backend.setVolunteerLocation(
          volunteerName, now.latitude, now.longitude);
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
        ),
      ).listen((p) {
        backend.setVolunteerLocation(volunteerName, p.latitude, p.longitude);
        _updateActiveTasks(p.latitude, p.longitude);
      });
    } catch (_) {
      // 平台不支援／取位失敗 → 暫停重試並提示，不影響其它功能
      _block('無法取得定位；到場後仍可在任務卡按綠色「回報」完成關單。');
    }
  }

  /// 志工移動 → 對「前往中」的任務：
  /// ① 走到長輩家附近（≤60m）自動回報「到場」（不需手動按「我到了」）
  /// ② 否則依目前位置到長輩家距離即時重算 ETA
  void _updateActiveTasks(double lat, double lng) {
    for (final t in backend.currentTasks) {
      if (t.assigneeName != volunteerName ||
          t.status != DispatchStatus.accepted) {
        continue;
      }
      Elder? elder;
      for (final e in backend.currentElders) {
        if (e.id == t.elderId) {
          elder = e;
          break;
        }
      }
      if (elder == null) continue;
      if (isNearbyMeters(lat, lng, elder.lat, elder.lng)) {
        backend.markArrived(t.id); // 到場自動回報
      } else {
        final eta = estimateEtaMinutes(lat, lng, elder.lat, elder.lng);
        if (eta != t.etaMinutes) backend.updateTaskEta(t.id, eta);
      }
    }
  }

  void _stop() {
    _publishing = false;
    _posSub?.cancel();
    _posSub = null;
  }

  void dispose() {
    _taskSub?.cancel();
    _stop();
  }
}
