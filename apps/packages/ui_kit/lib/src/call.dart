import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jinsun_core/jinsun_core.dart';

import 'chat.dart';
import 'jitsi_launcher.dart';
import 'ringtone.dart';

/// 限時遮罩通話（家屬 ↔ 志工）：走 Jitsi 通話 + 來電響鈴。
///
/// 設計重點：
/// - 整條鏈路只有 Jitsi room 名稱、沒有電話號碼 → 遮罩天生成立。
/// - 一張派遣單一通話一個 room；派遣結案後入口消失＝通話自然失效。
/// - 來電響鈴：對方發起後，本端透過 [BackendClient.callSignals] 收到 ringing
///   號誌 → 全螢幕來電畫面 + 鈴聲 + 震動；接聽才進 Jitsi 房間。
/// - 平台：行動端用 Jitsi 原生 SDK；Web 開 meet.jit.si 分頁（兩個瀏覽器對話）。

/// 通話期間監看號誌：對方拒接／取消／掛斷 → 自動退出 Jitsi 房間。
/// 撥號端與接聽端都要掛（雙向對稱），否則對方掛斷後自己會留在房裡。
StreamSubscription<CallSignal> _watchCallEnd(
    BackendClient backend, String signalId) {
  late StreamSubscription<CallSignal> sub;
  sub = backend.callSignals.listen((s) {
    if (s.id != signalId) return;
    debugPrint('[call] 號誌更新 id=${s.id} status=${s.status.name}');
    if (s.status == CallStatus.declined ||
        s.status == CallStatus.canceled ||
        s.status == CallStatus.ended) {
      sub.cancel();
      debugPrint('[call] 對方結束通話（${s.status.name}）→ 退出房間');
      JitsiCallLauncher.hangUp();
    }
  });
  return sub;
}

/// 發起遮罩通話（撥號端共用流程）：
/// 1) 自己先進房（保住 Web 點擊手勢）
/// 2) 送 ringing 號誌讓對方響鈴（並觸發對方的來電推播）
/// 3) 監看號誌：被拒接／對方掛斷 → 自動退出房間，不留人乾等
/// 4) 自己掛斷（會議結束事件）→ 號誌標 ended，對方的來電畫面同步收掉
void _startMaskedCall(
  BuildContext context, {
  required BackendClient backend,
  required String taskId,
  required CallRole selfRole,
  required String selfName,
  required String peerName,
}) {
  final to = selfRole == CallRole.family ? CallRole.volunteer : CallRole.family;
  // room 在點擊當下就產好：Web 才能立刻開分頁（避免被擋彈窗）。
  final room =
      'jinsun-$taskId-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  String? signalId;
  StreamSubscription<CallSignal>? sub;

  JitsiCallLauncher.join(
    room: room,
    displayName: selfName,
    onEnded: () {
      debugPrint('[call] 撥號端會議結束 → 標 ended');
      sub?.cancel();
      sub = null;
      final id = signalId;
      if (id != null) backend.setCallStatus(id, CallStatus.ended);
    },
  );
  backend
      .startCall(
          taskId: taskId, from: selfRole, to: to, fromName: selfName, room: room)
      .then((sig) {
    debugPrint('[call] 撥號成功 signalId=${sig.id}，開始監看');
    signalId = sig.id;
    sub = _watchCallEnd(backend, sig.id);
  });
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('撥號給$peerName…對方接聽後即可通話')),
  );
}

/// 派遣進行中的「安全轉接」入口按鈕（放派遣卡／任務卡）。按下＝發話。
class MaskedCallButton extends StatelessWidget {
  const MaskedCallButton({
    super.key,
    required this.label,
    required this.backend,
    required this.taskId,
    required this.selfRole,
    required this.selfName,
    required this.peerName,
    required this.peerLabel,
    required this.accent,
  });

  final String label; // 按鈕文字，如「聯絡志工 阿明」「聯絡家屬」
  final BackendClient backend;
  final String taskId;
  final CallRole selfRole; // 我方角色（發話者）
  final String selfName; // 我方顯示名（傳給對方當來電顯示）
  final String peerName; // 對方顯示名
  final String peerLabel; // 對方角色描述
  final Color accent;

  void _call(BuildContext context) => _startMaskedCall(
        context,
        backend: backend,
        taskId: taskId,
        selfRole: selfRole,
        selfName: selfName,
        peerName: peerName,
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: accent,
          side: BorderSide(color: accent.withValues(alpha: 0.5)),
        ),
        icon: const Icon(Icons.lock, size: 17),
        label: Text('$label（安全轉接）'),
        onPressed: () => _call(context),
      ),
    );
  }
}

