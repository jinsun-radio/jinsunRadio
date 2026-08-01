import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import 'app_local.dart';
import 'screens/bind_screen.dart';
import 'screens/home_page.dart';
import 'screens/login_screen.dart';
import 'screens/notifications_page.dart';
import 'screens/reminders_page.dart';
import 'screens/settings_page.dart';
import 'screens/stats_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 高齡照護產品：無障礙預設開啟（也讓 Web demo 可被輔助工具操作）
  SemanticsBinding.instance.ensureSemantics();
  // 後端由 --dart-define=BACKEND 決定（supabase 預設／aws 平行環境），見 JinsunBackends。
  await JinsunBackends.ensureInitialized();
  // 推播（FCM+APNs）：初始化在 runApp 前；實際 token 註冊在登入後（見下方）。
  await PushService.instance.initialize();
  runApp(const FamilyApp());
}

class FamilyApp extends StatefulWidget {
  const FamilyApp({super.key, this.backend, this.auth});

  // 可注入後端／認證（測試用 MockBackend）；正式版由 JinsunBackends 依建置參數決定。
  final BackendClient? backend;
  final AuthRepository? auth;

  @override
  State<FamilyApp> createState() => _FamilyAppState();
}

class _FamilyAppState extends State<FamilyApp> {
  late final BackendClient backend;
  late final AuthRepository auth;
  late final AppLocal local;
  StreamSubscription<AuthUser?>? _pushAuthSub;
  String _pushElderKey = '';

  @override
  void initState() {
    super.initState();
    auth = widget.auth ?? JinsunBackends.createAuth(AuthRole.family);
    backend = widget.backend ?? JinsunBackends.createBackend(auth);
    local = AppLocal(backend, auth);
    // 推播 token 要寫進「目前這一套」後端，不能寫死 Supabase。
    PushService.instance.backend = backend;

    // 推播 token 註冊：登入即註冊、登出即解除。綁定長輩清單變動時同步 topic。
    _pushAuthSub = auth.authStateChanges().listen((user) {
      if (user != null) {
        PushService.instance
            .registerForUser(user, elderIds: local.boundIds.toList());
      } else {
        _pushElderKey = '';
        PushService.instance.unregister();
      }
    });
    local.addListener(_syncPushElders);

    // 還原已登入 session，再處理 demo 參數
    auth.restore().then((_) async {
      final demo = Uri.base.queryParameters['demo'];
      if (demo != null) {
        if (auth.currentUser == null) {
          await auth.signIn(username: '0912-345-678', password: 'demo1234');
        }
        await local.bindBySerial('JS-0001');
        if (demo == 'fall') {
          Timer(const Duration(seconds: 3),
              () => backend.triggerFallSuspected('elder-1'));
        }
      }
    });
  }

  /// 綁定長輩清單變動時，同步推播 topic（家屬只收綁定長輩的事件）。
  void _syncPushElders() {
    if (auth.currentUser == null) return;
    final key = (local.boundIds.toList()..sort()).join(',');
    if (key == _pushElderKey) return;
    _pushElderKey = key;
    PushService.instance.updateElderIds(local.boundIds.toList());
  }

