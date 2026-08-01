import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';
import 'package:latlong2/latlong.dart';

import '../app_local.dart';
import 'history_page.dart';
import 'notifications_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.local});

  final AppLocal local;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 5) return '夜深了';
    if (h < 11) return '早安';
    if (h < 14) return '午安';
    if (h < 18) return '午後好';
    return '晚安';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: local,
      builder: (context, _) {
        final elders = local.boundElders;
        if (elders.isEmpty) return const SizedBox.shrink();
        final multi = elders.length > 1;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              children: [
                const JinsunLogo(size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('$_greeting，${local.userName}',
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: JinsunColors.ink)),
                ),
                // 即時紀錄收件匣：錯過首頁短暫卡片後仍能回看剛剛發生什麼；紅點＝未讀。
                IconButton(
                  tooltip: '即時紀錄',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => NotificationsPage(local: local)),
                  ),
                  icon: Badge(
                    isLabelVisible: local.unreadNotifications > 0,
                    label: Text('${local.unreadNotifications}'),
                    child: const Icon(Icons.notifications_none),
                  ),
                ),
              ],
            ),
            if (multi)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('你關心的長輩',
                    style: TextStyle(fontSize: 13, color: JinsunColors.muted)),
              ),
            const SizedBox(height: 16),
            // 每一位綁定長輩各一區：緊急橫幅→狀態卡→進行中事件→AI 確認中→聯絡。
            // 誰出事誰跳紅；完成的事件自動移到歷史，首頁不累積。
            for (final e in elders) ...[
              _ElderCard(local: local, elder: e),
              const SizedBox(height: 14),
              // 進行中事件＝一張整合卡（狀態＋地圖＋聯絡）；無事件時才顯示獨立聯絡卡。
              _DispatchCard(local: local, elder: e),
              _AiConfirmCard(local: local, elder: e),
              _ContactCard(local: local, elder: e),
              const SizedBox(height: 20),
            ],
            _AdviceCard(local: local),
            const SizedBox(height: 14),
            _HistoryEntry(local: local),
          ],
        );
      },
    );
  }
}

/// 長輩狀態卡
class _ElderCard extends StatelessWidget {
  const _ElderCard({required this.local, required this.elder});

  final AppLocal local;
  final Elder elder;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 28,
              backgroundColor: JinsunColors.orangeBg,
              child:
                  Icon(Icons.elderly, size: 30, color: JinsunColors.orangeDeep),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(elder.name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(elder.address,
                      style: const TextStyle(
                          fontSize: 12.5, color: JinsunColors.muted)),
                  if (elder.note != null && elder.note!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('📋 ${elder.note}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: JinsunColors.orangeDeep,
                            height: 1.4)),
                  ],
                ],
              ),
            ),
            StatusPill(
              label: elder.severity == Severity.normal
                  ? '今天一切安好'
                  : severityLabel(elder.severity),
              fg: severityTextColor(elder.severity),
              bg: severityBgColor(elder.severity),
            ),
          ],
        ),
      ),
    );
  }
}

/// 進行中事件區：每一件進行中的事件 = 一張 Card（家屬視角標題＋狀態時間軸＋地圖）。
/// 結案後事件自動移到「生活歷史紀錄」，首頁不再累積舊事件。
class _DispatchCard extends StatelessWidget {
  const _DispatchCard({required this.local, required this.elder});

