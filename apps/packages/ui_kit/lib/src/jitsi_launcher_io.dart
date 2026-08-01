// 行動端（Android/iOS）：Jitsi 原生 SDK 全螢幕通話。
import 'package:flutter/foundation.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';

import 'jitsi_config.dart';

final JitsiMeet _jitsi = JitsiMeet();

Future<void> joinJitsi({
  required String room,
  required String displayName,
  bool audioOnly = true,
  void Function()? onEnded,
}) async {
  final options = JitsiMeetConferenceOptions(
    serverURL: kJitsiServerUrl,
    room: room,
    configOverrides: {
      // 純語音：不談判視訊軌，接通更快、耗流量更少。
      'startAudioOnly': audioOnly,
      'startWithAudioMuted': false,
      'startWithVideoMuted': audioOnly,
      // 1:1 直接走 P2P（媒體不繞遠端橋接器），延遲與接通時間都更好。
      'p2p': {'enabled': true},
      // 不跳去裝／開原生 Jitsi App（會多一段延遲與詢問）。
      'disableDeepLinking': true,
      'requireDisplayName': false,
      'subject': '金孫收音機・安全通話',
    },
    featureFlags: {
      'welcomepage.enabled': false,
      'prejoinpage.enabled': false,
      'invite.enabled': false,
      'call-integration.enabled': false,
      'video-share.enabled': false,
      'tile-view.enabled': false,
    },
    userInfo: JitsiMeetUserInfo(displayName: displayName),
  );
  // 會議結束（自己掛斷或被踢出房）→ 通知呼叫端同步號誌狀態。
  final listener = onEnded == null
      ? null
      : JitsiMeetEventListener(conferenceTerminated: (_, __) => onEnded());
  await _jitsi.join(options, listener);
}

/// 主動退出目前通話（如：撥號後被對方拒接）。
Future<void> hangUpJitsi() async {
  final resp = await _jitsi.hangUp();
  debugPrint('[call] hangUp 結果 isSuccess=${resp.isSuccess}');
}
