// 平台分流：行動端用 Jitsi 原生 SDK，Web 開 meet.jit.si 分頁。
// 用條件式 import 讓 Web build 不會碰到只支援 android/ios 的原生外掛（含 dart:io）。
import 'jitsi_launcher_io.dart'
    if (dart.library.html) 'jitsi_launcher_web.dart' as impl;

/// 進入 Jitsi 房間通話。雙方以同一 [room] 名稱進同一場會議。
class JitsiCallLauncher {
  /// [onEnded] 於會議結束（自己掛斷等）時回呼；Web 端不支援（開分頁偵測不到）。
  static Future<void> join({
    required String room,
    required String displayName,
    bool audioOnly = true,
    void Function()? onEnded,
  }) =>
      impl.joinJitsi(
          room: room,
          displayName: displayName,
          audioOnly: audioOnly,
          onEnded: onEnded);

  /// 主動退出目前通話（如：撥號後被對方拒接）。Web 端為 no-op。
  static Future<void> hangUp() => impl.hangUpJitsi();
}
