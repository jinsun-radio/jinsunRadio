import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:latlong2/latlong.dart';

import 'export.dart';
import 'hardware_sim.dart';
import 'logo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JinsunSupabase.ensureInitialized();
  runApp(const AdminApp());
}

// ===== 橘色主題調色盤（WCAG 1.4.3：文字色一律白底 ≥4.5:1；fill 為圖示/圓環用，≥3:1）=====
const _orange = Color(0xFFF5761A); // 亮橘：大圖示、active、淺色高光（非白字底）
const _orangeDeep = Color(0xFFB2560F); // 白底上的橘色「文字／連結」（≥4.5:1）
const _orangeBtn = Color(0xFFB85708); // 實心按鈕填色＋白字（≈4.8:1，過 AA）
const _orangeBtnDeep = Color(0xFF9C4A06); // 按鈕微微漸層的下緣（更深）
const _orangeBg = Color(0xFFFFEEDD); // 淺橘底
const _bg = Color(0xFFF6F1EA); // 溫暖淺底（畫布）
const _ink = Color(0xFF24190F); // 主要文字（暖黑，白底 ~15:1）
const _line = Color(0xFFEDE6DC); // 分隔線／卡片邊

/// 後台內文用的中性灰（4.9:1，取代對比不足的 Colors.grey #9E9E9E＝2.8:1）。
const _muted = Color(0xFF6C6C72);

// 三態緊急度＝紅黃綠。文字色（白底 ≥4.5:1）用於數字/標籤；fill 較鮮豔用於圓環/圖示（graphical ≥3:1）。
Color severityColor(Severity s) => switch (s) {
      Severity.normal => const Color(0xFF2E7D32), // 綠 5.2:1
      Severity.attention => const Color(0xFF8A5A00), // 黃/琥珀 4.5:1
      Severity.emergency => const Color(0xFFC62828), // 紅 5.5:1
    };

/// 圓環／圖示用的鮮豔紅黃綠 fill（非文字，WCAG 圖形物件 ≥3:1）。
Color severityFill(Severity s) => switch (s) {
      Severity.normal => const Color(0xFF34A853), // 綠
      Severity.attention => const Color(0xFFF5A623), // 黃（琥珀）
      Severity.emergency => const Color(0xFFE5484D), // 紅
    };

/// 淺色底（卡片背景/藥丸），配 severityColor 文字。
Color severityBg(Severity s) => switch (s) {
      Severity.normal => const Color(0xFFE7F6EC),
      Severity.attention => const Color(0xFFFDF1DA),
      Severity.emergency => const Color(0xFFFCE7E7),
    };

/// 緊急度中文標籤（地圖／列表用）。
String severityText(Severity s) => switch (s) {
      Severity.normal => '正常',
      Severity.attention => '注意',
      Severity.emergency => '緊急',
    };

// ===== 基本資安：個資預設打碼，社工需要時一鍵顯示（防肩窺／降低外洩面）=====
// 全域開關；false＝打碼（預設）。頂列眼睛切換，整個 dashboard 隨之重繪。
final _revealPii = ValueNotifier<bool>(false);

/// 姓名打碼：中間字以 ○ 遮（林阿春→林○春；何進→何○；歐陽小明→歐○○明）。
String maskName(String name) {
  final n = name.trim();
  if (_revealPii.value || n.characters.length <= 1) return n;
  final cs = n.characters.toList();
  if (cs.length == 2) return '${cs[0]}○';
  return cs.first + '○' * (cs.length - 2) + cs.last;
}

/// 電話打碼：保留最前與最後一段，中間各段以 * 遮（0933-333-444→0933-***-444；
/// 02-2345-6789→02-****-6789）。無分隔則保留末 3 碼。
String maskPhone(String? phone) {
  final p = (phone ?? '').trim();
  if (p.isEmpty) return '—';
  if (_revealPii.value) return p;
  final parts = p.split(RegExp(r'[-\s]+'));
  if (parts.length >= 3) {
    for (var i = 1; i < parts.length - 1; i++) {
      parts[i] = '*' * parts[i].length;
    }
    return parts.join('-');
  }
  final digits = p.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 3) return '****';
  var shown = 0;
  final rev = p.split('').reversed.map((ch) {
    if (RegExp(r'\d').hasMatch(ch)) {
      shown++;
      return shown <= 3 ? ch : '*';
    }
    return ch;
  }).toList();
  return rev.reversed.join();
}

/// 地址打碼：保留到路名/段，遮門牌號（松仁路123號→松仁路◯號）。
String maskAddress(String addr) {
  final a = addr.trim();
  if (_revealPii.value || a.isEmpty) return a;
  final m = a.replaceFirst(RegExp(r'\d+\s*號.*$'), '◯號');
  return m == a ? a.replaceFirst(RegExp(r'\d+.*$'), '◯◯') : m;
}

/// 醫療/狀況注記：屬健康敏感資料，打碼時整段隱藏成提示。
String maskNote(String? note) {
  final t = (note ?? '').trim();
  if (t.isEmpty) return '';
  return _revealPii.value ? t : '🔒 注記已隱藏';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 事件紀錄時間：年月日 + 時分秒（本地時區）。
String _fmtDateTime(DateTime t) =>
    '${t.year}/${_two(t.month)}/${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

final _adminTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'NotoSansTC',
  colorScheme: ColorScheme.fromSeed(
    seedColor: _orange,
    primary: _orange,
    brightness: Brightness.light,
    surface: Colors.white,
  ),
  scaffoldBackgroundColor: _bg,
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    shadowColor: const Color(0x14A05A16),
    surfaceTintColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    margin: EdgeInsets.zero,
  ),
  filledButtonTheme: FilledButtonThemeData(
    // 白字實心按鈕改用 [_orangeBtn]（≥4.8:1）；亮橘 [_orange] 留給圖示／高光。
    style: FilledButton.styleFrom(
      backgroundColor: _orangeBtn,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: _orangeDeep),
  ),
  dividerTheme: const DividerThemeData(color: _line, thickness: 1, space: 1),
  dataTableTheme: DataTableThemeData(
    headingTextStyle: const TextStyle(
        fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
    dataTextStyle: const TextStyle(fontSize: 13.5, color: _ink),
    headingRowColor: WidgetStatePropertyAll(_orangeBg.withValues(alpha: 0.5)),
    dividerThickness: 1,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: _ink),
    titleMedium: TextStyle(color: _ink, fontWeight: FontWeight.w700),
  ),
);

