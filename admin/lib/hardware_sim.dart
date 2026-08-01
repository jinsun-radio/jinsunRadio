import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:jinsun_core/jinsun_core.dart';

/// 硬體模擬頁（社工後台內嵌）。
/// 這是唯一「假」的一環：模擬 HUB8735 收音機——上報事件（POST /voice）、
/// 播出雲端下發的語音（long-poll /commands），並顯示語言（國語／台語）。
/// 事件會寫進真 Supabase → 三端即時亮；社工接單/抵達後這裡喇叭會主動念進度。
///
/// 雲端 server base URL 預設用「後台同一台主機的 8787 埠」，可用 ?sim= 覆寫。
class HardwareSimPage extends StatefulWidget {
  const HardwareSimPage({super.key, required this.backend});

  final BackendClient backend;

  @override
  State<HardwareSimPage> createState() => _HardwareSimPageState();
}

class _Line {
  _Line(this.text, {this.you = false, this.lang});
  final String text;
  final bool you;
  final String? lang;
  final DateTime at = DateTime.now();
}

class _HardwareSimPageState extends State<HardwareSimPage> {
  // 語音 server 的 base URL 決定順序：
  //   ①?server=（或 ?api=）覆寫 → ②?sim=<網址>（相容舊用法，僅當值是網址）
  //   → ③build 時 --dart-define=SIM_BASE=... → ④同主機 :8787（本機開發）
  // 注意：?sim=1 是用來「開啟本頁」的旗標（見 main.dart），值為 '1' 不可當成 URL，
  //       否則會 POST 到 "1/voice" 而連不上。
  static const _envBase = String.fromEnvironment('SIM_BASE');
  static String get _base {
    final q = Uri.base.queryParameters;
    final override = q['server'] ?? q['api'];
    if (override != null && override.isNotEmpty) return override;
    final sim = q['sim'];
    if (sim != null && sim.startsWith('http')) return sim; // 舊用法：?sim=https://...
    if (_envBase.isNotEmpty) return _envBase;
    final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
    return 'http://$host:8787';
  }

  String? _serial;
  final _custom = TextEditingController();
  final List<_Line> _lines = [];
  String _raw = '尚未觸發';
  bool _polling = false;
  http.Client? _pollClient;
  StreamSubscription<List<Elder>>? _eldersSub;

  List<Elder> get _devices =>
      widget.backend.currentElders.where((e) => e.deviceSerial != null).toList();

  @override
  void initState() {
    super.initState();
    // 等長輩資料載入後選第一台
    final d = _devices;
    _serial = d.isNotEmpty ? d.first.deviceSerial : null;
    _startPolling();
    _eldersSub = widget.backend.elders.listen((_) {
      if (_serial == null && _devices.isNotEmpty && mounted) {
        setState(() => _serial = _devices.first.deviceSerial);
      }
    });
  }

  @override
  void dispose() {
    _eldersSub?.cancel();
    _pollClient?.close();
    _custom.dispose();
    super.dispose();
  }

  void _add(_Line l) {
    if (!mounted) return;
    setState(() => _lines.insert(0, l));
  }

