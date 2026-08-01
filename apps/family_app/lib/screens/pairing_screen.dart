import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';
import '../services/radio_ble.dart';

/// 收音機藍牙配對＋Wi-Fi 佈建（真實 BLE），十步驟引導流程：
///   1. 選擇新增收音機（起始說明）
///   2. 開啟收音機配對模式（引導長按，藍燈閃爍）
///   3. 手機透過 Bluetooth 搜尋收音機（掃描 JS- 裝置）
///   4. 配對成功（BLE 已連線）
///   5. 認識收音機提供的 Wi-Fi（AP 模式說明，引導畫面）
///   6. 選擇家中的 Wi-Fi（裝置掃到的清單或手動輸入）
///   7. 輸入 Wi-Fi 密碼
///   8. 將 Wi-Fi 設定傳送到收音機（BLE 寫入）
///   9. 收音機連線成功（等 connected，逾時／密碼錯有明確錯誤）
///  10. 綁定完成（以序號綁定長輩）
/// 佈建成功後以裝置序號綁定長輩（沿用 [AppLocal.bindBySerial]）。
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.local});

  final AppLocal local;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

/// 流程狀態。intro／pairingMode／connected／apInfo 為引導畫面（只需按「下一步」），
/// 其餘對應真實 BLE 動作。
enum _Step {
  unsupported,
  intro,
  pairingMode,
  btOff,
  scan,
  connecting,
  connected,
  apInfo,
  wifi,
  password,
  sending,
  waiting,
  done,
  failed,
}