  final AppLocal local;
  final Elder elder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DispatchTask>>(
      stream: local.backend.tasks,
      initialData: local.backend.currentTasks,
      builder: (context, snapshot) {
        final active = (snapshot.data ?? const <DispatchTask>[])
            .where((t) =>
                t.elderId == elder.id && t.status != DispatchStatus.resolved)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (active.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final t in active)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _eventCard(context, elder, t),
              ),
          ],
        );
      },
    );
  }

  /// 家屬關單：確認長輩平安 → 結束事件（resolveTask 會關事件、把長輩狀態轉回正常、
  /// 移到歷史）。加確認對話框，避免誤觸把還需要協助的事件關掉。
  Future<void> _confirmSafe(
      BuildContext context, Elder elder, DispatchTask t) async {
    // 物資單＝送達完成，用「已完成」；跌倒／SOS 才是「確認平安」。
    final isSupply = t.kind == DispatchKind.supply;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSupply ? '確認已完成？' : '確認 ${elder.name} 平安？'),
        content: Text(isSupply
            ? '確認物資已送達、這件事情完成？完成後會移到歷史紀錄。'
            : '確認後這件事件會結束並移到歷史紀錄。\n若長輩仍需要協助，請先不要關閉。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: JinsunColors.okText),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isSupply ? '已完成' : '確認平安')),
        ],
      ),
    );
    if (ok != true) return;
    await local.backend.resolveTask(t.id,
        note: isSupply ? '家屬確認物資已完成' : '家屬確認長輩平安');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isSupply
              ? '物資已完成，事件結束'
              : '已確認 ${elder.name} 平安，事件結束')));
    }
  }

  /// 家屬視角標題：一句話說完發生什麼、現在怎樣。
  String _headline(Elder elder, DispatchTask t) {
    if (t.kind == DispatchKind.supply) return '${elder.name} 需要生活物資';
    return switch (t.status) {
      DispatchStatus.arrived => '志工已抵達 ${elder.name} 家中',
      DispatchStatus.accepted => '${elder.name} 需要協助，志工前往中',
      _ => t.assigneeName != null
          ? '${elder.name} 需要協助，志工前往中'
          : '偵測到 ${elder.name} 異常，AI 確認中…',
    };
  }

  /// 目前狀態時間軸（家屬視角，不放後台術語）。
  List<String> _steps(DispatchTask t) {
    if (t.kind == DispatchKind.supply) {
      return [
        '收到物資需求：${t.items.join('、')}',
        if (t.assigneeName != null)
          '志工 ${t.assigneeName} 已接單，正在處理',
      ];
    }
    return [
      '收音設備偵測到異常聲音，AI 已主動確認',
      if (t.assigneeName != null) '志工 ${t.assigneeName} 已接案，前往中',
      if (t.assigneeName != null && t.etaMinutes != null)
        '預估 ${t.etaMinutes} 分鐘到達',
      if (t.status == DispatchStatus.arrived) '志工已抵達，正在確認狀況',
    ];
  }

  Widget _eventCard(BuildContext context, Elder elder, DispatchTask t) {
    final emergency = t.kind == DispatchKind.emergency;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
            color: emergency
                ? const Color(0xFFEBB4A6)
                : const Color(0xFFE7CE93)),
      ),
      color: emergency ? const Color(0xFFFFF3EF) : const Color(0xFFFFF8E8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(emergency ? Icons.notifications_active : Icons.shopping_cart,
                    color: emergency
                        ? JinsunColors.dangerText
                        : JinsunColors.orangeDeep),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_headline(elder, t),
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: emergency
                              ? JinsunColors.dangerText
                              : JinsunColors.orangeDeep)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('目前狀態',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: JinsunColors.muted)),
            const SizedBox(height: 6),
            ..._steps(t).map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Icon(Icons.check_circle,
                            size: 14, color: JinsunColors.okText),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(s,
                              style: const TextStyle(
                                  fontSize: 14, height: 1.35))),
                    ],
                  ),
                )),
            // 志工前往中／已到場才顯示即時路線與 ETA 地圖。
            // 只是「已指派、還沒接單」（pending＋定向緊急單）不畫地圖，否則會出現
            // 志工還沒接單就在路上移動的假象。
            if (t.status == DispatchStatus.accepted ||
                t.status == DispatchStatus.arrived) ...[
              const SizedBox(height: 10),
              _DispatchRouteMap(local: local, task: t),
            ],
            // 志工到場回報的現場備註
            if (t.note != null && t.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFB8D4BE)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.volunteer_activism,
                            size: 15, color: JinsunColors.okText),
                        const SizedBox(width: 6),
                        Text('志工${t.assigneeName ?? ''}回報',
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: JinsunColors.okText)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('「${t.note}」',
                        style: const TextStyle(fontSize: 14, height: 1.5)),
                  ],
                ),
              ),
            ],
            // 物資單寬限期：3 分鐘內可自行處理，或立即請求志工支援
            if (t.kind == DispatchKind.supply && t.inOfferWindow) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => local.backend.cancelSupplyTask(t.id),
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('我來處理'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => local.backend.requestSupport(t.id),
                      icon: const Icon(Icons.campaign, size: 18),
                      label: const Text('請求支援'),
                    ),
                  ),
                ],
              ),
            ],
            // 家屬也能關單：確認長輩平安 → 結束事件、移到歷史（例如家屬已親自聯絡確認）。
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: JinsunColors.okText,
                  side: BorderSide(
                      color: JinsunColors.okText.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.verified, size: 18),
                label: Text(t.kind == DispatchKind.supply
                    ? '已完成'
                    : '已確認 ${elder.name} 平安'),
                onPressed: () => _confirmSafe(context, elder, t),
              ),
            ),
            // 聯絡併進事件卡：緊急橫幅＋事件卡＋聯絡三合一，撥打長輩不再重複出現。
            const SizedBox(height: 14),
            const Divider(height: 1, color: JinsunColors.line),
            const SizedBox(height: 12),
            _contactHeader(),
            const SizedBox(height: 12),
            // 有指派志工才顯示「聯絡志工」（與長輩並排）
            _ContactButtons(
                local: local, elder: elder, showWorker: t.assigneeName != null),
          ],
        ),
      ),
    );
  }
}

