import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';

import 'package:volunteer_app/main.dart';

/// 測試用假認證：直接回傳一位已登入志工（阿明），讓志工端離線渲染任務頁。
/// 與 admin/test 的 _FakeWorkerAuth 同一套寫法。
class _FakeVolunteerAuth implements AuthRepository {
  final _ctrl = StreamController<AuthUser?>.broadcast();
  static const _user = AuthUser(
      id: 'v1',
      name: '阿明',
      username: '0921-000-111',
      role: AuthRole.volunteer,
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
  testWidgets('志工首頁：顯示問候、今日統計與接單狀態', (tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
        VolunteerApp(backend: MockBackend(), auth: _FakeVolunteerAuth()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('阿明'), findsWidgets);
    expect(find.text('今日完成'), findsOneWidget);
    expect(find.text('今日時數'), findsOneWidget);
    expect(find.text('接單狀態'), findsOneWidget);
    expect(find.text('目前任務'), findsOneWidget);
  });

  testWidgets('緊急派遣進來 → 出現待接單卡與接單鍵（黃金鏈路的志工端出口）',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final backend = MockBackend();
    await tester.pumpWidget(
        VolunteerApp(backend: backend, auth: _FakeVolunteerAuth()));
    await tester.pump();

    // 直接從後端觸發 SOS（不再依賴已移除的「模擬收音機」按鈕）
    backend.triggerSos('elder-2');
    await tester.pump(const Duration(milliseconds: 100));

    // 卡片標題＝具體事件（SOS／跌倒），不再是籠統「緊急派遣」（見 TaskCard._concreteTitle）。
    expect(find.text('SOS 緊急求救'), findsWidgets);
    expect(find.text('待接單'), findsWidgets);
    // 接單鍵文案帶 ETA，且分兩種：搶單池是「接單（約 N 分鐘到）」，
    // 督導受邀單是「確認前往（約 N 分鐘到）」。比對共同的尾段，才不會被
    // 分鐘數或哪一種派單方式綁死。
    expect(find.textContaining('分鐘到）'), findsWidgets);
  });
}
