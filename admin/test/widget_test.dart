import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

import 'package:admin_dashboard/main.dart';

/// 測試用假認證：直接回傳一位已登入社工，讓後台離線渲染 dashboard。
class _FakeWorkerAuth implements AuthRepository {
  final _ctrl = StreamController<AuthUser?>.broadcast();
  static const _user = AuthUser(
      id: 'w1',
      name: '王淑芬',
      username: '0933-222-333',
      role: AuthRole.worker,
      token: 't');
  @override
  AuthUser? get currentUser => _user;
  @override
  Stream<AuthUser?> authStateChanges() => _ctrl.stream;
  @override
  Future<void> restore() async {}
  @override
  Future<AuthUser> signIn(
          {required String username, required String password}) async =>
      _user;
  @override
  Future<AuthUser> signUp(
          {required String username,
          required String password,
          required String name,
          required AuthRole role}) async =>
      _user;
  @override
  Future<void> signOut() async {}
  @override
  void dispose() => _ctrl.close();
}

void main() {
  testWidgets('社工後台：登入後顯示標題、匯出鍵與長輩即時狀態', (tester) async {
    // 拉高視窗高度讓長輩表建出來，但仍不到底部地圖（避免測試環境載圖磚）
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
        AdminApp(backend: MockBackend(), auth: _FakeWorkerAuth()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 標題在品牌視覺改版後拆成兩行：主標「社工後台」＋副標「金孫收音機派遣中心」。
    // 這裡兩行都驗，改名才不會又只有一半被抓到。
    expect(find.text('社工後台'), findsOneWidget);
    expect(find.textContaining('金孫收音機'), findsWidgets);
    expect(find.text('下載 Excel'), findsOneWidget);
    // 長輩即時狀態表（MockBackend seed 的三位）。
    // 個資保護預設開啟（_revealPii 預設 false），畫面上是 maskName 後的「林○春」，
    // 不是原名——這是刻意的隱私預設，測試要驗遮罩後的樣子才對。
    expect(find.textContaining('林○春'), findsWidgets);
    expect(find.textContaining('王○火'), findsWidgets);
    expect(find.textContaining('陳○蘭'), findsWidgets);
    // 反向確認：預設狀態下原名不該外洩到畫面上
    expect(find.textContaining('林阿春'), findsNothing);
    // 後台的三個關鍵控制項（長輩搜尋框已於後續改版移除，原本斷言 TextField 已失效）
    expect(find.textContaining('派遣監控'), findsOneWidget);
    expect(find.text('全部長輩'), findsOneWidget);
    expect(find.text('個資已保護'), findsOneWidget);
  });

  // 迴歸：SOS／疑似跌倒進來、20 秒升級還沒開派遣單的那一刻，長輩 severity 已非
  // normal 但 task 仍是 null。窄螢幕的 _compactRow 當時寫 `it.task!`，一到這一刻
  // 就整個 _DispatchMonitor 丟例外——release build 不會紅屏，而是換成一塊灰色的
  // ErrorWidget，社工那一刻剛好什麼都看不到。這是黃金時間的出口，不能再退化。
  testWidgets('派遣監控（窄螢幕）：事件已進來但派遣單還沒開，不可丟例外', (tester) async {
    // ListView 左右各 16 padding → _DispatchMonitor 的 maxWidth = 750-32 = 718 < 720，
    // 走 _compactRow。不取更窄的寬度是因為測試字型的中文字寬與實機不同，會先撞到
    // 頂部工具列的排版溢位，那個無關的例外會蓋掉我們要驗的這一個。
    tester.view.physicalSize = const Size(750, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final backend = MockBackend();
    await tester.pumpWidget(
        AdminApp(backend: backend, auth: _FakeWorkerAuth()));
    await tester.pump();

    // 疑似跌倒：只寫事件、把長輩轉 attention，20 秒後才會升級開單 → 現在 task 仍為 null。
    backend.triggerFallSuspected('elder-1');
    // _DispatchMonitor 掛在 tasks 串流上，而這一刻還沒有任何 task 變動，
    // 靠的是它自己每 10 秒的 ticker 重繪。等過那一拍（仍在 20 秒升級窗內）。
    await tester.pump(const Duration(seconds: 11));

    expect(tester.takeException(), isNull);
    // 確認窗的卡片真的有畫出來（不是靠「沒例外」矇混過關）
    expect(find.textContaining('狀況確認中'), findsWidgets);
  });
}
