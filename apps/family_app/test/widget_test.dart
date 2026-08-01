import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import 'package:family_app/app_local.dart';
import 'package:family_app/screens/home_page.dart';

/// 測試用假認證：不碰 Supabase／SharedPreferences，讓家屬首頁能離線渲染。
class _FakeAuth implements AuthRepository {
  final _ctrl = StreamController<AuthUser?>.broadcast();
  @override
  AuthUser? get currentUser => null;
  @override
  Stream<AuthUser?> authStateChanges() => _ctrl.stream;
  @override
  Future<void> restore() async {}
  @override
  Future<AuthUser> signIn(
          {required String username, required String password}) async =>
      throw UnimplementedError();
  @override
  Future<AuthUser> signUp(
          {required String username,
          required String password,
          required String name,
          required AuthRole role}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut() async {}
  @override
  void dispose() => _ctrl.close();
}

Widget _wrapHome(AppLocal local) => MaterialApp(
      theme: jinsunTheme(JinsunColors.orange),
      home: Scaffold(body: HomePage(local: local)),
    );

void main() {
  testWidgets('家屬首頁：正常狀態顯示長輩「今天一切安好」，無緊急橫幅', (tester) async {
    final backend = MockBackend();
    final local = AppLocal(backend, _FakeAuth());
    local.boundIds.add('elder-1'); // 直接綁定，跳過 Supabase family_bindings

    await tester.pumpWidget(_wrapHome(local));
    await tester.pump();

    expect(find.textContaining('林阿春'), findsWidgets);
    expect(find.text('今天一切安好'), findsOneWidget);
    expect(find.text('偵測到緊急狀況'), findsNothing);

    local.dispose();
    backend.dispose();
  });

  testWidgets('家屬首頁：SOS 後置頂顯示緊急告警橫幅與撥打鍵', (tester) async {
    final backend = MockBackend();
    final local = AppLocal(backend, _FakeAuth());
    local.boundIds.add('elder-1');

    await tester.pumpWidget(_wrapHome(local));
    await tester.pump();
    // 橫幅文案在 0b45f62 改成動態句（帶長輩名字），舊的固定字串「偵測到緊急狀況」已不存在。
    // 現行為：未派到人＝「偵測到 X 異常，AI 確認中…」；已派＝「X 需要協助，志工前往中」。
    expect(find.textContaining('需要協助'), findsNothing);

    backend.triggerSos('elder-1'); // 長輩按 SOS → severity 變 emergency
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 置頂緊急橫幅出現，且聯絡長輩的入口在（林阿春 seed 有電話 → 可撥）。
    // 原本斷言的「立即撥打」已於 0b45f62「撥打長輩不再重複」整併成「聯絡 X」三合一入口
    // （撥打／訊息／視訊同一顆），所以改驗整併後的入口。
    expect(find.textContaining('需要協助'), findsWidgets);
    expect(find.textContaining('聯絡 林阿春'), findsWidgets);

    local.dispose();
    backend.dispose();
  });
}
