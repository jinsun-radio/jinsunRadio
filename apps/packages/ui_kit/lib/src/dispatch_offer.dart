import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 來單受理（志工端）：收到緊急派遣／請支援時全螢幕彈出。
/// 可「按鈕同意/拒絕」，也可「說話同意/拒絕」（按住錄音→Whisper 轉文字→判斷語意）。
/// 同意＝接單前往；拒絕＝把單讓給其他志工（改派/開放全體）。
class DispatchOfferScreen extends StatefulWidget {
  const DispatchOfferScreen({
    super.key,
    required this.backend,
    required this.title,
    required this.elderName,
    required this.address,
    required this.etaText,
    required this.onAccept,
    required this.onDecline,
    required this.accent,
    this.canAccept = true,
    this.warning,
  });

  final BackendClient backend;
  final String title; // 如「緊急派遣・請支援」
  final String elderName;
  final String address;
  final String etaText; // 如「約 1.2 km・機車約 4 分鐘到」
  final bool canAccept; // 證件不齊時為 false
  final String? warning; // 不能接單的原因
  final Color accent;
  // 回傳 Future，畫面會 await 完成才關閉；失敗會顯示錯誤、不關閉，讓社工能重試。
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;

  @override
  State<DispatchOfferScreen> createState() => _DispatchOfferScreenState();
}

class _DispatchOfferScreenState extends State<DispatchOfferScreen> {
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _transcribing = false;
  bool _handled = false;
  String _recFilename = 'audio.m4a';
  String _recMime = 'audio/mp4';
  String? _heard; // 顯示「聽到：…」

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  bool _busy = false;

  Future<void> _accept() async {
    if (_handled || _busy) return;
    if (!widget.canAccept) {
      _toast(widget.warning ?? '目前無法接此單');
      return;
    }
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    try {
      await widget.onAccept(); // 真的等接單寫入完成，才關畫面
      _handled = true;
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('接單失敗，請再試一次：$e');
      }
    }
  }

  Future<void> _decline() async {
    if (_handled || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onDecline();
      _handled = true;
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('操作失敗，請再試一次：$e');
      }
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  // ---- 語音同意/拒絕 ----
  Future<void> _startRecord() async {
    if (_recording || _transcribing) return;
    if (!await _recorder.hasPermission()) {
      _toast('請允許使用麥克風才能語音回覆');
      return;
    }
    AudioEncoder encoder = AudioEncoder.aacLc;
    _recFilename = 'audio.m4a';
    _recMime = 'audio/mp4';
    if (kIsWeb) {
      if (await _recorder.isEncoderSupported(AudioEncoder.opus)) {
        encoder = AudioEncoder.opus;
        _recFilename = 'audio.webm';
        _recMime = 'audio/webm';
      }
    }
    var path = '';
    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/jinsun_offer_${DateTime.now().millisecondsSinceEpoch}.m4a';
    }
    try {
      await _recorder.start(RecordConfig(encoder: encoder), path: path);
    } catch (e) {
      _toast('無法開始錄音：$e');
      return;
    }
    setState(() => _recording = true);
  }

  Future<void> _stopAndParse() async {
    if (!_recording) return;
    setState(() => _recording = false);
    final path = await _recorder.stop();
    if (path == null || path.isEmpty) return;
    setState(() => _transcribing = true);
    try {
      final bytes = await XFile(path).readAsBytes();
      final text = await widget.backend
          .transcribeAudio(bytes, filename: _recFilename, mimeType: _recMime);
      if (!mounted) return;
      setState(() {
        _transcribing = false;
        _heard = text;
      });
      final intent = _parseIntent(text);
      if (intent == true) {
        _accept();
      } else if (intent == false) {
        _decline();
      } else {
        _toast('沒聽清楚，請說「同意」或「拒絕」，或直接按下方按鈕');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _transcribing = false);
        _toast('語音辨識失敗，請改用按鈕');
      }
    }
  }

  /// 從辨識文字判斷同意(true)/拒絕(false)/不確定(null)。先判拒絕避免「不能去」被誤判。
  static bool? _parseIntent(String text) {
    final t = text.replaceAll(RegExp(r'\s'), '');
    const no = ['拒絕', '不行', '沒辦法', '不能', '不要', '無法', '改派', '不接', '別派'];
    const yes = ['同意', '好的', '接單', '我去', '我來', '可以', '沒問題', '前往', '答應', '收到'];
    for (final w in no) {
      if (t.contains(w)) return false;
    }
    for (final w in yes) {
      if (t.contains(w)) return true;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    const white70 = Color(0xB3FFFFFF);
    return PopScope(
      canPop: false, // 只能用同意／拒絕離開
      child: Scaffold(
        backgroundColor: const Color(0xFF14141C),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                      color: Color(0xFFE5484D), shape: BoxShape.circle),
                  child: const Icon(Icons.emergency_share,
                      size: 52, color: Colors.white),
                ),
                const SizedBox(height: 18),
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white)),
                const SizedBox(height: 10),
                Text(widget.elderName,
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: Colors.white)),
                const SizedBox(height: 6),
                Text('📍 ${widget.address}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, color: white70)),
                const SizedBox(height: 4),
                Text(widget.etaText,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                if (widget.warning != null) ...[
                  const SizedBox(height: 10),
                  Text('⚠️ ${widget.warning}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFFFC9A8))),
                ],
                const SizedBox(height: 20),
                // 語音回覆
                _voiceRow(white70),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: _bigBtn(
                        color: const Color(0xFFC62828),
                        icon: Icons.close,
                        label: '拒絕（改派）',
                        onTap: _busy ? null : _decline,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _bigBtn(
                        color: const Color(0xFF2E7D32),
                        icon: Icons.check,
                        label: _busy ? '處理中…' : '同意接單',
                        onTap: _busy ? null : _accept,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _voiceRow(Color white70) {
    if (_transcribing) {
      return const Text('辨識中…', style: TextStyle(color: Color(0xB3FFFFFF)));
    }
    return Column(
      children: [
        GestureDetector(
          onTap: _recording ? _stopAndParse : _startRecord,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: _recording
                  ? const Color(0xFFE5484D)
                  : Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: white70),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_recording ? Icons.stop : Icons.mic,
                    color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(_recording ? '說完按這裡送出' : '用說的回覆（同意／拒絕）',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
        if (_heard != null && _heard!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('聽到：$_heard',
              style: TextStyle(fontSize: 12.5, color: white70)),
        ],
      ],
    );
  }

  Widget _bigBtn(
      {required Color color,
      required IconData icon,
      required String label,
      required VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: BoxDecoration(
            color: onTap == null ? color.withValues(alpha: 0.5) : color,
            borderRadius: BorderRadius.circular(18)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}