/// 整合「聯絡」入口：一顆主按鈕，點開小選單讓使用者選「撥打電話」或「文字訊息」。
/// 撥打電話走與 [MaskedCallButton] 相同的遮罩通話流程；文字訊息開 [ChatScreen]。
class ContactButton extends StatelessWidget {
  const ContactButton({
    super.key,
    required this.backend,
    required this.taskId,
    required this.accent,
    // 通話（遮罩轉接）所需
    required this.callSelfRole,
    required this.callSelfName,
    required this.callPeerName,
    required this.callPeerLabel,
    // 文字訊息所需
    required this.chatMyRole,
    required this.chatTitle,
    this.chatMyId,
    this.label = '聯絡',
  });

  final BackendClient backend;
  final String taskId;
  final Color accent;
  final CallRole callSelfRole; // 我方角色（發話者）
  final String callSelfName; // 我方顯示名（傳給對方當來電顯示）
  final String callPeerName; // 對方顯示名
  final String callPeerLabel; // 對方角色描述
  final ChatFromRole chatMyRole; // 我在聊天中的角色
  final String chatTitle; // 聊天頁標題
  final String? chatMyId;
  final String label;

  /// 發起遮罩通話（邏輯同 [MaskedCallButton]）。
  void _startCall(BuildContext context) => _startMaskedCall(
        context,
        backend: backend,
        taskId: taskId,
        selfRole: callSelfRole,
        selfName: callSelfName,
        peerName: callPeerName,
      );

  /// 點「聯絡」直接進聊天頁（不再跳選擇 Modal）。聊天頁底部有玻璃擬態
  /// 🎤 語音輸入（ASR）／📞 通話（Jitsi 遮罩安全轉接）兩顆鈕。
  void _openChat(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        backend: backend,
        taskId: taskId,
        myRole: chatMyRole,
        myId: chatMyId,
        title: chatTitle,
        accent: accent,
        peerName: callPeerName,
        onCall: () => _startCall(context),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: accent,
        ),
        icon: const Icon(Icons.chat_bubble_outline, size: 18),
        label: Text(label),
        onPressed: () => _openChat(context),
      ),
    );
  }
}

/// 來電畫面（受話端）：鈴聲＋震動；接聽→進 Jitsi，拒接→關閉。
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.backend,
    required this.signal,
    required this.selfName,
    required this.accent,
  });

  final BackendClient backend;
  final CallSignal signal;
  final String selfName;
  final Color accent;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  Timer? _vibrate;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    RingtonePlayer.start();
    HapticFeedback.heavyImpact();
    _vibrate = Timer.periodic(const Duration(milliseconds: 1200),
        (_) => HapticFeedback.heavyImpact());
  }

  void _stopRing() {
    _vibrate?.cancel();
    RingtonePlayer.stop();
  }

  void _accept() {
    if (_handled) return;
    _handled = true;
    _stopRing();
    // 先 join（保住 Web 點擊手勢），再更新狀態、關畫面。
    // 自己掛斷（會議結束）→ 號誌標 ended；同時監看號誌，
    // 對方先掛斷 → 自動退出房間（不用自己按掛斷）。
    StreamSubscription<CallSignal>? watch;
    JitsiCallLauncher.join(
      room: widget.signal.room,
      displayName: widget.selfName,
      onEnded: () {
        debugPrint('[call] 接聽端會議結束 → 標 ended');
        watch?.cancel();
        watch = null;
        widget.backend.setCallStatus(widget.signal.id, CallStatus.ended);
      },
    );
    watch = _watchCallEnd(widget.backend, widget.signal.id);
    widget.backend.setCallStatus(widget.signal.id, CallStatus.accepted);
    // 用 pop() 而非 maybePop()：本頁 PopScope(canPop:false) 會擋下 maybePop，
    // 造成通話結束後卡回來電畫面（接聽／拒接）出不去。
    Navigator.of(context).pop();
  }

  void _decline() {
    if (_handled) return;
    _handled = true;
    _stopRing();
    widget.backend.setCallStatus(widget.signal.id, CallStatus.declined);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _stopRing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fromVol = widget.signal.from == CallRole.volunteer;
    return PopScope(
      canPop: false, // 只能用接聽／拒接離開，避免誤觸返回鍵漏接
      child: _CallScaffold(
        peerName: widget.signal.fromName ?? (fromVol ? '志工' : '家屬'),
        peerLabel: fromVol ? '前來協助的志工' : '長輩的家人',
        accent: widget.accent,
        hint: '來電中…',
        actions: [
          _CallActionButton(
            color: const Color(0xFFFF3B30),
            icon: Icons.call_end,
            label: '拒接',
            onTap: _decline,
          ),
          _CallActionButton(
            color: const Color(0xFF34C759),
            icon: Icons.call,
            label: '接聽',
            onTap: _accept,
          ),
        ],
      ),
    );
  }
}

/// 掛在已登入畫面外層：監聽 [BackendClient.callSignals]，收到打給「我」的
/// ringing 就彈全螢幕來電；對方取消／結束就自動收掉。
class CallListener extends StatefulWidget {
  const CallListener({
    super.key,
    required this.backend,
    required this.selfRole,
    required this.selfName,
    required this.accent,
    required this.child,
  });