/// 後台主要 CTA：品牌橘微微漸層＋柔和陰影＋白字（過 WCAG AA），與家屬／志工端一致。
class _GradientCta extends StatelessWidget {
  const _GradientCta(
      {required this.onPressed, required this.label, this.icon});

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: disabled
                ? const [Color(0xFFCFCFD6), Color(0xFFC4C4CB)]
                : const [_orangeBtn, _orangeBtnDeep],
          ),
          borderRadius: BorderRadius.circular(999),
          boxShadow: disabled
              ? null
              : [
                  BoxShadow(
                    color: _orangeBtnDeep.withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 7),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              constraints: const BoxConstraints(minHeight: 50),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 19, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AdminApp extends StatefulWidget {
  const AdminApp({super.key, this.backend, this.auth});

  // 可注入後端／認證（測試用 MockBackend）；正式版預設 Supabase。
  final BackendClient? backend;
  final AuthRepository? auth;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final BackendClient backend;
  late final AuthRepository auth;

  @override
  void initState() {
    super.initState();
    // 後台＝派遣中心：開啟卡單自動改派看門狗（單一權威端執行）。
    backend = widget.backend ?? SupabaseBackend(dispatchWatchdog: true);
    auth = widget.auth ?? SupabaseAuthRepository(role: AuthRole.worker);
    auth.restore().then((_) async {
      final demo = Uri.base.queryParameters['demo'];
      if (demo != null && auth.currentUser == null) {
        await auth.signIn(username: '0933-222-333', password: 'demo1234');
      }
      if (demo == 'fall') {
        Timer(const Duration(seconds: 2),
            () => backend.triggerFallSuspected('elder-1'));
      } else if (demo == 'sos') {
        Timer(const Duration(seconds: 2), () => backend.triggerSos('elder-2'));
      }
    });
  }

  @override
  void dispose() {
    backend.dispose();
    auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '金孫收音機・社工後台',
      debugShowCheckedModeBanner: false,
      theme: _adminTheme,
      home: StreamBuilder<AuthUser?>(
        stream: auth.authStateChanges(),
        initialData: auth.currentUser,
        builder: (context, snap) {
          if (snap.data == null) return _AdminLogin(auth: auth);
          return AdminHomePage(backend: backend, auth: auth);
        },
      ),
    );
  }
}

class AdminHomePage extends StatefulWidget {
  const AdminHomePage({super.key, required this.backend, required this.auth});

  final BackendClient backend;
  final AuthRepository auth;

  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  BackendClient get backend => widget.backend;

  // 硬體模擬不對外，只有帶 ?sim=1 的網址（開發／管理者用）才會出現。
  bool get _simMode => Uri.base.queryParameters['sim'] == '1';

  final _scroll = ScrollController();
  // 側欄圖示點擊 → 捲動到對應區塊
  final _kDispatch = GlobalKey();
  final _kEvents = GlobalKey();
  final _kMap = GlobalKey();
  final _kWorkers = GlobalKey();
  int _navIdx = 0;