  @override
  void dispose() {
    _pushAuthSub?.cancel();
    local.removeListener(_syncPushElders);
    backend.dispose();
    auth.dispose();
    local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '金孫收音機（家屬端）',
      debugShowCheckedModeBanner: false,
      theme: jinsunTheme(JinsunColors.orange),
      home: StreamBuilder<AuthUser?>(
        stream: auth.authStateChanges(),
        initialData: auth.currentUser,
        builder: (context, snapshot) {
          final user = snapshot.data;
          if (user == null) return LoginScreen(auth: auth);
          return ListenableBuilder(
            listenable: local,
            builder: (context, _) {
              // 綁定資料或長輩清單還在從 Supabase 載入 → 先顯示 loading，避免閃過綁定頁
              final loading = !local.bindingsLoaded ||
                  (local.boundIds.isNotEmpty && local.boundElders.isEmpty);
              if (loading) {
                // 長輩資料載入失敗／不一致時，boundElders 可能一直是空 → 這頁別讓家屬
                // 卡在孤零零的轉圈只能砍 App；永遠留「重新載入 / 登出」兩條退路。
                return Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        const Text('正在載入長輩資料…',
                            style: TextStyle(color: JinsunColors.muted)),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => local.loadBindings(),
                          child: const Text('重新載入'),
                        ),
                        TextButton(
                          onPressed: () => local.logout(),
                          child: const Text('登出',
                              style: TextStyle(color: JinsunColors.muted)),
                        ),
                      ],
                    ),
                  ),
                );
              }
              // 沒有綁定任何收音機（新帳號）→ onboarding 綁定；否則直接進首頁
              if (local.boundElders.isEmpty) return BindScreen(local: local);
              // 外層掛：①來電監聽（志工打來全螢幕響鈴）②即時通知橫幅（Realtime 推播）。
              // InAppNotifier 靠 Supabase Realtime 串流，長輩一有狀況就從畫面上方滑下橫幅，
              // 點一下進「即時紀錄」——這就是網頁端不靠系統推播的即時通知。
              return CallListener(
                backend: local.backend,
                selfRole: CallRole.family,
                selfName: '家屬',
                accent: JinsunColors.orange,
                child: InAppNotifier(
                  notifications: local.backend.notifications,
                  filter: (n) =>
                      n.elderId == null || local.boundIds.contains(n.elderId),
                  onTap: (_) => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => NotificationsPage(local: local))),
                  child: HomeShell(local: local),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.local});

  final AppLocal local;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  // 通知不再用底部 SnackBar；改由 AppLocal 累積通知歷史、首頁「即時紀錄」呈現。

  /// 綁定長輩目前「未結案」事件的最高分級：緊急 > 注意 > 無。
  /// 用來在任何分頁上都顯示醒目警示＋首頁紅點，避免家屬停在其他分頁時漏接。
  Severity? _activeSeverity(List<RadioEvent> events) {
    final ids = widget.local.boundIds;
    var anyAttention = false;
    for (final e in events) {
      if (!ids.contains(e.elderId)) continue;
      if (e.status == RadioEventStatus.confirmedOk ||
          e.status == RadioEventStatus.closed) {
        continue;
      }
      if (e.severity == Severity.emergency) return Severity.emergency;
      if (e.severity == Severity.attention) anyAttention = true;
    }
    return anyAttention ? Severity.attention : null;
  }

  /// 跨分頁緊急警示條：點一下跳回首頁看詳情。
  Widget _emergencyBanner(Severity s) {
    final emerg = s == Severity.emergency;
    return Material(
      color: emerg ? const Color(0xFFD32F2F) : JinsunColors.orange,
      child: InkWell(
        onTap: () => setState(() => _tab = 0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(emerg ? Icons.notifications_active : Icons.info_outline,
                  color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  emerg ? '長輩有緊急狀況，請立即查看' : '長輩狀況確認中，請留意',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5),
                ),
              ),
              const Text('查看 ›',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  /// 通知權限被拒的明顯提醒（不再靜默失效）。點一下重新請求權限——這是最攸關安全的
  /// 設定（收不到跌倒／SOS 通知），不能只丟一句「請自己去設定」讓家屬找不到入口。
  Widget _permissionBanner() {
    return Material(
      color: const Color(0xFFFFF3CD),
      child: InkWell(
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final user = widget.local.auth.currentUser;
          if (user != null) {
            await PushService.instance.registerForUser(user,
                elderIds: widget.local.boundIds.toList());
          }
          if (!mounted) return;
          if (PushService.instance.permissionBlocked.value) {
            messenger.showSnackBar(const SnackBar(
                content: Text('仍未取得通知權限，請到手機「設定 → 通知 → 金孫收音機」手動開啟'),
                duration: Duration(seconds: 4)));
          } else {
            messenger.showSnackBar(const SnackBar(
                content: Text('通知已開啟，跌倒／SOS 會即時通知你')));
          }
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.notifications_off, color: Color(0xFF8A6D00), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '通知權限未開啟，可能收不到跌倒／SOS 通知。點這裡重新開啟。',
                  style: TextStyle(
                      color: Color(0xFF8A6D00), fontSize: 13, height: 1.4),
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF8A6D00), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(local: widget.local),
      StatsPage(local: widget.local),
      RemindersPage(local: widget.local),
      SettingsPage(local: widget.local),
    ];
    return StreamBuilder<List<RadioEvent>>(
      stream: widget.local.backend.events,
      initialData: widget.local.backend.currentEvents,
      builder: (context, snap) {
        final active = _activeSeverity(snap.data ?? const []);
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (active != null) _emergencyBanner(active),
                ValueListenableBuilder<bool>(
                  valueListenable: PushService.instance.permissionBlocked,
                  builder: (context, blocked, _) =>
                      blocked ? _permissionBanner() : const SizedBox.shrink(),
                ),
                Expanded(child: pages[_tab]),
              ],
            ),
          ),
          // 硬體模擬集中在社工後台的「硬體模擬」頁；家屬前台不顯示任何模擬按鈕。
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: active == Severity.emergency,
                  child: const Icon(Icons.home_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: active == Severity.emergency,
                  child: const Icon(Icons.home),
                ),
                label: '首頁',
              ),
              const NavigationDestination(
                  icon: Icon(Icons.bar_chart_outlined),
                  selectedIcon: Icon(Icons.bar_chart),
                  label: '統計'),
              const NavigationDestination(icon: Icon(Icons.alarm), label: '提醒'),
              const NavigationDestination(
                  icon: Icon(Icons.settings_outlined), label: '設定'),
            ],
          ),
        );
      },
    );
  }
}
