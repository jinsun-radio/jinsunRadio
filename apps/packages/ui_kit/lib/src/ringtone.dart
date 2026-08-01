// 來電鈴聲：行動端用系統鈴聲，Web 用 Web Audio 嗶聲（自動播放政策下可能需先互動）。
import 'ringtone_io.dart' if (dart.library.html) 'ringtone_web.dart' as impl;

class RingtonePlayer {
  static void start() => impl.startRing();
  static void stop() => impl.stopRing();
}