  // 只看「我負責的長輩」：登入社工只看 supervisor_worker_name == 自己 的長輩。
  bool _onlyMine = false;
  String get _myWorker => widget.auth.currentUser?.name ?? '';
  bool _visible(Elder e) => !_onlyMine || e.supervisorWorkerName == _myWorker;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollTo(GlobalKey key, int idx) {
    setState(() => _navIdx = idx);
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          alignment: 0.02);
    }
  }

  Future<void> _exportExcel() async {
    // 政府申報硬需求：不能靜默壞。先選匯出期間（政府月報以「月」為單位），
    // 依期間篩事件／派遣單再匯出；檔名帶期間避免互相覆蓋。
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('選擇匯出期間'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'this'),
              child: Text('本月（${now.year}/${_two(now.month)}）')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'last'),
              child: const Text('上個月')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'all'),
              child: const Text('全部')),
        ],
      ),
    );
    if (choice == null) return;

    DateTime? from, to;
    String stamp;
    if (choice == 'this') {
      from = DateTime(now.year, now.month, 1);
      to = DateTime(now.year, now.month + 1, 1);
      stamp = '${from.year}${_two(from.month)}';
    } else if (choice == 'last') {
      from = DateTime(now.year, now.month - 1, 1);
      to = DateTime(now.year, now.month, 1);
      stamp = '${from.year}${_two(from.month)}';
    } else {
      stamp = 'all_${now.year}${_two(now.month)}${_two(now.day)}';
    }
    bool inRange(DateTime t) =>
        from == null || (!t.isBefore(from) && t.isBefore(to!));

    final events =
        backend.currentEvents.where((e) => inRange(e.occurredAt)).toList();
    final tasks =
        backend.currentTasks.where((t) => inRange(t.createdAt)).toList();
    try {
      buildExportWorkbook(
        elders: backend.currentElders,
        events: events,
        tasks: tasks,
      ).save(fileName: 'jinsun_radio_report_$stamp.xlsx');
      messenger.showSnackBar(
        SnackBar(
            content: Text(
                '已下載 jinsun_radio_report_$stamp.xlsx（事件 ${events.length}、派遣 ${tasks.length} 筆）')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
            backgroundColor: const Color(0xFFC62828),
            content: Text('匯出失敗：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_simMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('金孫收音機・硬體模擬')),
        body: HardwareSimPage(backend: backend),
      );
    }
    // 個資開關切換 → 頂列按鈕與整個 dashboard 一起重繪
    final content = ValueListenableBuilder<bool>(
      valueListenable: _revealPii,
      builder: (context, _, _) => Column(
        children: [
          _topBar(),
          Expanded(child: _dashboard()),
        ],
      ),
    );
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 720;
      if (narrow) {
        // 手機：導覽移到底部 NavigationBar，內容佔滿寬度（不再被左側 rail 吃寬度）。
        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(bottom: false, child: content),
          bottomNavigationBar: _bottomNav(),
        );
      }
      // 桌機：維持左側圖示導覽軌。
      return Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sidebar(),
              Expanded(child: content),
            ],
          ),
        ),
      );
    });
  }

  /// 手機底部導覽：捲到對應區塊（登出在右上角個人選單）。
  Widget _bottomNav() {
    final keys = [_kDispatch, _kEvents, _kMap, _kWorkers];
    return NavigationBar(
      backgroundColor: Colors.white,
      indicatorColor: _orangeBg,
      selectedIndex: _navIdx.clamp(0, 3),
      onDestinationSelected: (i) => _scrollTo(keys[i], i),
      destinations: const [
        NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping_rounded),
            label: '派遣'),
        NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note_rounded),
            label: '事件'),
        NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map_rounded),
            label: '地圖'),
        NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups_rounded),
            label: '名單'),
      ],
    );
  }

  /// 左側圖示導覽軌（點擊捲到對應區塊）。
  Widget _sidebar() {
    Widget navBtn(IconData icon, String tip, int idx, VoidCallback onTap) {
      final active = _navIdx == idx;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Tooltip(
          message: tip,
          child: Material(
            color: active ? _orange : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: SizedBox(
                width: 46,
                height: 46,
                child: Icon(icon,
                    color: active ? Colors.white : _muted, size: 22),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 76,
      margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Color(0x11A05A16), blurRadius: 18, offset: Offset(0, 6))
        ],
      ),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const JinsunLogo(size: 44),
          const SizedBox(height: 18),
          navBtn(Icons.local_shipping_rounded, '派遣監控', 0,
              () => _scrollTo(_kDispatch, 0)),
          navBtn(Icons.event_note_rounded, '即時事件', 1,
              () => _scrollTo(_kEvents, 1)),
          navBtn(Icons.map_rounded, '服務地圖', 2, () => _scrollTo(_kMap, 2)),
          navBtn(Icons.groups_rounded, '社工名單', 3,
              () => _scrollTo(_kWorkers, 3)),
          const Spacer(),
          navBtn(Icons.logout_rounded, '登出', -1, () => widget.auth.signOut()),
        ],
      ),
    );
  }

  /// 頂列：標題＋日期、緊急提醒鈴、匯出、帳號。
  Widget _topBar() {
    final now = DateTime.now();
    final name = widget.auth.currentUser?.name ?? '社工';
    return StreamBuilder<List<Elder>>(
      stream: backend.elders,
      initialData: backend.currentElders,
      builder: (context, _) {
        final emergency = backend.currentElders
            .where((e) => e.severity == Severity.emergency)
            .length;
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('社工後台',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w900, color: _ink)),
            Text('${now.year}/${_two(now.month)}/${_two(now.day)}　金孫收音機派遣中心',
                style: const TextStyle(fontSize: 12.5, color: _muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        );
        // 只看我負責的長輩（依 supervisor_worker_name 篩選）
        final filterBtn = Tooltip(
          message: _onlyMine ? '目前只顯示我負責的長輩' : '顯示全部長輩',
          child: TextButton.icon(
            onPressed: () => setState(() => _onlyMine = !_onlyMine),
            style: TextButton.styleFrom(
                foregroundColor: _onlyMine ? _orangeDeep : _muted),
            icon: Icon(
                _onlyMine ? Icons.person_pin_circle : Icons.groups_outlined,
                size: 18),
            label: Text(_onlyMine ? '只看我的長輩' : '全部長輩'),
          ),
        );
        // 基本資安：個資打碼開關（預設打碼；防肩窺，需要時才顯示）
        final piiBtn = Tooltip(
          message: _revealPii.value
              ? '個資顯示中，點擊隱藏（打碼）'
              : '個資已打碼保護，點擊顯示完整資料',
          child: TextButton.icon(
            onPressed: () => _revealPii.value = !_revealPii.value,
            style: TextButton.styleFrom(
                foregroundColor:
                    _revealPii.value ? const Color(0xFFC62828) : _muted),
            icon: Icon(
                _revealPii.value
                    ? Icons.visibility_off_rounded
                    : Icons.shield_outlined,
                size: 18),
            label: Text(_revealPii.value ? '隱藏個資' : '個資已保護'),
          ),
        );
        // 緊急提醒鈴（有緊急就紅點）
        final bell = Tooltip(
          message: emergency > 0 ? '$emergency 位長輩緊急處理中' : '目前沒有緊急',
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                onPressed: () => _scrollTo(_kDispatch, 0),
                icon: const Icon(Icons.notifications_none_rounded),
                color: _ink,
              ),
              if (emergency > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                        color: Color(0xFFE5484D), shape: BoxShape.circle),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text('$emergency',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        );
        final excelBtn = FilledButton.icon(
          onPressed: _exportExcel,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('下載 Excel'),
        );
        final avatar = PopupMenuButton<String>(
          tooltip: name,
          onSelected: (v) {
            if (v == 'logout') widget.auth.signOut();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child:
                  Text('$name（${widget.auth.currentUser?.username ?? ''}）'),
            ),
            const PopupMenuItem(value: 'logout', child: Text('登出')),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: _orangeBg,
                child: Text(name.isNotEmpty ? name.characters.first : '社',
                    style: const TextStyle(
                        color: _orangeDeep, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.keyboard_arrow_down, color: _muted, size: 18),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: LayoutBuilder(builder: (context, c) {
            final narrow = c.maxWidth < 640;
            if (narrow) {
              // 手機寬度：標題＋頭像一排；動作鈕（含「下載 Excel」）用可換行 Wrap 排第二排，
              // 確保所有操作（尤其匯出）都在畫面內、不被擠出去。
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [Expanded(child: title), avatar]),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [filterBtn, piiBtn, bell, excelBtn],
                    ),
                  ),
                ],
              );
            }
            return Row(
              children: [
                title,
                const Spacer(),
                filterBtn,
                const SizedBox(width: 4),
                piiBtn,
                const SizedBox(width: 4),
                bell,
                const SizedBox(width: 6),
                excelBtn,
                const SizedBox(width: 12),
                avatar,
              ],
            );
          }),
        );
      },
    );
  }

  Widget _dashboard() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1480),
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
          children: [
            // 派遣監控：每位長輩一張狀態卡（新事件自動置頂、即時推送）。
            KeyedSubtree(
              key: _kDispatch,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('派遣監控（需要決策的事件優先）'),
                  _DispatchMonitor(backend: backend, elderFilter: _visible),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // 即時事件：左側事件列表，右側選取後直接展開完整 Timeline（不跳 Modal）。
            KeyedSubtree(
              key: _kEvents,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('即時事件（點長輩看細節與歷史派遣紀錄）'),
                  _EventCenter(backend: backend, elderFilter: _visible),
                ],
              ),
            ),
            const SizedBox(height: 24),
            KeyedSubtree(
              key: _kMap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('服務地圖（長輩位置與即時狀態）'),
                  _ElderMap(backend: backend, elderFilter: _visible),
                ],
              ),
            ),
            const SizedBox(height: 24),
            KeyedSubtree(
              key: _kWorkers,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('社工名單與班表'),
                  _WorkerTable(backend: backend),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminLogin extends StatefulWidget {
  const _AdminLogin({required this.auth});
  final AuthRepository auth;
  @override
  State<_AdminLogin> createState() => _AdminLoginState();
}

class _AdminLoginState extends State<_AdminLogin> {
  final _user = TextEditingController(text: '0933-222-333');
  final _pass = TextEditingController(text: 'demo1234');
  String? _err;
  bool _busy = false;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.auth
          .signIn(username: _user.text.trim(), password: _pass.text);
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Demo：以不同社工登入，示範「只看我的長輩」各自不同的責任區。
  static const _demoWorkers = <(String, String)>[
    ('王淑芬', '0933-222-333'),
    ('李建成', '0933-333-444'),
    ('張美惠', '0955-555-666'),
  ];

  Future<void> _loginAs(String name, String phone) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      try {
        await widget.auth.signIn(username: phone, password: 'demo1234');
      } on AuthException {
        await widget.auth.signUp(
            username: phone,
            password: 'demo1234',
            name: name,
            role: AuthRole.worker);
      }
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: JinsunLogoBadge(size: 84, radius: 24)),
                const SizedBox(height: 18),
                const Text('金孫收音機・社工後台',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('社工／管理者登入',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted)),
                const SizedBox(height: 28),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                      labelText: '手機號碼', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                  decoration: const InputDecoration(
                      labelText: '密碼', border: OutlineInputBorder()),
                ),
                if (_err != null) ...[
                  const SizedBox(height: 10),
                  Text(_err!, style: const TextStyle(color: Color(0xFFC62828))),
                ],
                const SizedBox(height: 20),
                _GradientCta(
                  onPressed: _busy ? null : _login,
                  label: _busy ? '登入中…' : '登入',
                  icon: Icons.login,
                ),
                const SizedBox(height: 16),
                const Text('Demo：換不同社工登入，「只看我的長輩」責任區各自不同',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: _muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final (name, phone) in _demoWorkers)
                      ActionChip(
                        avatar: const Icon(Icons.badge_outlined, size: 16),
                        label: Text('社工 $name'),
                        onPressed: _busy ? null : () => _loginAs(name, phone),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
                color: _orange, borderRadius: BorderRadius.circular(2)),
          ),
          Flexible(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
          ),
        ],
      ),
    );
  }
}

class _ElderMap extends StatelessWidget {
  const _ElderMap({required this.backend, this.elderFilter});