/// 志工→長輩 路線與 ETA 地圖（派遣進行中顯示）。
/// 志工位置取自 backend.currentVolunteers（依接單志工姓名比對，志工 App 即時回報）；
/// 路線走 OSRM 取真實道路幾何，取不到時退化為直線。志工移動會即時更新。
class _DispatchRouteMap extends StatefulWidget {
  const _DispatchRouteMap({required this.local, required this.task});

  final AppLocal local;
  final DispatchTask task;

  @override
  State<_DispatchRouteMap> createState() => _DispatchRouteMapState();
}

class _DispatchRouteMapState extends State<_DispatchRouteMap> {
  final MapController _mapController = MapController();
  List<LatLng>? _route; // OSRM 道路幾何（null＝還沒取到，用直線）
  LatLng? _routeFrom, _routeTo; // 上次取路線的端點（移動夠遠才重取）
  StreamSubscription<List<Volunteer>>? _volSub;
  LatLng? _volLatLng; // 志工即時座標（volunteers stream 驅動；志工移動就更新）
  bool _mapReady = false;
  bool _fitDone = false; // 鏡頭只框一次整段行程（避免志工靠近長輩家時越縮越放大）

  // 派遣定位模式（app_settings.dispatch_tracking，志工在 ?sim=1 切換）：
  //   simulate＝模擬出發（志工自動沿路移動、ETA 倒數，demo 用）
  //   real    ＝只用志工 App 回報的真實 GPS；沒有就顯示「定位中」，不畫假位置
  String _mode = 'simulate';
  Timer? _simTimer;
  double _simProgress = 0; // 0..1（simulate 用）
  LatLng? _simStart;

  @override
  void initState() {
    super.initState();
    _volLatLng = _lookupVol();
    _volSub = widget.local.backend.volunteers.listen((_) {
      final p = _lookupVol();
      if (mounted) setState(() => _volLatLng = p);
    });
    _loadMode();
  }