class _PairingScreenState extends State<PairingScreen> {
  final _prov = RadioProvisioner();
  final _manualSsid = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  _Step _step = _Step.intro;
  String? _error;
  String _deviceLabel = '';
  List<String> _wifiList = const [];
  String? _selectedSsid;
  String? _serial;
  StreamSubscription<ProvStatus>? _statusSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _provTimeout;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!await _prov.isSupported) {
      setState(() => _step = _Step.unsupported);
      return;
    }
    // 藍牙關閉時提示開啟，開啟後（若正卡在 btOff）自動接續掃描。
    _adapterSub = _prov.adapterState.listen((s) {
      if (!mounted) return;
      if (s == BluetoothAdapterState.on && _step == _Step.btOff) {
        _beginScan();
      }
    });
    // 起始停在步驟 1（intro），由使用者按「開始配對」再往下走。
  }

  // 步驟 1 → 2：進入「開啟配對模式」引導。
  void _startPairing() {
    setState(() {
      _step = _Step.pairingMode;
      _error = null;
    });
  }

  // 步驟 2 → 3：確認收音機已進入配對模式，開始搜尋（先確認藍牙已開）。
  Future<void> _searchDevices() async {
    if (!await _prov.isBluetoothOn) {
      if (!mounted) return;
      setState(() => _step = _Step.btOff);
      return;
    }
    _beginScan();
  }

  Future<void> _beginScan() async {
    setState(() {
      _step = _Step.scan;
      _error = null;
    });
    try {
      await _prov.startScan();
    } catch (e) {
      _fail('無法開始搜尋藍牙：$e');
    }
  }

  Future<void> _onSelectDevice(BluetoothDevice device, String label) async {
    setState(() {
      _step = _Step.connecting;
      _deviceLabel = label;
      _error = null;
    });
    try {
      await _prov.connect(device);
      _serial = await _prov.readSerial();
      final list = await _prov.readWifiList();
      if (!mounted) return;
      // 步驟 4：配對成功，停在「已連線」讓使用者確認後再往下。
      setState(() {
        _wifiList = list;
        _step = _Step.connected;
      });
    } catch (e) {
      _fail('連線失敗：$e');
    }
  }

  // 步驟 4 → 5：進入「收音機提供的 Wi-Fi（AP 模式）」說明。
  void _toApInfo() => setState(() => _step = _Step.apInfo);

  // 步驟 5 → 6：進入「選擇家中的 Wi-Fi」。
  void _toWifi() => setState(() => _step = _Step.wifi);

  void _onSelectWifi(String ssid) {
    setState(() {
      _selectedSsid = ssid;
      _password.clear();
      _step = _Step.password;
    });
  }

  Future<void> _submitWifi() async {
    final ssid = _selectedSsid!;
    // 步驟 8：透過 BLE 把 Wi-Fi 設定傳給收音機。
    setState(() {
      _step = _Step.sending;
      _error = null;
    });
    try {
      await _prov.sendWifi(ssid, _password.text);
    } catch (e) {
      _fail('傳送 Wi-Fi 設定失敗：$e');
      return;
    }
    if (!mounted) return;
    // 步驟 9：等收音機回報連上網路。
    setState(() => _step = _Step.waiting);
    // 40 秒沒結果視為逾時。
    _provTimeout = Timer(const Duration(seconds: 40), () {
      if (mounted && _step == _Step.waiting) {
        _fail('等收音機連上 Wi-Fi 逾時，請確認訊號與密碼後重試');
      }
    });
    _statusSub = _prov.watchStatus().listen((status) {
      if (!mounted) return;
      switch (status) {
        case ProvStatus.connected:
          _provTimeout?.cancel();
          _statusSub?.cancel();
          _finish();
        case ProvStatus.wrongPassword:
          _provTimeout?.cancel();
          _statusSub?.cancel();
          setState(() {
            _error = 'Wi-Fi 密碼錯誤，請重新輸入';
            _step = _Step.password;
          });
        case ProvStatus.error:
          _provTimeout?.cancel();
          _statusSub?.cancel();
          _fail('收音機回報連線錯誤，請確認 Wi-Fi 後重試');
        case ProvStatus.idle:
        case ProvStatus.connecting:
          break; // 持續等待
      }
    });
  }

  Future<void> _finish() async {
    // 步驟 10：佈建成功 → 以序號綁定長輩（序號讀不到時仍顯示完成，提示手動綁定）。
    final serial = _serial;
    if (serial != null && serial.isNotEmpty) {
      await widget.local.bindBySerial(serial);
    }
    if (mounted) setState(() => _step = _Step.done);
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _error = msg;
      _step = _Step.failed;
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _adapterSub?.cancel();
    _provTimeout?.cancel();
    _prov.stopScan();
    _prov.disconnect();
    _manualSsid.dispose();
    _password.dispose();
    super.dispose();
  }

  // 目前步驟在 1..10 的位置（給進度條）。
  int get _stepIndex => switch (_step) {
        _Step.intro => 1,
        _Step.pairingMode => 2,
        _Step.btOff => 3,
        _Step.scan => 3,
        _Step.connecting => 3,
        _Step.connected => 4,
        _Step.apInfo => 5,
        _Step.wifi => 6,
        _Step.password => 7,
        _Step.sending => 8,
        _Step.waiting => 9,
        _Step.done => 10,
        _Step.unsupported => 1,
        _Step.failed => 1,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配對收音機')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _body(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    return switch (_step) {
      _Step.unsupported => _unsupported(),
      _Step.intro => _introView(),
      _Step.pairingMode => _pairingModeView(),
      _Step.btOff => _info(Icons.bluetooth_disabled, '請先開啟藍牙',
          '配對收音機需要藍牙。請到手機設定開啟藍牙，畫面會自動繼續。'),
      _Step.scan => _scanView(),
      _Step.connecting =>
        _loading('正在連線 $_deviceLabel…', '與收音機建立藍牙連線'),
      _Step.connected => _connectedView(),
      _Step.apInfo => _apInfoView(),
      _Step.wifi => _wifiView(),
      _Step.password => _passwordView(),
      _Step.sending =>
        _loading('正在傳送 Wi-Fi 設定…', '透過藍牙把家中 Wi-Fi 傳給收音機'),
      _Step.waiting =>
        _loading('收音機連線中…', '已把 Wi-Fi 傳給收音機，等它連上網路（約需 10–30 秒）'),
      _Step.done => _doneView(),
      _Step.failed => _failedView(),
    };
  }

  Widget _stepBar() {
    const labels = [
      '開始',
      '配對模式',
      '搜尋收音機',
      '配對成功',
      '熱點說明',
      '選擇 Wi-Fi',
      '輸入密碼',
      '傳送設定',
      '連線中',
      '完成',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: _stepIndex / 10,
          minHeight: 6,
          backgroundColor: const Color(0xFFE8E8E4),
        ),
        const SizedBox(height: 6),
        Text('步驟 $_stepIndex / 10 · ${labels[_stepIndex - 1]}',
            style: const TextStyle(fontSize: 12.5, color: JinsunColors.muted)),
        const SizedBox(height: 18),
      ],
    );
  }

  // 步驟 1：起始說明。
  Widget _introView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const SizedBox(height: 8),
        const Center(child: Text('📻', style: TextStyle(fontSize: 64))),
        const SizedBox(height: 16),
        const Text('新增一台收音機',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        const Text(
          '接下來會用手機藍牙連上收音機，並幫它連上家裡的 Wi-Fi。\n'
          '全程約 10 個步驟、2 分鐘完成，請把手機靠近收音機。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, height: 1.5, color: JinsunColors.muted),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
          onPressed: _startPairing,
          child: const Text('開始配對', style: TextStyle(fontSize: 17)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 步驟 2：引導長按讓收音機進入配對模式。
  Widget _pairingModeView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const Text('開啟收音機的配對模式',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('請在收音機上完成以下動作：',
            style: TextStyle(fontSize: 14, color: JinsunColors.muted)),
        const SizedBox(height: 16),
        _bullet('1', '確認收音機已插電、已開機。'),
        _bullet('2', '長按收音機上的「SOS／電源」鍵約 5 秒。'),
        _bullet('3', '看到機身「藍燈開始閃爍」，就代表已進入配對模式。'),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF4FF),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.bluetooth_searching, color: Color(0xFF2E6BE6)),
              SizedBox(width: 10),
              Expanded(
                child: Text('藍燈閃爍時，收音機會用藍牙對外廣播，手機才找得到它。',
                    style: TextStyle(fontSize: 13.5, height: 1.4)),
              ),
            ],
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
          icon: const Icon(Icons.search),
          label: const Text('藍燈已閃爍，開始搜尋', style: TextStyle(fontSize: 16)),
          onPressed: _searchDevices,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 步驟 3：藍牙搜尋。
  Widget _scanView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        Row(
          children: [
            const Expanded(
              child: Text('搜尋附近的收音機',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            StreamBuilder<bool>(
              stream: _prov.isScanning,
              initialData: true,
              builder: (_, s) => (s.data ?? false)
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : IconButton(
                      tooltip: '重新搜尋',
                      onPressed: _beginScan,
                      icon: const Icon(Icons.refresh)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('手機正透過 Bluetooth 尋找進入配對模式（藍燈閃爍）的收音機。',
            style: TextStyle(fontSize: 13, color: JinsunColors.muted)),
        const SizedBox(height: 12),
        Expanded(
          child: StreamBuilder<List<ScanResult>>(
            stream: _prov.scanResults,
            initialData: const [],
            builder: (_, snap) {
              final results = (snap.data ?? [])
                  .where((r) =>
                      (r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : r.device.platformName)
                      .toUpperCase()
                      .contains(RadioBleContract.namePrefix))
                  .toList()
                ..sort((a, b) => b.rssi.compareTo(a.rssi));
              if (results.isEmpty) {
                return const Center(
                  child: Text('搜尋中…尚未找到收音機（JS- 開頭）',
                      style: TextStyle(color: JinsunColors.muted)),
                );
              }
              return ListView.separated(
                itemCount: results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = results[i];
                  final name = r.advertisementData.advName.isNotEmpty
                      ? r.advertisementData.advName
                      : r.device.platformName;
                  return ListTile(
                    leading: const Icon(Icons.radio, color: JinsunColors.orangeDeep),
                    title: Text(name.isEmpty ? '收音機' : name),
                    subtitle: Text('訊號 ${r.rssi} dBm'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _onSelectDevice(r.device, name),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // 步驟 4：配對成功。
  Widget _connectedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const SizedBox(height: 12),
        const Center(
            child: Icon(Icons.bluetooth_connected,
                size: 64, color: Color(0xFF2E6BE6))),
        const SizedBox(height: 16),
        const Text('配對成功！',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(
          '手機已用藍牙連上收音機'
          '${_deviceLabel.isEmpty ? '' : '（$_deviceLabel）'}。'
          '\n序號：${_serial ?? '—'}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14.5, height: 1.5, color: JinsunColors.muted),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
          onPressed: _toApInfo,
          child: const Text('下一步：設定 Wi-Fi', style: TextStyle(fontSize: 16)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 步驟 5：收音機提供的 Wi-Fi（AP 模式）說明（純引導，不真的切換手機 Wi-Fi）。
  Widget _apInfoView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const Text('關於收音機的 Wi-Fi 熱點',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFEFEFEC),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.wifi_tethering, color: JinsunColors.orangeDeep),
                  SizedBox(width: 8),
                  Text('收音機會開一個熱點',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '第一次設定時，收音機會開啟自己的 Wi-Fi 熱點（AP 模式），'
                '名稱類似 Jinsun-JS0001。',
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.check_circle, color: Color(0xFF43A047), size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '你不需要手動切換手機的 Wi-Fi。'
                        '接下來的 Wi-Fi 設定會透過剛剛連上的「藍牙」直接傳給收音機。',
                        style: TextStyle(fontSize: 13.5, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
          onPressed: _toWifi,
          child: const Text('我知道了，下一步', style: TextStyle(fontSize: 16)),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 步驟 6：選擇家中的 Wi-Fi。
  Widget _wifiView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const Text('選擇家中的 Wi-Fi',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('收音機將連上這個 Wi-Fi 上網（序號 ${_serial ?? '—'}）。',
            style: const TextStyle(fontSize: 13, color: JinsunColors.muted)),
        const SizedBox(height: 12),
        Expanded(
          child: _wifiList.isEmpty
              ? _manualWifi()
              : ListView(
                  children: [
                    for (final ssid in _wifiList)
                      ListTile(
                        leading: const Icon(Icons.wifi),
                        title: Text(ssid),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onSelectWifi(ssid),
                      ),
                    const Divider(),
                    _manualWifi(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _manualWifi() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('或手動輸入 Wi-Fi 名稱',
              style: TextStyle(fontSize: 13.5, color: JinsunColors.muted)),
          const SizedBox(height: 8),
          TextField(
            controller: _manualSsid,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi 名稱（SSID）',
              prefixIcon: Icon(Icons.wifi),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _manualSsid.text.trim().isEmpty
                ? null
                : () => _onSelectWifi(_manualSsid.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
  }

  // 步驟 7：輸入 Wi-Fi 密碼。
  Widget _passwordView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepBar(),
        const Text('輸入 Wi-Fi 密碼',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Wi-Fi：${_selectedSsid ?? ''}',
            style: const TextStyle(fontSize: 14, color: JinsunColors.muted)),
        const SizedBox(height: 16),
        TextField(
          controller: _password,
          obscureText: _obscure,
          autofocus: true,
          onSubmitted: (_) => _submitWifi(),
          decoration: InputDecoration(
            labelText: 'Wi-Fi 密碼',
            prefixIcon: const Icon(Icons.lock_outline),
            errorText: _error,
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.send),
          label: const Text('傳送給收音機'),
          onPressed: _submitWifi,
        ),
        const SizedBox(height: 8),
        const Text('密碼只透過藍牙直接傳給收音機，不會上傳雲端。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: JinsunColors.muted)),
      ],
    );
  }

  // 步驟 10：完成。
  Widget _doneView() {
    final bound = _serial != null && _serial!.isNotEmpty;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF43A047), size: 72),
        const SizedBox(height: 16),
        const Text('綁定完成！',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          bound
              ? '收音機（$_serial）已連上 Wi-Fi，並綁定到你的帳號。'
              : '收音機已連上 Wi-Fi。請到設定頁用序號完成綁定。',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: JinsunColors.muted),
        ),
        const SizedBox(height: 28),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _failedView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, color: Color(0xFFE53935), size: 64),
        const SizedBox(height: 16),
        const Text('配對沒有成功',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(_error ?? '請重試',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: JinsunColors.muted)),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('重新配對'),
          onPressed: () async {
            await _prov.disconnect();
            setState(() => _step = _Step.pairingMode);
          },
        ),
      ],
    );
  }

  Widget _loading(String title, String sub) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _stepBar(),
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(sub,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, color: JinsunColors.muted)),
      ],
    );
  }

  Widget _info(IconData icon, String title, String sub) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: JinsunColors.muted),
        const SizedBox(height: 16),
        Text(title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(sub,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: JinsunColors.muted)),
      ],
    );
  }

  // 引導步驟用的編號小圓點清單項。
  Widget _bullet(String no, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: JinsunColors.orangeBg,
              shape: BoxShape.circle,
            ),
            child: Text(no,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: JinsunColors.orangeDeep)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(text,
                  style: const TextStyle(fontSize: 14.5, height: 1.4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unsupported() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.phonelink_erase, size: 64, color: JinsunColors.muted),
        const SizedBox(height: 16),
        const Text('此裝置不支援藍牙配對',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('藍牙配對僅支援手機 App（iOS／Android）。\nWeb 版請改用序號或 QR Code 綁定收音機。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: JinsunColors.muted)),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('返回'),
        ),
      ],
    );
  }
}
