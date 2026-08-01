import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

/// 掛在志工端已登入畫面外層：緊急派遣單就近派給「我」（或改派給我）時，
/// 從**畫面上方滑下一張推播橫幅**（直接按「確認接單」／「拒絕」；點橫幅本體展開完整詳情）。
/// 也接推播點擊（App 在背景被叫醒）→ 開同一張橫幅。
class DispatchListener extends StatefulWidget {
  const DispatchListener({
    super.key,
    required this.backend,
    required this.volunteerName,
    required this.child,
  });

  final BackendClient backend;
  final String volunteerName;
  final Widget child;

  @override
  State<DispatchListener> createState() => _DispatchListenerState();
}

class _DispatchListenerState extends State<DispatchListener> {
  StreamSubscription<List<DispatchTask>>? _sub;
  StreamSubscription<Map<String, dynamic>>? _tapSub;
  final Set<String> _seen = {}; // 已處理過的「單:指派對象」鍵
  bool _seeded = false;
  OverlayEntry? _entry; // 目前顯示中的頂部推播橫幅
  String? _shownTaskId; // 橫幅對應的單（用來在單被接走/取消時自動收掉）

  BackendClient get backend => widget.backend;

  @override
  void initState() {
    super.initState();
    _sub = backend.tasks.listen(_onTasks);
    _tapSub = PushService.instance.taps.listen(_onTap);
    final pending = PushService.instance.takePendingTap();
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onTap(pending));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tapSub?.cancel();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  String _key(DispatchTask t) => '${t.id}:${t.assigneeName}';

  bool _isForMe(DispatchTask t) =>
      t.kind == DispatchKind.emergency &&
      t.status == DispatchStatus.pending &&
      t.assigneeName == widget.volunteerName;

  void _onTasks(List<DispatchTask> list) {
    // 顯示中的單若已不再是「待我接」（別人接走／轉全體／取消）→ 自動收掉橫幅。
    final shown = _shownTaskId;
    if (shown != null) {
      DispatchTask? cur;
      for (final t in list) {
        if (t.id == shown) {
          cur = t;
          break;
        }
      }
      if (cur == null || !_isForMe(cur)) _dismiss();
    }

    for (final t in list) {
      final k = _key(t);
      if (_seen.contains(k)) continue;
      _seen.add(k);
      // 首次載入（_seeded=false）只記錄不彈，避免開 App 就洗版舊單。
      if (_seeded && _isForMe(t) && _entry == null) _present(t);
    }
    _seeded = true;
  }

  Future<void> _onTap(Map<String, dynamic> data) async {
    if (data['kind'] != 'dispatch' || data['offer'] != '1') return;
    final taskId = (data['taskId'] ?? '').toString();
    if (taskId.isEmpty || _entry != null) return;
    DispatchTask? t;
    for (final x in backend.currentTasks) {
      if (x.id == taskId) {
        t = x;
        break;
      }
    }
    if (t == null || t.status != DispatchStatus.pending) return;
    _present(t);
  }

  Elder? _elderOf(String id) {
    for (final e in backend.currentElders) {
      if (e.id == id) return e;
    }
    return null;
  }

  (double, double) _myPos() {
    for (final v in backend.currentVolunteers) {
      if (v.name == widget.volunteerName) return (v.lat, v.lng);
    }
    return (0, 0);
  }

  /// 緊急單接單資格：良民證＋意外險有效（與 tasks_page 一致）。
  (bool, String?) _eligibility() {
    for (final v in backend.currentVolunteers) {
      if (v.name != widget.volunteerName) continue;
      bool valid(CertKind k) => v.certificates
          .any((c) => c.kind == k && c.status == CertStatus.valid);
      final ok = valid(CertKind.goodCitizen) && valid(CertKind.insurance);
      return ok ? (true, null) : (false, '接緊急派遣需先完成良民證與意外險（我的→證件）');
    }
    return (true, null);
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
    _shownTaskId = null;
  }