  final BackendClient backend;
  final bool Function(Elder)? elderFilter;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Elder>>(
      stream: backend.elders,
      initialData: backend.currentElders,
      builder: (context, snapshot) {
        final all = snapshot.data!;
        final elders = elderFilter == null
            ? all
            : all.where(elderFilter!).toList();
        return Card(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 360,
            child: FlutterMap(
              options: const MapOptions(
                initialCenter: LatLng(25.042, 121.535), // 台北市服務區
                initialZoom: 12.5,
                interactionOptions: InteractionOptions(
                  // 滾輪保留給頁面捲動，地圖縮放用拖曳/雙擊/按鈕
                  flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'tw.jinsunradio.admin',
                ),
                MarkerLayer(
                  markers: [
                    for (final e in elders)
                      Marker(
                        point: LatLng(e.lat, e.lng),
                        width: 96,
                        height: 78,
                        alignment: Alignment.topCenter,
                        child: Semantics(
                          button: true,
                          label: '${maskName(e.name)}，${severityText(e.severity)}',
                          child: InkWell(
                          // 點圖釘 → 有進行中派遣單就開改派面板；否則開該長輩細節＋歷史
                          // 派遣紀錄（不再是死點擊）。
                          onTap: () {
                            final active = backend.currentTasks
                                .where((t) =>
                                    t.elderId == e.id &&
                                    t.status != DispatchStatus.resolved)
                                .toList();
                            if (active.isNotEmpty) {
                              pickVolunteer(context, backend, active.first.id);
                            } else {
                              final evs = adminCareEvents(backend)
                                  .where((c) => c.elderId == e.id)
                                  .toList();
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    _ElderDetailScreen(elder: e, events: evs),
                              ));
                            }
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_pin,
                                  size: 38, color: severityColor(e.severity)),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: severityColor(e.severity)),
                                ),
                                child: Text(
                                  '${maskName(e.name)}・${severityText(e.severity)}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: severityColor(e.severity)),
                                ),
                              ),
                            ],
                          ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SimpleAttributionWidget(
                    source: Text('OpenStreetMap contributors')),
              ],
            ),
          ),
        );
      },
    );
  }

}

class _WorkerTable extends StatelessWidget {
  const _WorkerTable({required this.backend});

  final BackendClient backend;