  Future<void> _loadMode() async {
    var m = 'simulate';
    try {
      final row = await JinsunSupabase.client
          .from('app_settings')
          .select('value')
          .eq('key', 'dispatch_tracking')
          .maybeSingle();
      m = (row?['value'] as String?) ?? 'simulate';
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _mode = m;
      _volLatLng = _lookupVol();
    });
    if (m == 'simulate') _startSim();
  }

  // 模擬移動只推進到「門口前」就停住（≤_simCap），**不主動判定到達**。
  // 真正的「到達」由志工端按「我到了」或社工後台按「標記到達」決定——長輩端收音機
  // 也只在那一刻才會播「志工到了」。如此可保證：畫面上的移動路線與實際到達時間同步，
  // 收音機不會在志工還沒真的到之前就報「已到達」（提早），也不會延後。
  static const _simCap = 0.9;

  /// 模擬出發：每 2 秒沿路推進約 5%，停在門口前等真正到場；ETA 同步倒數。
  /// 只有志工「已接單、前往中」才模擬移動；還沒接單（pending）不該有人在路上。
  void _startSim() {
    if (_simTimer != null) return;
    if (widget.task.status != DispatchStatus.accepted) return;
    _simTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted) return t.cancel();
      final next = (_simProgress + 0.05).clamp(0.0, _simCap);
      setState(() => _simProgress = next);
      if (next >= _simCap) t.cancel(); // 到門口就停，不自動 markArrived
    });
  }

  @override
  void didUpdateWidget(covariant _DispatchRouteMap old) {
    super.didUpdateWidget(old);
    // 任務真的「到場」（志工端／後台標記到達）→ 停模擬、把車程補到門口內（1.0）。
    // 用 _simProgress<1 判斷而非 _simTimer!=null：計時器可能已停在門口（_simCap），
    // 這時仍要在到達當下把橘點補進家門，與收音機「志工到了」同一刻發生。
    if (widget.task.status == DispatchStatus.arrived && _simProgress < 1.0) {
      _simTimer?.cancel();
      _simTimer = null;
      if (mounted) setState(() => _simProgress = 1.0);
    }
    // 從 pending 轉 accepted（剛接單）→ 這時才開始模擬移動。
    if (old.task.status != DispatchStatus.accepted &&
        widget.task.status == DispatchStatus.accepted &&
        _mode == 'simulate') {
      _startSim();
    }
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    _volSub?.cancel();
    super.dispose();
  }

  /// 接單志工座標。real 模式只回「近期真實 GPS」（seed／過期回 null）；
  /// 其它模式回原始座標（含 seed）。查無回 null。
  LatLng? _lookupVol() {
    final now = DateTime.now();
    for (final v in widget.local.backend.currentVolunteers) {
      if (v.name != widget.task.assigneeName) continue;
      if (_mode == 'real') {
        return v.hasLiveLocation(now) ? LatLng(v.lat, v.lng) : null;
      }
      return (v.lat != 0 || v.lng != 0) ? LatLng(v.lat, v.lng) : null;
    }
    return null;
  }

  /// real 模式沒有 live GPS 時顯示（不畫假位置）。
  Widget _locatingCard() {
    return Container(
      height: 118,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0FA),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.my_location, color: JinsunColors.muted),
            SizedBox(height: 8),
            Text('志工定位中…',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            SizedBox(height: 2),
            Text('志工開始移動後，這裡會顯示即時位置與預計到達時間',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: JinsunColors.muted)),
          ],
        ),
      ),
    );
  }

  double _dist(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b);

  Future<void> _maybeFetchRoute(LatLng from, LatLng to) async {
    // 端點沒明顯移動就不重取（避免志工每動一下就打一次 OSRM）
    if (_routeFrom != null &&
        _routeTo != null &&
        _dist(_routeFrom!, from) < 40 &&
        _dist(_routeTo!, to) < 40) {
      return;
    }
    _routeFrom = from;
    _routeTo = to;
    try {
      final url = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
          '?overview=full&geometries=geojson');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return;
      final coords = (jsonDecode(res.body)['routes'] as List).first['geometry']
          ['coordinates'] as List;
      final pts = coords
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      if (mounted) {
        setState(() {
          _route = pts;
          _fitDone = false; // 拿到道路幾何後，重新框一次整條路線（僅此一次）
        });
      }
    } catch (_) {
      // OSRM 取不到 → 保持 null，用直線
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    // 用「這張派遣單的長輩」而非 primaryElder（家屬可能綁多位長輩）。
    final elder = widget.local.backend.currentElders.firstWhere(
        (e) => e.id == task.elderId,
        orElse: () => widget.local.primaryElder!);
    final elderPos = LatLng(elder.lat, elder.lng);
    final arrived = task.status == DispatchStatus.arrived;

    // 依模式決定志工位置與 ETA。
    final LatLng volPos;
    final int displayEta;
    if (_mode == 'real') {
      // 只用真實 GPS；沒有 live 座標就顯示「定位中」，不畫假位置。
      if (_volLatLng == null) return _locatingCard();
      volPos = _volLatLng!;
      displayEta = task.etaMinutes ??
          estimateEtaMinutes(volPos.latitude, volPos.longitude,
              elderPos.latitude, elderPos.longitude);
      if (!arrived) _maybeFetchRoute(volPos, elderPos);
    } else {
      // simulate：從合成起點沿路往長輩家移動、ETA 倒數。
      final baseEta0 = task.etaMinutes ?? 8;
      _simStart ??= LatLng(elder.lat + 0.010 * (baseEta0 / 8),
          elder.lng + 0.016 * (baseEta0 / 8));
      final start = _simStart!;
      if (!arrived) _maybeFetchRoute(start, elderPos);
      if (_route != null && _route!.length > 1) {
        final idx = (_simProgress * (_route!.length - 1))
            .floor()
            .clamp(0, _route!.length - 1);
        volPos = _route![idx];
      } else {
        volPos = LatLng(
          start.latitude + (elderPos.latitude - start.latitude) * _simProgress,
          start.longitude +
              (elderPos.longitude - start.longitude) * _simProgress,
        );
      }
      final baseEta = task.etaMinutes ??
          estimateEtaMinutes(start.latitude, start.longitude,
              elderPos.latitude, elderPos.longitude);
      // 還沒真的到場前 ETA 至少顯示 1 分鐘，避免橘點還在門口卻先跳「0 分鐘」。
      displayEta = arrived
          ? 0
          : (baseEta * (1 - _simProgress)).round().clamp(1, baseEta < 1 ? 1 : baseEta);
    }
    final line = _route ?? [volPos, elderPos];
    final mid = LatLng(
      (elderPos.latitude + volPos.latitude) / 2,
      (elderPos.longitude + volPos.longitude) / 2,
    );

    // 鏡頭只框「整段行程」一次（起點/路線 ＋ 長輩家），之後讓橘點在畫面裡移動即可。
    // 不再每幀跟著志工重框——否則志工越靠近長輩家、兩點越近，畫面就會一直放大。
    if (_mapReady && !_fitDone) {
      final frame = _route ?? [_simStart ?? volPos, elderPos];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _mapController.fitCamera(CameraFit.coordinates(
            coordinates: frame,
            padding: const EdgeInsets.all(34),
            maxZoom: 16,
          ));
        } catch (_) {}
      });
      _fitDone = true;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 170,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: mid,
                onMapReady: () {
                  if (mounted) setState(() => _mapReady = true);
                },
                initialZoom: 14,
                interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none), // 卡片內：唯讀不干擾捲動
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'tw.jinsunradio.family',
                ),
                if (!arrived)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: line,
                        strokeWidth: 4,
                        color: JinsunColors.orange,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    // 長輩（家）
                    Marker(
                      point: elderPos,
                      width: 90,
                      height: 64,
                      alignment: Alignment.topCenter,
                      child: const _MapPin(
                          icon: Icons.home_rounded,
                          label: '長輩家',
                          color: JinsunColors.okText),
                    ),
                    // 志工＝橘色圓點（模擬中的即時位置）
                    Marker(
                      point: volPos,
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      child: const _VolunteerDot(),
                    ),
                  ],
                ),
              ],
            ),
            // ETA 徽章
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4)
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(arrived ? Icons.check_circle : Icons.navigation,
                        size: 15,
                        color: arrived
                            ? JinsunColors.okText
                            : JinsunColors.orange),
                    const SizedBox(width: 6),
                    Text(
                      arrived
                          ? '志工已到場'
                          : (displayEta <= 0
                              ? '即將到達'
                              : '預計 $displayEta 分鐘到達'),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            const Positioned(
              right: 6,
              bottom: 2,
              child: Text('© OpenStreetMap',
                  style: TextStyle(fontSize: 9, color: Colors.black45)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地圖標記：圖示 + 標籤
class _MapPin extends StatelessWidget {
  const _MapPin(
      {required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 30, color: color),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.bold, color: color)),
        ),
      ],
    );
  }
}

