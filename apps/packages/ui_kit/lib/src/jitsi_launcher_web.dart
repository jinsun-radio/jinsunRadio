// Web：直接開 Jitsi 房間分頁（兩個瀏覽器視窗以同房名進同一場會議）。
// 必須在使用者點擊當下呼叫，否則會被瀏覽器擋彈窗。
import 'package:url_launcher/url_launcher.dart';

import 'jitsi_config.dart';

Future<void> joinJitsi({
  required String room,
  required String displayName,
  bool audioOnly = true,
  // Web 開的是另一個分頁，關閉分頁偵測不到，onEnded 不支援（僅行動端有效）。
  void Function()? onEnded,
}) async {
  final name = Uri.encodeComponent(displayName);
  // 用 hash fragment 帶入 Jitsi 設定：預填顯示名、關預覽頁、視訊預設關（語音先行）。
  final url = Uri.parse(
    '$kJitsiServerUrl/$room'
    '#userInfo.displayName=%22$name%22'
    '&config.startWithVideoMuted=$audioOnly'
    '&config.prejoinConfig.enabled=false',
  );
  await launchUrl(url, webOnlyWindowName: '_blank');
}

/// Web 端無法遠端關閉已開出去的分頁；退出交由使用者自行關閉。
Future<void> hangUpJitsi() async {}