  Future<void> _present(DispatchTask t) async {
    final elder = _elderOf(t.elderId);
    if (elder == null || !mounted || _entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final (vlat, vlng) = _myPos();
    final km = roadDistanceKm(vlat, vlng, elder.lat, elder.lng);
    final eta = estimateEtaMinutes(vlat, vlng, elder.lat, elder.lng);
    final (canAccept, warning) = _eligibility();
    final messenger = ScaffoldMessenger.maybeOf(context);

    HapticFeedback.heavyImpact();
    _shownTaskId = t.id;

    _entry = OverlayEntry(
      builder: (_) => _DispatchHeadsUp(
        elderName: elder.name,
        etaText: '約 ${km.toStringAsFixed(1)} km・機車約 $eta 分鐘到',
        canAccept: canAccept,
        warning: warning,
        // 接單不能 fire-and-forget：await＋try/catch，成功才收橫幅並回饋、失敗留著可重試，
        // 否則接單靜默失敗、志工以為出發但 DB 沒變、3 分鐘後被改派、長輩空等。
        onAccept: () async {
          try {
            await backend.acceptTask(t.id,
                etaMinutes: eta, assigneeName: widget.volunteerName);
            _dismiss();
            messenger?.showSnackBar(
                SnackBar(content: Text('已接單，前往 ${elder.name}')));
          } on StateError {
            _dismiss(); // 已被搶接，收掉橫幅、換下一張
            messenger?.showSnackBar(
                const SnackBar(content: Text('這張單已被其他志工接走')));
          } catch (_) {
            messenger?.showSnackBar(
                const SnackBar(content: Text('接單失敗，請重試')));
          }
        },
        onDecline: () async {
          _dismiss();
          try {
            await backend.requestSupport(t.id);
          } catch (_) {
            messenger?.showSnackBar(
                const SnackBar(content: Text('操作失敗，請重試')));
          }
        },
        onDetails: () {
          _dismiss();
          _openDetails(t, elder, km, eta, canAccept, warning);
        },
      ),
    );
    overlay.insert(_entry!);
  }

  /// 點橫幅本體 → 展開完整詳情（地圖／地址／語音同意），資格與動作與橫幅一致。
  Future<void> _openDetails(DispatchTask t, Elder elder, double km, int eta,
      bool canAccept, String? warning) async {
    final nav = Navigator.of(context, rootNavigator: true);
    await nav.push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DispatchOfferScreen(
        backend: backend,
        title: '🚨 緊急派遣・請支援',
        elderName: elder.name,
        address: elder.address,
        etaText: '約 ${km.toStringAsFixed(1)} km・機車約 $eta 分鐘到',
        canAccept: canAccept,
        warning: warning,
        accent: JinsunColors.blue,
        onAccept: () => backend.acceptTask(t.id,
            etaMinutes: eta, assigneeName: widget.volunteerName),
        onDecline: () => backend.requestSupport(t.id),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 頂部推播橫幅：從畫面上方滑下，直接按「確認接單」／「拒絕」；點本體展開詳情。
class _DispatchHeadsUp extends StatefulWidget {
  const _DispatchHeadsUp({
    required this.elderName,
    required this.etaText,
    required this.canAccept,
    required this.warning,
    required this.onAccept,
    required this.onDecline,
    required this.onDetails,
  });

  final String elderName;
  final String etaText;
  final bool canAccept;
  final String? warning;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onDetails;

  @override
  State<_DispatchHeadsUp> createState() => _DispatchHeadsUpState();
}

class _DispatchHeadsUpState extends State<_DispatchHeadsUp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280))
    ..forward();
  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, -1.3), end: Offset.zero)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            borderRadius: BorderRadius.circular(18),
            shadowColor: const Color(0x33C62828),
            color: Colors.white,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onDetails,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFFFCDD2), width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                              color: Color(0xFFFDECEA), shape: BoxShape.circle),
                          child: const Text('🚨', style: TextStyle(fontSize: 19)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('緊急派遣・請支援',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFFC62828))),
                              const SizedBox(height: 2),
                              Text('${widget.elderName}・${widget.etaText}',
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: JinsunColors.muted),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 18, color: JinsunColors.muted),
                      ],
                    ),
                    if (widget.warning != null) ...[
                      const SizedBox(height: 8),
                      Text(widget.warning!,
                          style: const TextStyle(
                              fontSize: 12, color: JinsunColors.warnText)),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: widget.onDecline,
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(46),
                                foregroundColor: JinsunColors.muted),
                            child: const Text('拒絕'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            onPressed: widget.canAccept ? widget.onAccept : null,
                            style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(46),
                                backgroundColor: JinsunColors.okText),
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('確認接單'),
                          ),
                        ),
                      ],
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