/// 志工位置＝橘色圓點（白框＋淡陰影），比人形圖示更輕、不遮住路線。
class _VolunteerDot extends StatelessWidget {
  const _VolunteerDot();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: JinsunColors.orange,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 4),
          ],
        ),
      ),
    );
  }
}

/// 聯絡兩顆鈕：長輩、志工。點任一個直接進聊天頁（底部玻璃擬態語音／電話）。
/// 進行中事件卡內、以及無事件時的獨立聯絡卡，都共用這組鈕，避免重複入口。
class _ContactButtons extends StatelessWidget {
  const _ContactButtons(
      {required this.local, required this.elder, this.showWorker = true});

  final AppLocal local;
  final Elder elder;
  // 只有「有志工正在服務」時才顯示聯絡志工；沒有進行中派遣就不顯示（不是常態入口）。
  final bool showWorker;

  Future<void> _dial(BuildContext context, String? number) async {
    if (number == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('長輩未留電話')));
      return;
    }
    final uri =
        Uri(scheme: 'tel', path: number.replaceAll(RegExp(r'[^0-9+]'), ''));
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('此裝置無法撥號')));
    }
  }

  /// 有進行中派遣單就用它的 id（可與該次服務的志工對話）；否則用穩定聯絡頻道 id。
  String _workerTaskId(Elder elder) {
    for (final t in local.backend.currentTasks) {
      if (t.elderId == elder.id && t.status != DispatchStatus.resolved) {
        return t.id;
      }
    }
    return 'family-worker-${elder.id}';
  }

  void _openElderChat(BuildContext context, Elder elder) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        backend: local.backend,
        taskId: 'family-elder-${elder.id}',
        myRole: ChatFromRole.family,
        title: '與 ${elder.name}',
        accent: JinsunColors.orange,
        peerName: elder.name,
        // 長輩端無螢幕、不走 Jitsi；「通話」＝直撥長輩家中電話。
        onCall: () => _dial(context, elder.phone),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 長輩鈕：無左側 icon（依需求），透過收音機語音或直撥家中電話
    final elderBtn = FilledButton(
      style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: JinsunColors.orange),
      onPressed: () => _openElderChat(context, elder),
      child: Text('聯絡 ${elder.name}'),
    );
    // 志工鈕：遮罩安全轉接（App 內語音／電話）——只有派遣中才顯示
    final workerBtn = ContactButton(
      label: '聯絡志工',
      backend: local.backend,
      taskId: _workerTaskId(elder),
      accent: JinsunColors.orange,
      callSelfRole: CallRole.family,
      callSelfName: '家屬',
      callPeerName: '志工',
      callPeerLabel: '負責的志工',
      chatMyRole: ChatFromRole.family,
      chatTitle: '與志工的訊息',
    );
    if (!showWorker) {
      return SizedBox(width: double.infinity, child: elderBtn);
    }
    // 兩顆並排（flex，各佔一半）
    return Row(
      children: [
        Expanded(child: elderBtn),
        const SizedBox(width: 10),
        Expanded(child: workerBtn),
      ],
    );
  }
}

