import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import 'pages/history_page.dart';
import 'pages/login_page.dart';
import 'pages/profile_page.dart';
import 'pages/redemption_page.dart';
import 'pages/tasks_page.dart';
import 'services/dispatch_listener.dart';
import 'services/location_publisher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  // 後端由 --dart-define=BACKEND 決定（supabase 預設／aws 平行環境），見 JinsunBackends。
  await JinsunBackends.ensureInitialized();
  // 推播（FCM+APNs）：初始化在 runApp 前；token 註冊在登入後（見下方）。
  await PushService.instance.initialize();
  runApp(const VolunteerApp());
}

class VolunteerApp extends StatefulWidget {
  const VolunteerApp({super.key, this.backend, this.auth});

  // 可注入後端／認證（測試用 MockBackend）；正式版由 JinsunBackends 依建置參數決定。
  // 與 FamilyApp／AdminApp 對齊——沒有這個注入點，widget test 只能去連真 Supabase。
  final BackendClient? backend;
  final AuthRepository? auth;

  @override
  State<VolunteerApp> createState() => _VolunteerAppState();
}

class _VolunteerAppState extends State<VolunteerApp> {
  late final BackendClient backend;
  late final AuthRepository auth;
  StreamSubscription<AuthUser?>? _pushAuthSub;

  @override
  void initState() {
    super.initState();
    auth = widget.auth ?? JinsunBackends.createAuth(AuthRole.volunteer);
    backend = widget.backend ?? JinsunBackends.createBackend(auth);
    // 推播 token 要寫進「目前這一套」後端，不能寫死 Supabase。
    PushService.instance.backend = backend;
    // 推播 token 註冊：志工登入即註冊（訂閱 role_volunteer，收新派遣單廣播）。
    _pushAuthSub = auth.authStateChanges().listen((user) {
      if (user != null) {
        PushService.instance.registerForUser(user);
      } else {
        PushService.instance.unregister();
      }
    });
    auth.restore().then((_) async {
      final demo = Uri.base.queryParameters['demo'];
      if (demo != null && auth.currentUser == null) {
        await auth.signIn(username: '0921-000-111', password: 'demo1234');
      }
      if (demo == 'sos') {
        Timer(const Duration(seconds: 2), () => backend.triggerSos('elder-2'));
      } else if (demo == 'fall') {
        Timer(const Duration(seconds: 2),
            () => backend.triggerFallSuspected('elder-1'));
      }
    });
  }

  @override
  void dispose() {
    _pushAuthSub?.cancel();
    backend.dispose();
    auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '金孫收音機（志工端）',
      debugShowCheckedModeBanner: false,
      theme: jinsunTheme(JinsunColors.blue),
      home: StreamBuilder<AuthUser?>(
        stream: auth.authStateChanges(),
        initialData: auth.currentUser,
        builder: (context, snapshot) {
          if (snapshot.data == null) return LoginPage(auth: auth);
          // 外層掛來電監聽 + 來單受理監聽：家屬來電全螢幕響鈴；緊急派單/改派給我時
          // 全螢幕彈出「來單受理」（可按鈕或語音同意／拒絕）。
          final name = snapshot.data?.name ?? '志工';
          return CallListener(
            backend: backend,
            selfRole: CallRole.volunteer,
            selfName: name,
            accent: JinsunColors.blue,
            child: DispatchListener(
              backend: backend,
              volunteerName: name,
              child: VolunteerShell(backend: backend, auth: auth),
            ),
          );
        },
      ),
    );
  }
}

class VolunteerShell extends StatefulWidget {
  const VolunteerShell({super.key, required this.backend, required this.auth});

  final BackendClient backend;
  final AuthRepository auth;

  @override
  State<VolunteerShell> createState() => _VolunteerShellState();
}

class _VolunteerShellState extends State<VolunteerShell> {
  BackendClient get backend => widget.backend;
  LocationPublisher? _locator;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 志工有進行中任務時，即時回報定位供家屬地圖顯示（無任務不開 GPS）
    _locator = LocationPublisher(
      backend: backend,
      volunteerName: widget.auth.currentUser?.name ?? '志工',
      onLocationUnavailable: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 6),
        ));
      },
    );
    // 不再用底部彈出通知；新任務會即時出現在「接任務」列表。
  }

  @override
  void dispose() {
    _locator?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.auth.currentUser?.name ?? '志工';
    final pages = [
      TasksPage(backend: backend, volunteerName: name),
      HistoryPage(backend: backend, volunteerName: name),
      RedemptionPage(backend: backend, name: name),
      ProfilePage(backend: backend, auth: widget.auth, name: name),
    ];
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      // 硬體模擬集中在社工後台的「硬體模擬」頁；志工前台不顯示任何模擬按鈕。
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.assignment_outlined),
              selectedIcon: Icon(Icons.assignment),
              label: '任務'),
          NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: '紀錄'),
          NavigationDestination(
              icon: Icon(Icons.redeem_outlined),
              selectedIcon: Icon(Icons.redeem),
              label: '時數兌換'),
          NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的'),
        ],
      ),
    );
  }
}