  Future<void> _post(Map<String, dynamic> body, {String? label}) async {
    _add(_Line(label ?? (body['text'] ?? '[事件] ${body['event']}') as String,
        you: true));
    try {
      final res = await http
          .post(Uri.parse('$_base/voice'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() => _raw = const JsonEncoder.withIndent('  ').convert(j));
      if (j['reply'] != null) {
        _add(_Line('🔊 ${j['reply']}', lang: j['lang'] as String?));
      }
    } catch (e) {
      _add(_Line('⚠️ 連不到雲端 server（$_base）：$e'));
    }
  }

  void _say(String t) => _post({'device_serial': _serial, 'text': t});
  void _event(String e) =>
      _post({'device_serial': _serial, 'event': e}, label: '[實體事件] $e');

  // 背景長輪詢下行：把 server 稍後主動下發的 speak（急救階梯／社工進度）顯示成喇叭播報。
  Future<void> _startPolling() async {
    if (_polling) return;
    _polling = true;
    _pollClient = http.Client();
    while (mounted) {
      final s = _serial;
      if (s == null) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      try {
        final res = await _pollClient!
            .get(Uri.parse('$_base/commands?device_serial=$s'))
            .timeout(const Duration(seconds: 30));
        final cmds = (jsonDecode(res.body)['commands'] as List?) ?? [];
        for (final c in cmds) {
          final m = c as Map<String, dynamic>;
          if (m['type'] == 'speak') {
            _add(_Line('🔊 ${m['text']}', lang: m['lang'] as String?));
          } else if (m['type'] == 'device') {
            _add(_Line('⚙️ 執行裝置指令：${m['command']}', lang: m['lang'] as String?));
          }
        }
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Elder>>(
      stream: widget.backend.elders,
      initialData: widget.backend.currentElders,
      builder: (context, _) {
        final devices = _devices;
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 760;
          final left = _controlCard(devices);
          final right = _speakerCard();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 開發／管理者專用切換（放在 ?sim=1 這頁）
                _SettingToggleCard(
                  backend: widget.backend,
                  settingKey: 'llm_provider',
                  icon: Icons.smart_toy_outlined,
                  title: 'AI 語音對話供應商',
                  subtitle: '控制語音 Agent server 用哪個 LLM。切換後約 10 秒內生效，免重新部署。',
                  options: {
                    'apikey': 'API Key（XCC 閘道）',
                    'mock': 'Mock（離線示範）',
                    'bedrock': 'AWS Bedrock',
                  },
                  fallback: 'apikey',
                ),
                const SizedBox(height: 12),
                _SettingToggleCard(
                  backend: widget.backend,
                  settingKey: 'dispatch_tracking',
                  icon: Icons.my_location,
                  title: '派遣定位模式',
                  subtitle: '家屬地圖上社工位置與 ETA 的來源。'
                      '模擬出發＝demo 動畫（社工自動往長輩家移動、時間倒數）；'
                      '真實 GPS＝只用社工 App 回報的定位推算，沒有就顯示「定位中」。',
                  options: {
                    'simulate': '模擬出發',
                    'real': '真實 GPS',
                  },
                  fallback: 'simulate',
                ),
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 16),
                      Expanded(child: right),
                    ],
                  )
                else
                  Column(children: [left, const SizedBox(height: 16), right]),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _controlCard(List<Elder> devices) {
    Elder? elder;
    for (final e in devices) {
      if (e.deviceSerial == _serial) {
        elder = e;
        break;
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('🔧 硬體模擬（收音機）',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
                '唯一「假」的一環：模擬收音機上報事件、播出下行語音。其餘全真——事件寫進 Supabase，三端即時亮。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            Text('雲端 server：$_base',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
            const SizedBox(height: 14),
            const Text('選擇長輩收音機',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _serial,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                for (final e in devices)
                  DropdownMenuItem(
                    value: e.deviceSerial,
                    child: Text(
                        '${e.deviceSerial} · ${e.name}（${e.preferredLang.label}）'),
                  ),
              ],
              onChanged: (v) => setState(() => _serial = v),
            ),
            const SizedBox(height: 14),
            const Text('觸發事件（＝長輩對收音機做的事）',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            // 已移除實體 SOS 鍵：長輩端所有互動統一走語音按鈕，模擬器不再保留 SOS 流程。
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn('🤕 相機偵測「疑似跌倒」', const Color(0xFFEF6C00),
                  () => _event('fall_suspected')),
              _btn('🗣️ 說「我跌倒了」', const Color(0xFFEF6C00),
                  () => _say('我跌倒了')),
              _btn('🙆 回應「我沒事」', const Color(0xFF2E7D32),
                  () => _say('我沒事啦')),
              _btn('🛒 「我想買牛奶跟雞蛋」', const Color(0xFF1565C0),
                  () => _say('我想買牛奶跟雞蛋')),
              _btn('🔊 「音量大一點」', const Color(0xFF6A1B9A),
                  () => _say('音量大一點')),
            ]),
            const SizedBox(height: 14),
            const Text('或自訂長輩說的話（走真 Bedrock 分類）',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _custom,
                  decoration: const InputDecoration(
                      hintText: '例如：我胸口好痛 / 我睡不著',
                      border: OutlineInputBorder(),
                      isDense: true),
                  onSubmitted: (_) => _sendCustom(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _sendCustom, child: const Text('送出')),
            ]),
            const SizedBox(height: 12),
            Text(
                '流程：跌倒 → 收音機問診（${elder?.preferredLang.label ?? '國語'}）→ 20 秒無回應自動升級 →'
                ' 你在社工 App 接單 → 這裡喇叭念「社工○○大約○分鐘到」→ 按「我到了」→ 喇叭念「社工到囉」。',
                style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _speakerCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.campaign, size: 18),
              const SizedBox(width: 6),
              const Text('收音機喇叭（server 下發的 TTS · 依長輩語言）',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 300,
              child: _lines.isEmpty
                  ? const Center(
                      child: Text('觸發事件後，收音機要念的話會出現在這裡…',
                          style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: _lines.length,
                      itemBuilder: (_, i) => _bubble(_lines[i]),
                    ),
            ),
            const SizedBox(height: 10),
            const Text('最後一次 /voice 回應（原始 JSON）',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F7),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(_raw,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Line l) {
    final taigi = l.lang == 'taigi';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: l.you ? const Color(0xFFEAF2FB) : const Color(0xFFEFF7EE),
        borderRadius: BorderRadius.circular(8),
        border: Border(
            left: BorderSide(
                width: 3,
                color: l.you
                    ? const Color(0xFF1565C0)
                    : const Color(0xFF2E7D32))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(l.text, style: const TextStyle(fontSize: 14))),
            if (!l.you)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                    color: taigi
                        ? const Color(0xFFFCEFCF)
                        : const Color(0xFFDCEBFB),
                    borderRadius: BorderRadius.circular(10)),
                child: Text(taigi ? '台語' : '國語',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: taigi
                            ? const Color(0xFF8A5A00)
                            : const Color(0xFF1565C0))),
              ),
          ]),
          const SizedBox(height: 2),
          Text(
              '${l.at.hour.toString().padLeft(2, '0')}:${l.at.minute.toString().padLeft(2, '0')}:${l.at.second.toString().padLeft(2, '0')}'
              '${l.you ? '（長輩說 / 按鍵）' : '（喇叭播）'}',
              style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
        ],
      ),
    );
  }

  void _sendCustom() {
    final t = _custom.text.trim();
    if (t.isEmpty) return;
    _say(t);
    _custom.clear();
  }

  Widget _btn(String label, Color c, VoidCallback onTap) => FilledButton(
        style: FilledButton.styleFrom(backgroundColor: c),
        onPressed: _serial == null ? null : onTap,
        child: Text(label),
      );
}

