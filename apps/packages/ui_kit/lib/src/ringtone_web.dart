// Web：用 Web Audio 產生「嗶——嗶——」來電音，每秒一響。
// 瀏覽器自動播放政策下，若使用者尚未與頁面互動可能無聲；視覺來電畫面仍會顯示。
import 'dart:async';

import 'package:web/web.dart' as web;

web.AudioContext? _ctx;
Timer? _timer;

void _beep() {
  final ctx = _ctx;
  if (ctx == null) return;
  final osc = ctx.createOscillator();
  final gain = ctx.createGain();
  osc.type = 'sine';
  osc.frequency.value = 480;
  gain.gain.value = 0.12;
  osc.connect(gain);
  gain.connect(ctx.destination);
  final now = ctx.currentTime;
  osc.start(now);
  osc.stop(now + 0.4);
}

void startRing() {
  try {
    _ctx ??= web.AudioContext();
    _beep();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _beep());
  } catch (_) {
    // AudioContext 不可用時靜默（視覺來電仍在）
  }
}

void stopRing() {
  _timer?.cancel();
  _timer = null;
}