  @override
  Widget build(BuildContext context) {
    // 單量會隨派遣單變動，跟著 tasks stream 重繪
    return StreamBuilder<List<DispatchTask>>(
      stream: backend.tasks,
      initialData: backend.currentTasks,
      builder: (context, _) {
        final now = DateTime.now();
        final workers = [...backend.currentWorkers]..sort((a, b) {
            final duty = (b.onDuty(now) ? 1 : 0) - (a.onDuty(now) ? 1 : 0);
            if (duty != 0) return duty;
            return backend.workerLoad(a.name).compareTo(backend.workerLoad(b.name));
          });
        return Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('社工')),
                DataColumn(label: Text('班表')),
                DataColumn(label: Text('狀態')),
                DataColumn(label: Text('目前單量')),
                DataColumn(label: Text('聯絡電話')),
              ],
              rows: [
                for (final w in workers)
                  DataRow(cells: [
                    DataCell(Text(w.name,
                        style: const TextStyle(fontWeight: FontWeight.bold))),
                    DataCell(Text(w.shiftLabel)),
                    DataCell(Text(
                      w.onDuty(now) ? '值班中' : '下班',
                      style: TextStyle(
                          color: w.onDuty(now)
                              ? const Color(0xFF2E7D32)
                              : _muted,
                          fontWeight: FontWeight.bold),
                    )),
                    DataCell(Text('${backend.workerLoad(w.name)} 件')),
                    DataCell(Text(maskPhone(w.phone))),
                  ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 指派志工前往（後台派遣監控／待處理面板共用）。
void pickVolunteer(BuildContext context, BackendClient backend, String taskId) {
    final messenger = ScaffoldMessenger.of(context);
    // 找出這張單的長輩座標 → 給社工「誰最近」的決策依據（估 ETA、近者排前）。
    DispatchTask? task;
    for (final t in backend.currentTasks) {
      if (t.id == taskId) {
        task = t;
        break;
      }
    }
    Elder? elder;
    if (task != null) {
      for (final e in backend.currentElders) {
        if (e.id == task.elderId) {
          elder = e;
          break;
        }
      }
    }
    final elderCoord = elder != null && (elder.lat != 0 || elder.lng != 0);
    int? etaOf(Volunteer v) {
      if (!elderCoord || (v.lat == 0 && v.lng == 0)) return null;
      return estimateEtaMinutes(v.lat, v.lng, elder!.lat, elder.lng);
    }

    // 排序：上線優先 → ETA 近者優先（估不到 ETA 的排後）→ 時間銀行點數高者優先。
    final vols = [...backend.currentVolunteers]..sort((a, b) {
        final on = (b.online ? 1 : 0) - (a.online ? 1 : 0);
        if (on != 0) return on;
        final ea = etaOf(a), eb = etaOf(b);
        if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
        if (ea != null && eb == null) return -1;
        if (ea == null && eb != null) return 1;
        return b.points.compareTo(a.points);
      });

    Future<void> doAssign(BuildContext sheetCtx, Volunteer v) async {
      final nav = Navigator.of(sheetCtx); // 先抓，避免 await 後跨 async gap 用 context
      // 離線志工可能收不到通知 → 指派前先警示確認（規則：緊急一律派單、不搶單）。
      if (!v.online) {
        final ok = await showDialog<bool>(
          context: sheetCtx,
          builder: (c) => AlertDialog(
            title: const Text('此志工目前離線'),
            content: Text('${v.name} 目前離線，可能收不到派遣通知。仍要指派嗎？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('仍要指派')),
            ],
          ),
        );
        if (ok != true) return;
      }
      nav.pop();
      try {
        await backend.assignVolunteer(taskId,
            volunteerName: v.name, volunteerId: v.id);
        messenger.showSnackBar(SnackBar(content: Text('已指派 ${v.name} 前往')));
      } catch (_) {
        messenger.showSnackBar(const SnackBar(content: Text('指派失敗，請重試')));
      }
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('指派志工前往（近者在前）',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
            ),
            if (vols.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('目前沒有可指派的志工'),
              ),
            for (final v in vols)
              Opacity(
                opacity: v.online ? 1 : 0.55,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: v.online
                        ? const Color(0xFFE3F1FB)
                        : const Color(0xFFEEEEEE),
                    child: Icon(Icons.volunteer_activism,
                        size: 20,
                        color: v.online
                            ? const Color(0xFF2478B5)
                            : Colors.black38),
                  ),
                  title: Text(v.name),
                  isThreeLine: v.intro.isNotEmpty,
                  subtitle: Text([
                        v.online ? '🟢 上線中' : '⚪ 離線',
                        if (etaOf(v) != null) '約 ${etaOf(v)} 分鐘',
                        '時間銀行 ${v.points} 點',
                      ].join('｜') +
                      (v.intro.isNotEmpty ? '\n${v.intro}' : '')),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                  onTap: () => doAssign(ctx, v),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
}

// ============ 派遣監控 + 即時事件（無鏡頭收音事件時間軸）============

/// 從一張進行中派遣單合成即時 CareEvent（後台事件列表／派遣監控用）。
CareEvent _liveCareEvent(Elder elder, DispatchTask t, List<RadioEvent> events) {
  // 用 eventId 精準配對這張單對應的事件（歷史單才不會抓到別筆事件的標題）。
  RadioEvent? ev;
  for (final e in events) {
    if (e.id == t.eventId) {
      ev = e;
      break;
    }
  }
  final trigger = switch (ev?.type) {
    RadioEventType.sos => AcousticTrigger.helpKeyword,
    RadioEventType.fallSuspected => AcousticTrigger.suspectedFall,
    RadioEventType.supplyRequest => AcousticTrigger.supplyRequest,
    _ => t.kind == DispatchKind.supply
        ? AcousticTrigger.supplyRequest
        : AcousticTrigger.cryForHelp,
  };
  final t0 = ev?.occurredAt ?? t.createdAt;
  DateTime at(int m) => t0.add(Duration(minutes: m));
  final steps = <CareStep>[];
  if (t.kind == DispatchKind.followUp) {
    steps.add(CareStep(CareStepKind.detected, t0,
        '近期多次疑似跌倒（均自行回應無恙），系統判定趨勢需留意'));
    steps.add(CareStep(CareStepKind.notifiedWorker, at(0),
        '已為督導個管 ${t.workerName} 開立追蹤訪視待辦（非緊急、未派志工）'));
    if (t.status == DispatchStatus.resolved) {
      steps.add(CareStep(CareStepKind.eventClosed, t.resolvedAt ?? at(1),
          t.note ?? '個管已完成追蹤訪視'));
    }
  } else if (t.kind == DispatchKind.supply) {
    steps.add(CareStep(
        CareStepKind.detected, t0, '長輩語音提出物資需求：${t.items.join('、')}'));
    if (t.assigneeName != null) {
      steps.add(CareStep(
          CareStepKind.workerAccepted, at(1), '志工 ${t.assigneeName} 接單'));
    }
    if (t.status == DispatchStatus.resolved) {
      steps.add(CareStep(
          CareStepKind.eventClosed, t.resolvedAt ?? at(20), t.note ?? '物資已送達'));
    }
  } else {
    steps.add(CareStep(CareStepKind.detected, t0, trigger.label));
    steps.add(CareStep(CareStepKind.aiConfirming, at(0), 'AI 主動語音確認狀況'));
    if (t.assigneeName != null) {
      steps.add(
          CareStep(CareStepKind.noResponse, at(1), '長輩未即時回應，判定需前往'));
      steps.add(CareStep(CareStepKind.notifiedWorker, at(1), '已就近通知志工'));
      steps.add(CareStep(
          CareStepKind.workerAccepted, at(2), '志工 ${t.assigneeName} 接案'));
      steps.add(CareStep(CareStepKind.workerDeparted, at(2),
          '志工出發${t.etaMinutes != null ? '，預估 ${t.etaMinutes} 分鐘到' : ''}'));
    }
    if (t.status == DispatchStatus.arrived ||
        t.status == DispatchStatus.resolved) {
      steps.add(CareStep(CareStepKind.workerArrived, at(3), '志工抵達長輩家'));
    }
    if (t.status == DispatchStatus.resolved) {
      steps.add(CareStep(
          CareStepKind.confirmedSafe, t.resolvedAt ?? at(6), t.note ?? '已確認長輩安全'));
      steps.add(
          CareStep(CareStepKind.eventClosed, t.resolvedAt ?? at(7), '事件結束'));
    }
  }
  final peak =
      t.kind == DispatchKind.emergency ? Severity.emergency : Severity.attention;
  return CareEvent(
    id: 'live-${t.id}',
    elderId: elder.id,
    elderName: elder.name,
    trigger: trigger,
    peakSeverity: peak,
    steps: steps,
  );
}

/// 單筆真實 radio_event（沒有對應派遣單者，如誤報跌倒、長輩自行回應無恙）合成 CareEvent。
CareEvent _careEventFromRadio(Elder elder, RadioEvent ev) {
  final trigger = switch (ev.type) {
    RadioEventType.sos => AcousticTrigger.helpKeyword,
    RadioEventType.fallSuspected => AcousticTrigger.suspectedFall,
    RadioEventType.supplyRequest => AcousticTrigger.supplyRequest,
  };
  final hasText = ev.transcript != null && ev.transcript!.isNotEmpty;
  final steps = <CareStep>[
    CareStep(CareStepKind.detected, ev.occurredAt,
        hasText ? '長輩語音：${ev.transcript}' : trigger.label),
  ];
  switch (ev.status) {
    case RadioEventStatus.confirmedOk:
      steps.add(CareStep(
          CareStepKind.confirmedSafe, ev.occurredAt, '長輩回應無恙，虛驚一場'));
      steps.add(CareStep(CareStepKind.eventClosed, ev.occurredAt, '事件結束'));
    case RadioEventStatus.closed:
      steps.add(CareStep(CareStepKind.eventClosed, ev.occurredAt, '事件已結案'));
    case RadioEventStatus.escalated:
      steps.add(CareStep(
          CareStepKind.notifiedWorker, ev.occurredAt, '已升級，通知志工前往'));
    case RadioEventStatus.open:
      steps.add(CareStep(
          CareStepKind.aiConfirming, ev.occurredAt, 'AI 主動語音確認狀況'));
  }
  return CareEvent(
    id: 'ev-${ev.id}',
    elderId: elder.id,
    elderName: elder.name,
    trigger: trigger,
    peakSeverity: ev.severity,
    steps: steps,
  );
}

/// 後台統一事件流：全部來自真實資料——派遣單（進行中＋已結案，與志工歷史同一份）
/// ＋沒有派遣單的真實 radio_event。不再有任何假的「AI 主動關懷」展示資料。新→舊。
List<CareEvent> adminCareEvents(BackendClient backend) {
  final elders = backend.currentElders;
  Elder? elderOf(String id) {
    for (final e in elders) {
      if (e.id == id) return e;
    }
    return null;
  }

  final out = <CareEvent>[];
  final linkedEventIds = <String>{};
  // 1) 所有派遣單（進行中＋已結案）→ 真實 CareEvent。已結案的正是志工歷史那批同一份資料。
  for (final t in backend.currentTasks) {
    final e = elderOf(t.elderId);
    if (e == null) continue;
    out.add(_liveCareEvent(e, t, backend.currentEvents));
    if (t.eventId.isNotEmpty) linkedEventIds.add(t.eventId);
  }
  // 2) 沒有對應派遣單的真實事件（誤報跌倒、長輩自行回應無恙等）→ 也列出來。
  for (final ev in backend.currentEvents) {
    if (linkedEventIds.contains(ev.id)) continue;
    final e = elderOf(ev.elderId);
    if (e == null) continue;
    out.add(_careEventFromRadio(e, ev));
  }
  out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
  return out;
}

String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// 派遣監控：每位長輩一張狀態卡（🟠 AI 確認中／🔴 志工出發 ETA／🟢 已完成），
/// 進行中事件自動置頂，隨 tasks 串流即時推送更新。
class _DispatchMonitor extends StatefulWidget {
  const _DispatchMonitor({required this.backend, this.elderFilter});

  final BackendClient backend;
  final bool Function(Elder)? elderFilter;

  @override
  State<_DispatchMonitor> createState() => _DispatchMonitorState();
}

class _DispatchMonitorState extends State<_DispatchMonitor> {
  Timer? _ticker;

  BackendClient get backend => widget.backend;

  @override
  void initState() {
    super.initState();
    // 每 10 秒重繪，讓「已等 X 分」與「逾時」即時跳動（不必等 tasks 串流變化）。
    _ticker = Timer.periodic(
        const Duration(seconds: 10), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DispatchTask>>(
      stream: backend.tasks,
      initialData: backend.currentTasks,
      builder: (context, _) {
        final now = DateTime.now();
        final filter = widget.elderFilter;
        final elders = filter == null
            ? backend.currentElders
            : backend.currentElders.where(filter).toList();
        if (elders.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('你目前沒有負責的長輩', style: TextStyle(color: _muted)),
          );
        }
        final items = <_MonitorItem>[];
        for (final e in elders) {
          DispatchTask? active;
          for (final t in backend.currentTasks) {
            if (t.elderId == e.id && t.status != DispatchStatus.resolved) {
              if (active == null || t.createdAt.isAfter(active.createdAt)) {
                active = t;
              }
            }
          }
          DateTime? lastDone;
          if (active == null) {
            // 真實：最後一張已結案派遣單的完成時間；沒有就用最後一筆真實事件時間。
            for (final t in backend.currentTasks) {
              if (t.elderId == e.id && t.status == DispatchStatus.resolved) {
                final at = t.resolvedAt ?? t.createdAt;
                if (lastDone == null || at.isAfter(lastDone)) lastDone = at;
              }
            }
            if (lastDone == null) {
              for (final ev in backend.currentEvents) {
                if (ev.elderId == e.id &&
                    (lastDone == null || ev.occurredAt.isAfter(lastDone))) {
                  lastDone = ev.occurredAt;
                }
              }
            }
          }
          items.add(_MonitorItem(
              elder: e, task: active, lastDone: lastDone, now: now));
        }
        // 排序：卡單（逾時未接）最前 → 進行中（等最久的前面）→ 已完成。
        items.sort((a, b) {
          if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
          final la = a.task != null, lb = b.task != null;
          if (la != lb) return la ? -1 : 1;
          if (a.rank != b.rank) return b.rank.compareTo(a.rank);
          return b.waitSeconds.compareTo(a.waitSeconds);
        });
        // 統計（一目瞭然）：緊急 / 注意 / 待接單，與下方清單同一份 items。
        var emerg = 0, attn = 0, pending = 0;
        for (final it in items) {
          final t = it.task;
          if (t == null) continue;
          final sev = it.status().$2;
          if (sev == Severity.emergency) {
            emerg++;
          } else if (sev == Severity.attention) {
            attn++;
          }
          if (t.status == DispatchStatus.pending) pending++;
        }
        // 「需要處理」= 有進行中派遣單者（待接單／前往中／已到場／督導追蹤）。
        final actionable = items.where((it) => it.task != null).toList();

        return LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 720;
          if (narrow) {
            // 手機寬度：統計條 + 只列「要處理」的事件（緊要在前），不被正常長輩洗版，一眼看完。
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _summaryBar(emerg, attn, pending),
                const SizedBox(height: 12),
                if (actionable.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child: Text('目前沒有需要處理的事件',
                            style: TextStyle(color: _muted))),
                  )
                else
                  for (final it in actionable)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _compactRow(it),
                    ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryBar(emerg, attn, pending),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [for (final it in items) _card(it)],
              ),
            ],
          );
        });
      },
    );
  }

  /// 一目瞭然統計條：緊急 / 注意 / 待接單。
  Widget _summaryBar(int emerg, int attn, int pending) {
    Widget chip(String label, int n, Color fg, Color bg) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration:
                BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            child: Column(
              children: [
                Text('$n',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: fg)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 12.5, color: fg)),
              ],
            ),
          ),
        );
    return Row(
      children: [
        chip('緊急', emerg, const Color(0xFFC62828), const Color(0xFFFDECEA)),
        const SizedBox(width: 10),
        chip('注意', attn, _orangeDeep, _orangeBg),
        const SizedBox(width: 10),
        chip('待接單', pending, const Color(0xFF0E6EA8), const Color(0xFFE3F1FB)),
      ],
    );
  }

  /// 手機寬度用的精簡事件列：狀態＋等候＋（標記到達／結案／聯絡）動作；點列開改派面板。
  Widget _compactRow(_MonitorItem it) {
    final (label, sev, sub) = it.status();
    final t = it.task!;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => pickVolunteer(context, backend, t.id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: it.overdue ? severityFill(Severity.emergency) : _line,
                width: it.overdue ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: severityFill(sev), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(maskName(it.elder.name),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: _ink)),
                  ),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: severityColor(sev))),
                ],
              ),
              if (sub != null) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: Text(sub,
                      style: TextStyle(
                          fontSize: 12,
                          color: it.overdue
                              ? const Color(0xFFC62828)
                              : _muted)),
                ),
              ],
              if (t.kind != DispatchKind.followUp &&
                  t.status != DispatchStatus.resolved) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (t.status == DispatchStatus.accepted)
                      _cardAction('標記到達', Icons.location_on,
                          () => _markArrived(t.id)),
                    if (t.status == DispatchStatus.accepted ||
                        t.status == DispatchStatus.arrived)
                      _cardAction('結案', Icons.check_circle_outline,
                          () => _resolve(t.id)),
                    _cardAction('聯絡', Icons.call, () => _contact(it.elder, t)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(_MonitorItem it) {
    final (label, sev, sub) = it.status();
    final t = it.task;
    // 只有進行中的單可點：點卡片 → 開改派／指派面板。
    final tappable = t != null;
    return SizedBox(
      width: 264,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: tappable ? () => pickVolunteer(context, backend, t.id) : null,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: it.overdue ? severityFill(Severity.emergency) : _line,
                  width: it.overdue ? 1.5 : 1),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x0FA05A16), blurRadius: 12, offset: Offset(0, 4))
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: severityBg(sev), shape: BoxShape.circle),
                      child:
                          Icon(Icons.elderly, size: 20, color: severityColor(sev)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(maskName(it.elder.name),
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: _ink)),
                    ),
                    if (it.overdue)
                      const Icon(Icons.error, size: 18, color: Color(0xFFC62828))
                    else if (tappable)
                      const Icon(Icons.swap_horiz, size: 16, color: _muted),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: severityFill(sev), shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: severityColor(sev))),
                    ),
                  ],
                ),
                if (sub != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 18),
                    child: Text(sub,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: it.overdue
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: it.overdue
                                ? const Color(0xFFC62828)
                                : _muted)),
                  ),
                ],
                // 社工可直接操作的動作：不再只能「換人」。督導追蹤單（followUp）
                // 由個管另行結案，這裡不放到達/結案。
                if (t != null &&
                    t.kind != DispatchKind.followUp &&
                    t.status != DispatchStatus.resolved) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (t.status == DispatchStatus.accepted)
                        _cardAction('標記到達', Icons.location_on,
                            () => _markArrived(t.id)),
                      if (t.status == DispatchStatus.accepted ||
                          t.status == DispatchStatus.arrived)
                        _cardAction('結案', Icons.check_circle_outline,
                            () => _resolve(t.id)),
                      _cardAction(
                          '聯絡', Icons.call, () => _contact(it.elder, t)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardAction(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        minimumSize: const Size(0, 34),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }

  Future<void> _markArrived(String taskId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await backend.markArrived(taskId);
      messenger.showSnackBar(const SnackBar(content: Text('已標記志工到達')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('操作失敗，請重試')));
    }
  }

  Future<void> _resolve(String taskId) async {
    final messenger = ScaffoldMessenger.of(context);
    // 物資單＝送達完成，用「已完成」；跌倒／SOS 才是「確認平安」。
    DispatchTask? t;
    for (final x in backend.currentTasks) {
      if (x.id == taskId) {
        t = x;
        break;
      }
    }
    final isSupply = t?.kind == DispatchKind.supply;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(isSupply ? '確認已完成' : '確認結案'),
        content: Text(isSupply
            ? '確認志工已將物資送達、任務完成？結案後會計入服務時數，且無法復原。'
            : '確認志工已完成服務、長輩目前平安？結案後會計入服務時數，且無法復原。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(isSupply ? '確認已完成' : '確認結案')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await backend.resolveTask(taskId,
          note: isSupply ? '社工後台：物資已完成' : '社工後台結案');
      messenger.showSnackBar(
          SnackBar(content: Text(isSupply ? '已完成' : '已結案')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('操作失敗，請重試')));
    }
  }

  String _volPhone(String name) {
    for (final v in backend.currentVolunteers) {
      if (v.name == name) return v.phone;
    }
    return '';
  }

  String _workerPhone(String name) {
    for (final w in backend.currentWorkers) {
      if (w.name == name) return w.phone;
    }
    return '';
  }

  /// 後台聯絡資訊：社工是內部人力，直接顯示可撥打的電話（長輩／志工／督導）。
  void _contact(Elder elder, DispatchTask t) {
    Widget row(String who, String? phone) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(who)),
              const SizedBox(width: 12),
              Text((phone == null || phone.isEmpty) ? '未提供' : phone,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        );
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('聯絡資訊'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row('長輩 ${elder.name}', elder.phone),
            if (t.assigneeName != null)
              row('志工 ${t.assigneeName}', _volPhone(t.assigneeName!)),
            if (t.workerName != null)
              row('督導社工 ${t.workerName}', _workerPhone(t.workerName!)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('關閉')),
        ],
      ),
    );
  }
}