/// 小標題「聯絡」＋說明（事件卡內與獨立聯絡卡共用）。
Widget _contactHeader() => Row(
      children: const [
        Icon(Icons.headset_mic, size: 18, color: JinsunColors.orangeDeep),
        SizedBox(width: 8),
        Text('聯絡',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        SizedBox(width: 8),
        Expanded(
          child: Text('點一下直接進聊天，可語音或電話',
              style: TextStyle(fontSize: 12, color: JinsunColors.muted)),
        ),
      ],
    );

/// 獨立聯絡卡：只在「沒有進行中事件」時出現——有事件時聯絡鈕已併進事件卡，
/// 避免緊急橫幅／事件卡／聯絡卡三塊各自出現、且「撥打長輩」重複。
class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.local, required this.elder});

  final AppLocal local;
  final Elder elder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DispatchTask>>(
      stream: local.backend.tasks,
      initialData: local.backend.currentTasks,
      builder: (context, snap) {
        final hasActive = (snap.data ?? const <DispatchTask>[]).any((t) =>
            t.elderId == elder.id && t.status != DispatchStatus.resolved);
        if (hasActive) return const SizedBox.shrink(); // 併進事件卡了
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _contactHeader(),
                const SizedBox(height: 12),
                // 沒有進行中派遣＝沒有志工可聯絡，只顯示聯絡長輩
                _ContactButtons(
                    local: local, elder: elder, showWorker: false),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// AI 確認中卡：事件已偵測、尚未升級派人的黃金 20 秒視窗，讓家屬在最焦慮的那一刻
/// 也看得到「系統正在處理」。由 open 狀態的 RadioEvent 推導；一旦派單就交給事件卡。
class _AiConfirmCard extends StatelessWidget {
  const _AiConfirmCard({required this.local, required this.elder});

  final AppLocal local;
  final Elder elder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RadioEvent>>(
      stream: local.backend.events,
      initialData: local.backend.currentEvents,
      builder: (context, snap) {
        final events = snap.data ?? const <RadioEvent>[];
        final confirming = events.any((e) =>
            e.elderId == elder.id && e.status == RadioEventStatus.open);
        if (!confirming) return const SizedBox.shrink();
        // 已建立進行中派遣單 → 交給事件卡顯示，不重複。
        final hasTask = local.backend.currentTasks.any((t) =>
            t.elderId == elder.id && t.status != DispatchStatus.resolved);
        if (hasTask) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE7CE93)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 3, color: Color(0xFF8A5A00)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('偵測到 ${elder.name} 異常聲音，AI 正在確認…',
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF8A5A00))),
                      const SizedBox(height: 2),
                      const Text('AI 正在語音關心長輩；20 秒沒有回應，就會立即通知志工前往',
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: JinsunColors.muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 生活歷史紀錄入口（收音事件時間軸，以週分組）。
class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({required this.local});

  final AppLocal local;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.history, color: JinsunColors.orangeDeep),
        title: const Text('生活歷史紀錄',
            style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text('收音設備守護紀錄，以週回顧',
            style: TextStyle(color: JinsunColors.muted)),
        trailing: const Icon(Icons.chevron_right, color: JinsunColors.muted),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => HistoryPage(local: local))),
      ),
    );
  }
}

