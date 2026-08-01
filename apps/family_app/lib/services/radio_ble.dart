import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 金孫收音機 BLE 配對／Wi-Fi 佈建的 GATT 契約。
///
/// 收音機（Realtek AmebaPro2）開機未設定 Wi-Fi 時，會廣播一個 BLE
/// provisioning 服務，名稱以序號開頭（JS-xxxx）。家屬 App 連上後：
///   1. 讀 [chSerial] 取得序號（綁定用）
///   2. 讀 [chWifiList] 取得裝置掃到的 Wi-Fi 清單
///   3. 寫 [chSsid] + [chPass] 把選定的 Wi-Fi 傳給裝置
///   4. 訂閱 [chStatus] 等裝置回報 connected
///
/// ⚠️ 韌體端需實作同一組 UUID 與 status 字串；契約文件見
/// docs/requirements/hardware-integration.md。
class RadioBleContract {
  RadioBleContract._();

  static final service = Guid('a1b2c3d4-0001-4a5b-8c6d-1234567890ab');
  static final chSsid = Guid('a1b2c3d4-0002-4a5b-8c6d-1234567890ab'); // write
  static final chPass = Guid('a1b2c3d4-0003-4a5b-8c6d-1234567890ab'); // write
  static final chWifiList =
      Guid('a1b2c3d4-0004-4a5b-8c6d-1234567890ab'); // read/notify（\n 分隔）
  static final chStatus =
      Guid('a1b2c3d4-0005-4a5b-8c6d-1234567890ab'); // read/notify（狀態字串）
  static final chSerial = Guid('a1b2c3d4-0006-4a5b-8c6d-1234567890ab'); // read

  /// 收音機 BLE 廣播名前綴（也是序號前綴）
  static const namePrefix = 'JS-';
}

/// 裝置佈建狀態（對應 [RadioBleContract.chStatus] 回報的字串）
enum ProvStatus { idle, connecting, connected, wrongPassword, error }

/// 封裝一次配對的 BLE 生命週期：掃描 → 連線 → 讀清單 → 傳 Wi-Fi → 等上線。
class RadioProvisioner {
  BluetoothDevice? _device;
  final Map<Guid, BluetoothCharacteristic> _chars = {};

  /// 這個平台是否支援 BLE（Web／桌面部分平台回 false）。
  Future<bool> get isSupported => FlutterBluePlus.isSupported;

  /// 藍牙是否已開啟。
  Future<bool> get isBluetoothOn async =>
      FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;

  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  /// 掃描廣播 provisioning 服務的收音機（15 秒逾時）。
  Future<void> startScan() => FlutterBluePlus.startScan(
        withServices: [RadioBleContract.service],
        timeout: const Duration(seconds: 15),
      );

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
  }

  /// 連上裝置並探索 provisioning 服務的特徵值。
  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await stopScan();
    await device.connect(timeout: const Duration(seconds: 15));
    final services = await device.discoverServices();
    _chars.clear();
    for (final s in services) {
      if (s.uuid != RadioBleContract.service) continue;
      for (final c in s.characteristics) {
        _chars[c.uuid] = c;
      }
    }
    if (_chars.isEmpty) {
      await disconnect();
      throw Exception('這台裝置沒有金孫收音機的配對服務');
    }
  }

  /// 讀裝置序號（沒有序號特徵值時退回廣播名稱）。
  Future<String?> readSerial() async {
    final c = _chars[RadioBleContract.chSerial];
    if (c == null) return _device?.platformName;
    try {
      return utf8.decode(await c.read()).trim();
    } catch (_) {
      return _device?.platformName;
    }
  }

  /// 讀裝置掃到的 Wi-Fi 清單（\n 分隔；裝置未提供時回空陣列，改由手動輸入）。
  Future<List<String>> readWifiList() async {
    final c = _chars[RadioBleContract.chWifiList];
    if (c == null) return const [];
    try {
      return utf8
          .decode(await c.read())
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 把選定的 Wi-Fi SSID 與密碼寫進裝置。
  Future<void> sendWifi(String ssid, String password) async {
    final s = _chars[RadioBleContract.chSsid];
    final p = _chars[RadioBleContract.chPass];
    if (s == null || p == null) throw Exception('裝置缺少 Wi-Fi 設定通道');
    await s.write(utf8.encode(ssid));
    await p.write(utf8.encode(password));
  }

  /// 監看裝置佈建狀態（訂閱 status 特徵值的 notify）。
  Stream<ProvStatus> watchStatus() async* {
    final c = _chars[RadioBleContract.chStatus];
    if (c == null) {
      yield ProvStatus.error;
      return;
    }
    await c.setNotifyValue(true);
    try {
      yield _parseStatus(await c.read());
    } catch (_) {}
    yield* c.onValueReceived.map(_parseStatus);
  }

  ProvStatus _parseStatus(List<int> raw) {
    final s = utf8.decode(raw).trim().toLowerCase();
    return switch (s) {
      'connected' || 'ok' => ProvStatus.connected,
      'connecting' => ProvStatus.connecting,
      'wrong_password' || 'auth_fail' => ProvStatus.wrongPassword,
      'idle' => ProvStatus.idle,
      _ => ProvStatus.error,
    };
  }

  Future<void> disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _chars.clear();
  }
}