class _MonitorItem {
  _MonitorItem(
      {required this.elder, this.task, this.lastDone, required this.now});
  final Elder elder;
  final DispatchTask? task;
  final DateTime? lastDone;
  final DateTime now;

  int get waitSeconds {
    final t = task;
    return t == null ? 0 : now.difference(t.createdAt).inSeconds;
  }

  String get _waitLabel {
    final m = waitSeconds ~/ 60;
    return m < 1 ? '剛派出' : '已等 $m 分';
  }

  /// 卡單：緊急・待接單・已指派・逾 offered_until 仍沒人接。
  bool get overdue {
    final t = task;
    return t != null &&
        t.kind == DispatchKind.emergency &&
        t.status == DispatchStatus.pending &&
        t.offeredUntil != null &&
        now.isAfter(t.offeredUntil!);
  }

  int get rank {
    final (_, sev, _) = status();
    return switch (sev) {
      Severity.emergency => 3,
      Severity.attention => 2,
      Severity.normal => 1,
    };
  }

  (String, Severity, String?) status() {
    final t = task;
    if (t != null) {
      if (t.kind == DispatchKind.followUp) {
        return t.status == DispatchStatus.resolved
            ? ('追蹤已完成', Severity.normal, '個管 ${t.workerName} 已處理')
            : ('待督導追蹤', Severity.attention, '個管 ${t.workerName}・疑似跌倒趨勢');
      }
      if (t.kind == DispatchKind.supply) {
        return t.assigneeName != null
            ? ('志工處理中', Severity.attention, '物資代購・${t.assigneeName}')
            : ('物資待接單', Severity.attention, '等待志工接單');
      }
      return switch (t.status) {
        // 緊急待接單：顯示已派給誰＋已等多久；逾時轉紅告警（卡單）。
        DispatchStatus.pending => overdue
            ? (
                '等待逾時・改派中',
                Severity.emergency,
                '原派 ${t.assigneeName ?? '－'}・$_waitLabel・已廣播請支援'
              )
            : (
                t.assigneeName == null ? '待接單（已開放全體）' : '已派單・等待接單',
                Severity.emergency,
                t.assigneeName == null
                    ? _waitLabel
                    : '已派 ${t.assigneeName}・$_waitLabel'
              ),
        DispatchStatus.accepted => (
            '志工前往中',
            Severity.emergency,
            t.etaMinutes != null ? 'ETA：${t.etaMinutes} 分鐘' : null
          ),
        DispatchStatus.arrived => ('志工已抵達', Severity.emergency, '現場確認中'),
        DispatchStatus.resolved => ('已完成', Severity.normal, null),
      };
    }
    return ('已完成', Severity.normal, lastDone != null ? _hm(lastDone!) : '狀況穩定');
  }
}