/// 通用「後台設定切換卡」（寫後端 app_settings 的某個 key）。開發／管理者專用，
/// 只出現在 ?sim=1 頁。用於 LLM 供應商、派遣定位模式等即時切換（改了免重新部署）。
/// 讀寫一律走 BackendClient，兩套環境（Supabase／AWS）共用同一個元件。
class _SettingToggleCard extends StatefulWidget {
  const _SettingToggleCard({
    required this.backend,
    required this.settingKey,
    required this.title,
    required this.subtitle,
    required this.options,
    required this.fallback,
    this.icon = Icons.tune,
  });

  final BackendClient backend;
  final String settingKey;
  final String title;
  final String subtitle;
  final Map<String, String> options; // value → label
  final String fallback;
  final IconData icon;

  @override
  State<_SettingToggleCard> createState() => _SettingToggleCardState();
}

class _SettingToggleCardState extends State<_SettingToggleCard> {
  String? _value;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await widget.backend.appSetting(widget.settingKey);
      if (mounted) setState(() => _value = v ?? widget.fallback);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  Future<void> _set(String v) async {
    if (v == _value || _busy) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.backend.setAppSetting(widget.settingKey, v);
      if (mounted) setState(() => _value = v);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.icon, size: 20),
                const SizedBox(width: 8),
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(width: 10),
                if (_busy)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 4),
            Text(widget.subtitle,
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFF666666))),
            const SizedBox(height: 12),
            if (_value == null && _err == null)
              const Text('讀取中…', style: TextStyle(color: Colors.grey))
            else
              SegmentedButton<String>(
                segments: [
                  for (final e in widget.options.entries)
                    ButtonSegment(value: e.key, label: Text(e.value)),
                ],
                selected: {_value ?? widget.fallback},
                onSelectionChanged: _busy ? null : (s) => _set(s.first),
                showSelectedIcon: false,
              ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text('讀寫設定失敗：$_err',
                  style:
                      const TextStyle(color: Color(0xFFC62828), fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
