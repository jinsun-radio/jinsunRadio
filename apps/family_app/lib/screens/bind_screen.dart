import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';
import 'pairing_screen.dart';

/// 綁定長輩的收音機：輸入序號或掃 QR Code
class BindScreen extends StatefulWidget {
  const BindScreen({super.key, required this.local, this.canPop = false});

  final AppLocal local;
  final bool canPop;

  @override
  State<BindScreen> createState() => _BindScreenState();
}

class _BindScreenState extends State<BindScreen> {
  final _code = TextEditingController(text: 'JS-0001');
  String? _error;

  Future<void> _bind() async {
    final err = await widget.local.bindBySerial(_code.text);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (widget.canPop) Navigator.of(context).pop();
  }

  Future<void> _pairBluetooth() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PairingScreen(local: widget.local)),
    );
    if (ok == true && mounted) {
      // 藍牙配對成功時已在流程內完成綁定；有綁到就關掉本頁。
      if (widget.local.boundElders.isNotEmpty && widget.canPop) {
        Navigator.of(context).pop();
      } else if (widget.local.boundElders.isNotEmpty) {
        setState(() {});
      }
    }
  }

  Future<void> _scanQr() async {
    final serial = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (serial != null && mounted) {
      setState(() {
        _code.text = serial;
        _error = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('掃描成功：$serial')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('綁定長輩的收音機'),
        automaticallyImplyLeading: widget.canPop,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFEFEC),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Column(
                      children: [
                        Text('📻', style: TextStyle(fontSize: 40)),
                        SizedBox(height: 8),
                        Text(
                          '第一次設定：用藍牙配對收音機並幫它連上 Wi-Fi。\n'
                          '已在使用中：掃描底部 QR Code 或輸入序號（JS- 開頭）即可綁定。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13.5, color: Color(0xFF52524E)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('用藍牙配對新收音機'),
                    onPressed: _pairBluetooth,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('掃描 QR Code 綁定'),
                    onPressed: _scanQr,
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('或手動輸入序號',
                          style: TextStyle(
                              fontSize: 12.5, color: JinsunColors.muted)),
                    ),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: '收音機序號',
                      hintText: 'JS-0001',
                      prefixIcon: const Icon(Icons.qr_code_2),
                      errorText: _error,
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                      onPressed: _bind,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      child: const Text('綁定')),
                  const SizedBox(height: 12),
                  const Text(
                    'Demo 可用序號：JS-0001（林阿春）、JS-0002（王金火）、JS-0003（陳玉蘭）',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: JinsunColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// QR 掃描畫面。
/// Demo 版：模擬相機取景與掃描動畫，2 秒後回傳序號；
/// 真機版換 mobile_scanner 套件，介面（pop 回序號字串）不變。
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _line;
  Timer? _found;

  @override
  void initState() {
    super.initState();
    _line = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _found = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) Navigator.of(context).pop('JS-0001');
    });
  }

  @override
  void dispose() {
    _line.dispose();
    _found?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const frame = 240.0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('掃描 QR Code',
            style: TextStyle(color: Colors.white, fontFamily: 'NotoSansTC')),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: frame,
              height: frame,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  for (final a in const [
                    Alignment.topLeft,
                    Alignment.topRight,
                    Alignment.bottomLeft,
                    Alignment.bottomRight
                  ])
                    Align(
                      alignment: a,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          border: Border(
                            top: a == Alignment.topLeft || a == Alignment.topRight
                                ? const BorderSide(color: Colors.white, width: 4)
                                : BorderSide.none,
                            bottom: a == Alignment.bottomLeft ||
                                    a == Alignment.bottomRight
                                ? const BorderSide(color: Colors.white, width: 4)
                                : BorderSide.none,
                            left: a == Alignment.topLeft ||
                                    a == Alignment.bottomLeft
                                ? const BorderSide(color: Colors.white, width: 4)
                                : BorderSide.none,
                            right: a == Alignment.topRight ||
                                    a == Alignment.bottomRight
                                ? const BorderSide(color: Colors.white, width: 4)
                                : BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  AnimatedBuilder(
                    animation: _line,
                    builder: (context, _) => Positioned(
                      top: 12 + (frame - 28) * _line.value,
                      left: 12,
                      right: 12,
                      child: Container(height: 2.5, color: const Color(0xFF7FD08F)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('對準收音機底部的 QR Code',
                style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('（Demo：2 秒後自動完成掃描）',
                style: TextStyle(color: Colors.white38, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}