/// 即時事件：左側事件列表（點選），右側直接展開完整 Timeline（不跳 Modal）。
class _EventCenter extends StatefulWidget {
  const _EventCenter({required this.backend, this.elderFilter});

  final BackendClient backend;
  final bool Function(Elder)? elderFilter;

  @override
  State<_EventCenter> createState() => _EventCenterState();
}

class _EventCenterState extends State<_EventCenter> {
  String? _selElderId; // 選中的長輩（寬版右側顯示其細節與歷史）

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DispatchTask>>(
      stream: widget.backend.tasks,
      initialData: widget.backend.currentTasks,
      builder: (context, _) {
        final filter = widget.elderFilter;
        var elders = widget.backend.currentElders;
        if (filter != null) elders = elders.where(filter).toList();
        // 每位長輩的歷史事件（真實 radio_events + 派遣單，新→舊）。
        final byElder = <String, List<CareEvent>>{};
        for (final ev in adminCareEvents(widget.backend)) {
          (byElder[ev.elderId] ??= []).add(ev);
        }
        int rankOf(Elder e) {
          final active =
              (byElder[e.id] ?? const <CareEvent>[]).where((x) => !x.resolved);
          if (active.any((x) => x.peakSeverity == Severity.emergency) ||
              e.severity == Severity.emergency) {
            return 3;
          }
          if (active.any((x) => x.peakSeverity == Severity.attention) ||
              e.severity == Severity.attention) {
            return 2;
          }
          return 1;
        }

        final sorted = [...elders]..sort((a, b) {
            final r = rankOf(b).compareTo(rankOf(a));
            return r != 0 ? r : a.name.compareTo(b.name);
          });
        if (sorted.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('目前沒有長輩', style: TextStyle(color: _muted)),
            ),
          );
        }

        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 720; // 與派遣監控／主佈局同一斷點，平板不再混搭
          if (!wide) {
            // 手機：長輩清單，點一位 → 推到細節＋歷史派遣紀錄頁。
            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < sorted.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: _line),
                    _elderRow(
                      sorted[i],
                      byElder[sorted[i].id] ?? const [],
                      false,
                      () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => _ElderDetailScreen(
                            elder: sorted[i],
                            events: byElder[sorted[i].id] ?? const []),
                      )),
                    ),
                  ],
                ],
              ),
            );
          }
          final sel = sorted.firstWhere((e) => e.id == _selElderId,
              orElse: () => sorted.first);
          return SizedBox(
            height: 580,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 320,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: sorted.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: _line),
                      itemBuilder: (context, i) {
                        final e = sorted[i];
                        return _elderRow(
                            e,
                            byElder[e.id] ?? const [],
                            e.id == sel.id,
                            () => setState(() => _selElderId = e.id));
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                    child: _ElderDetailView(
                        elder: sel, events: byElder[sel.id] ?? const [])),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _elderRow(
      Elder e, List<CareEvent> evs, bool selected, VoidCallback onTap) {
    final active = evs.where((x) => !x.resolved).toList();
    final sev = active.isNotEmpty ? active.first.peakSeverity : e.severity;
    final String sub;
    if (active.isNotEmpty) {
      sub =
          '${active.first.trigger.label}・${active.first.currentStep?.kind.label ?? '處理中'}';
    } else if (evs.isEmpty) {
      sub = '無派遣紀錄';
    } else {
      sub = '狀況穩定・${evs.length} 筆紀錄';
    }
    return Material(
      color: selected ? _orangeBg.withValues(alpha: 0.6) : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: severityFill(sev), shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(maskName(e.name),
                        style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: _ink)),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(
                            fontSize: 12,
                            color: active.isNotEmpty
                                ? severityColor(sev)
                                : _muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: _muted, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// 長輩細節＋歷史派遣紀錄（社工後台「即時事件」點一位長輩後看到的內容）。
class _ElderDetailView extends StatelessWidget {
  const _ElderDetailView({required this.elder, required this.events});

  final Elder elder;
  final List<CareEvent> events; // 這位長輩的歷史事件（新→舊）

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _revealPii,
      builder: (context, _, _) => Card(
        clipBehavior: Clip.antiAlias,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            _profile(),
            const SizedBox(height: 18),
            // 志工到場所見的照護資訊——後台點進長輩看到同一份（志工端所見即後台所見）。
            _CareChecklist(elder: elder),
            const SizedBox(height: 18),
            Row(
              children: [
                const Text('歷史派遣紀錄',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: _ink)),
                const SizedBox(width: 8),
                Text('共 ${events.length} 筆',
                    style: const TextStyle(fontSize: 12.5, color: _muted)),
              ],
            ),
            const SizedBox(height: 10),
            if (events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child:
                    Text('這位長輩目前沒有派遣紀錄', style: TextStyle(color: _muted)),
              )
            else
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _EventTile(event: e),
                ),
          ],
        ),
      ),
    );
  }

  Widget _profile() {
    final sev = elder.severity;
    Widget row(IconData ic, String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ic, size: 16, color: _muted),
              const SizedBox(width: 8),
              SizedBox(
                  width: 60,
                  child: Text(label,
                      style: const TextStyle(fontSize: 12.5, color: _muted))),
              Expanded(
                  child: Text(value,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600))),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: severityBg(sev), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle),
                child: Icon(Icons.elderly, color: severityColor(sev)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(maskName(elder.name),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: _ink)),
                    Text('${elder.age} 歲・${_severityLabel(sev)}',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: severityColor(sev))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          row(Icons.place_outlined, '地址', maskAddress(elder.address)),
          row(Icons.phone_outlined, '電話', maskPhone(elder.phone)),
          row(Icons.record_voice_over_outlined, '語言',
              elder.preferredLang.label),
          if (elder.supervisorWorkerName != null)
            row(Icons.badge_outlined, '督導社工', elder.supervisorWorkerName!),
          if (elder.supervisorVolunteerName != null)
            row(Icons.volunteer_activism_outlined, '督導志工',
                elder.supervisorVolunteerName!),
          row(Icons.sticky_note_2_outlined, '注記',
              maskNote(elder.note).isEmpty ? '—' : maskNote(elder.note)),
        ],
      ),
    );
  }
}

