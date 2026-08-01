import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';

import 'theme.dart';

/// 網頁端「即時推播」——不靠系統推播，靠 Supabase Realtime（WebSocket）串流，
/// 一有新通知就從畫面上方滑下一張橫幅，依嚴重度上色，數秒後自動收起；
/// 點橫幅可查看（[onTap]），按 X 立即關閉。掛在已登入畫面外層即可。
class InAppNotifier extends StatefulWidget {
  const InAppNotifier({
    super.key,
    required this.notifications,
    required this.child,
    this.onTap,
    this.filter,
    this.autoDismiss = const Duration(seconds: 6),
  });

  /// 後端通知串流（broadcast；只會往後推「新」通知，初次載入不會回放）。
  final Stream<AppNotification> notifications;
  final Widget child;

  /// 點橫幅本體（通常導去「即時紀錄」收件匣或該長輩）。
  final void Function(AppNotification n)? onTap;

  /// 只彈符合條件的通知（例：家屬只看自己綁定的長輩）。回 false 就不彈。
  final bool Function(AppNotification n)? filter;

  /// 幾秒後自動收起。
  final Duration autoDismiss;

  @override
  State<InAppNotifier> createState() => _InAppNotifierState();
}

class _InAppNotifierState extends State<InAppNotifier> {
  StreamSubscription<AppNotification>? _sub;
  OverlayEntry? _entry;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _sub = widget.notifications.listen(_onNotif);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _autoTimer?.cancel();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _dismiss() {
    _autoTimer?.cancel();
    _entry?.remove();
    _entry = null;
  }

  void _onNotif(AppNotification n) {
    if (!mounted) return;
    if (widget.filter != null && !widget.filter!(n)) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    // 永遠顯示最新一則：新的來就取代舊的。
    _dismiss();
    _entry = OverlayEntry(
      builder: (_) => _NotifBanner(
        notif: n,
        onTap: () {
          _dismiss();
          widget.onTap?.call(n);
        },
        onClose: _dismiss,
      ),
    );
    overlay.insert(_entry!);
    _autoTimer = Timer(widget.autoDismiss, () {
      if (mounted) _dismiss();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NotifBanner extends StatefulWidget {
  const _NotifBanner(
      {required this.notif, required this.onTap, required this.onClose});

  final AppNotification notif;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_NotifBanner> createState() => _NotifBannerState();
}

class _NotifBannerState extends State<_NotifBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260))
    ..forward();
  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, -1.3), end: Offset.zero)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _title(Severity s) => switch (s) {
        Severity.emergency => '緊急通知',
        Severity.attention => '需要留意',
        _ => '通知',
      };

  IconData _icon(Severity s) => switch (s) {
        Severity.emergency => Icons.emergency,
        Severity.attention => Icons.warning_amber_rounded,
        _ => Icons.check_circle,
      };

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final n = widget.notif;
    final accent = severityTextColor(n.severity);
    final bg = severityBgColor(n.severity);
    final topPad = MediaQuery.of(context).padding.top;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: EdgeInsets.only(top: topPad + 8, left: 12, right: 12),
          child: Material(
            elevation: 10,
            borderRadius: BorderRadius.circular(16),
            shadowColor: const Color(0x22000000),
            color: Colors.white,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: widget.onTap,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: accent.withValues(alpha: 0.35), width: 1.4),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                      child: Icon(_icon(n.severity), size: 20, color: accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(_title(n.severity),
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: accent)),
                              const Spacer(),
                              Text(_hhmm(n.at),
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      color: JinsunColors.muted)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(n.message,
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: JinsunColors.ink,
                                  height: 1.35),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: widget.onClose,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close,
                          size: 18, color: JinsunColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