  final BackendClient backend;
  final CallRole selfRole; // 本端角色（family / volunteer）
  final String selfName; // 接聽後進 Jitsi 用的顯示名
  final Color accent;
  final Widget child;

  @override
  State<CallListener> createState() => _CallListenerState();
}

class _CallListenerState extends State<CallListener> {
  StreamSubscription<CallSignal>? _sub;
  StreamSubscription<Map<String, dynamic>>? _tapSub;
  final Set<String> _handled = {}; // 已處理過的號誌（避免重複彈）
  String? _shownId; // 目前正顯示的來電號誌 id

  @override
  void initState() {
    super.initState();
    _sub = widget.backend.callSignals.listen(_onSignal);
    // 來電推播：點通知進 App → 開來電畫面再接聽。
    // （背景／被系統凍結時 realtime 會斷線漏事件，推播是叫得醒的那條路。）
    _tapSub = PushService.instance.taps.listen(_onPushTap);
    final pending = PushService.instance.takePendingTap();
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onPushTap(pending));
    }
  }

  Future<void> _onSignal(CallSignal s) async {
    if (s.to != widget.selfRole) return; // 只處理打給「我」的

    if (s.status == CallStatus.ringing) {
      await _showIncoming(s);
    } else {
      // 對方取消／結束 → 若來電畫面還開著就收掉。
      // 用 pop()：來電畫面 PopScope(canPop:false) 會擋下 maybePop。
      if (_shownId == s.id) {
        _shownId = null;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// 點擊「📞 來電」推播：先查最新狀態（通知可能是幾分鐘前的），
  /// 還在響鈴才彈來電畫面；查不到（如 MockBackend）就信任推播內容。
  Future<void> _onPushTap(Map<String, dynamic> data) async {
    if (data['kind'] != 'call') return;
    final toRole = data['toRole'];
    if (toRole is String &&
        toRole.isNotEmpty &&
        toRole != widget.selfRole.wire) {
      return;
    }
    final id = (data['signalId'] ?? '').toString();
    final room = (data['room'] ?? '').toString();
    if (id.isEmpty || room.isEmpty) return;

    CallSignal? s;
    try {
      s = await widget.backend.getCallSignal(id);
    } catch (_) {}
    if (s != null && s.status != CallStatus.ringing) return; // 來電已結束
    s ??= CallSignal(
      id: id,
      taskId: (data['taskId'] ?? '').toString(),
      room: room,
      from: CallRoleWire.parse((data['fromRole'] ?? 'volunteer').toString()),
      to: widget.selfRole,
      status: CallStatus.ringing,
      fromName: (data['fromName'] ?? '').toString().isEmpty
          ? null
          : data['fromName'].toString(),
      createdAt: DateTime.now(),
    );
    if (!mounted) return;
    await _showIncoming(s);
  }

  Future<void> _showIncoming(CallSignal s) async {
    if (_handled.contains(s.id) || _shownId != null) return;
    _handled.add(s.id);
    _shownId = s.id;
    final nav = Navigator.of(context, rootNavigator: true);
    await nav.push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => IncomingCallScreen(
        backend: widget.backend,
        signal: s,
        selfName: widget.selfName,
        accent: widget.accent,
      ),
    ));
    if (_shownId == s.id) _shownId = null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tapSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---- 共用視覺 ----

class _CallScaffold extends StatelessWidget {
  const _CallScaffold({
    required this.peerName,
    required this.peerLabel,
    required this.accent,
    required this.hint,
    required this.actions,
  });

  final String peerName;
  final String peerLabel;
  final Color accent;
  final String hint;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    const white70 = Color(0xB3FFFFFF);
    const white45 = Color(0x73FFFFFF);
    return Scaffold(
      backgroundColor: const Color(0xFF14141C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              CircleAvatar(
                radius: 54,
                backgroundColor: accent,
                child: const Icon(Icons.person, size: 54, color: Colors.white),
              ),
              const SizedBox(height: 20),
              Text(peerName,
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
              const SizedBox(height: 4),
              Text(peerLabel,
                  style: const TextStyle(fontSize: 15, color: white70)),
              const SizedBox(height: 18),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock, size: 15, color: white70),
                  SizedBox(width: 6),
                  Text('號碼已遮蔽・透過金孫收音機安全轉接',
                      style: TextStyle(fontSize: 12.5, color: white45)),
                ],
              ),
              const SizedBox(height: 22),
              Text(hint,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: white70)),
              const Spacer(flex: 2),
              Row(
                mainAxisAlignment: actions.length > 1
                    ? MainAxisAlignment.spaceEvenly
                    : MainAxisAlignment.center,
                children: actions,
              ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  '此通話僅在本次派遣進行中有效，結案後自動失效；'
                  '雙方皆看不到對方的真實號碼。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.6, color: white45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 14),
        Text(label,
            style: const TextStyle(fontSize: 13, color: Color(0xB3FFFFFF))),
      ],
    );
  }
}