/// 長輩照護資訊（志工到場所見）——後台點進長輩看到同一份十大類檢核清單，
/// 資料共用 jinsun_core 的 careCategories。重點列尊重後台 PII 反遮罩開關。
class _CareChecklist extends StatelessWidget {
  const _CareChecklist({required this.elder});
  final Elder elder;

  static const _careBlue = Color(0xFF2563EB);
  static const _careBlueBg = Color(0xFFEFF5FF);

  @override
  Widget build(BuildContext context) {
    final note = maskNote(elder.note);
    final phone = maskPhone(elder.phone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.assignment_ind_outlined, size: 18, color: _careBlue),
            const SizedBox(width: 6),
            const Text('長輩照護資訊',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w900, color: _ink)),
            const SizedBox(width: 8),
            Text('志工到場所見・點類別展開',
                style: const TextStyle(fontSize: 11.5, color: _muted)),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _careBlueBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.isNotEmpty) ...[
                Text('📋 本次照護重點：$note',
                    style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: _careBlue)),
                const SizedBox(height: 6),
              ],
              Text(
                  '👤 ${maskName(elder.name)}（${elder.age} 歲）　🗣️ 慣用${elder.preferredLang.label}'
                  '${phone.isNotEmpty ? '　📞 家中 $phone' : ''}',
                  style: const TextStyle(fontSize: 12.5, height: 1.4, color: _ink)),
            ],
          ),
        ),
        for (final cat in careCategories) _CareCategoryTile(cat: cat),
      ],
    );
  }
}

/// 單一照護類別的收合／展開卡（點標題展開項目）。
class _CareCategoryTile extends StatefulWidget {
  const _CareCategoryTile({required this.cat});
  final CareCategory cat;

  @override
  State<_CareCategoryTile> createState() => _CareCategoryTileState();
}

class _CareCategoryTileState extends State<_CareCategoryTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cat = widget.cat;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Icon(cat.icon, size: 20, color: _CareChecklist._careBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(cat.title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: _ink)),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: _muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in cat.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child:
                                Icon(Icons.circle, size: 5, color: _muted),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(item,
                                style: const TextStyle(
                                    fontSize: 13, height: 1.45, color: _ink)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 手機寬度：點長輩推到的細節頁。
class _ElderDetailScreen extends StatelessWidget {
  const _ElderDetailScreen({required this.elder, required this.events});

  final Elder elder;
  final List<CareEvent> events;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(maskName(elder.name))),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _ElderDetailView(elder: elder, events: events),
      ),
    );
  }
}

/// 單筆歷史派遣紀錄：可展開看完整時間軸。
class _EventTile extends StatefulWidget {
  const _EventTile({required this.event});
  final CareEvent event;

  @override
  State<_EventTile> createState() => _EventTileState();
}

class _EventTileState extends State<_EventTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final sev = e.resolved ? Severity.normal : e.peakSeverity;
    return Container(
      decoration: BoxDecoration(
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: severityFill(sev), shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.trigger.label,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: severityColor(sev))),
                        const SizedBox(height: 2),
                        Text(
                            '${_fmtDateTime(e.startedAt)}・${e.resolved ? '已結束' : '進行中'}',
                            style:
                                const TextStyle(fontSize: 12, color: _muted)),
                      ],
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: _muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                children: [
                  for (var i = 0; i < e.steps.length; i++)
                    _tlStep(e, e.steps[i],
                        first: i == 0, last: i == e.steps.length - 1),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tlStep(CareEvent e, CareStep s,
      {required bool first, required bool last}) {
    final color = severityColor(s.kind.severity);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(_hm(s.at),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: _muted)),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              Container(
                  width: 2,
                  height: 4,
                  color: first ? Colors.transparent : _line),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5)),
              ),
              Expanded(
                  child: Container(
                      width: 2, color: last ? Colors.transparent : _line)),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.kind.label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: color)),
                  const SizedBox(height: 1),
                  Text(s.text.replaceAll(e.elderName, maskName(e.elderName)),
                      style: const TextStyle(fontSize: 12.5, height: 1.4)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分級中文標籤。
String _severityLabel(Severity s) => switch (s) {
      Severity.emergency => '緊急',
      Severity.attention => '注意',
      Severity.normal => '正常',
    };