/// AI 照護建議卡
class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.local});

  final AppLocal local;

  @override
  Widget build(BuildContext context) {
    final a = local.advice;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('AI 照護建議',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: Text(a == null ? 'AI 分析' : '重新分析'),
                  onPressed: local.generateAdvice,
                ),
              ],
            ),
            if (a != null) ...[
              const SizedBox(height: 12),
              Text(a.summary,
                  style: const TextStyle(fontSize: 14.5, height: 1.6)),
              const SizedBox(height: 10),
              ...a.insights.map((t) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Icon(Icons.circle,
                              size: 6, color: JinsunColors.muted),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(t,
                                style: const TextStyle(
                                    fontSize: 13.5, height: 1.5))),
                      ],
                    ),
                  )),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: JinsunColors.orangeBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.medical_services_outlined,
                            size: 18, color: JinsunColors.orangeDeep),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(a.suggestion,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: JinsunColors.orangeDeep)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(a.suggestionReason,
                        style: const TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: Color(0xFF6B4310))),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                  '依收音機偵測到的真實事件（疑似跌倒／求助／物資）與長輩狀態彙整，僅供參考，不能取代醫療診斷。',
                  style:
                      TextStyle(fontSize: 11.5, color: JinsunColors.muted)),
            ],
          ],
        ),
      ),
    );
  }
}
