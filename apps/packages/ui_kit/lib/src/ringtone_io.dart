// 行動端（Android/iOS）：系統鈴聲循環。
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

void startRing() =>
    FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false);

void stopRing() => FlutterRingtonePlayer().stop();
