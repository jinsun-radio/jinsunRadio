import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'auth.dart';
import 'supabase_config.dart';

/// 真帳號系統：Supabase Auth。與 [LocalAuthRepository] 同介面（[AuthRepository]），
/// App 換掉不需改 UI。手機號碼在內部映射成 `{digits}@jinsun.local` 當 email。
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository({this.role});

  final AuthRole? role;
  final sb.SupabaseClient _sb = JinsunSupabase.client;
  final _ctrl = StreamController<AuthUser?>.broadcast();
  AuthUser? _current;

  static String _emailOf(String username) {
    final digits = username.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
    return username.contains('@') ? username : '$digits@jinsun.local';
  }

  @override
  AuthUser? get currentUser => _current;

  @override
  Stream<AuthUser?> authStateChanges() => _ctrl.stream;

  AuthUser? _fromSession(sb.Session? session) {
    final u = session?.user;
    if (u == null) return null;
    final meta = u.userMetadata ?? {};
    final roleName = (meta['role'] ?? role?.name ?? 'family') as String;
    return AuthUser(
      id: u.id,
      name: (meta['name'] ?? u.email?.split('@').first ?? '') as String,
      username: (meta['phone'] ?? u.email ?? '') as String,
      role: AuthRole.values.byName(roleName),
      token: session?.accessToken ?? '',
    );
  }

  @override
  Future<void> restore() async {
    _sb.auth.onAuthStateChange.listen((data) {
      _current = _fromSession(data.session);
      _ctrl.add(_current);
    });
    _current = _fromSession(_sb.auth.currentSession);
    _ctrl.add(_current);
  }

  @override
  Future<AuthUser> signIn(
      {required String username, required String password}) async {
    try {
      final res = await _sb.auth.signInWithPassword(
          email: _emailOf(username), password: password);
      _current = _fromSession(res.session);
      _ctrl.add(_current);
      return _current!;
    } on sb.AuthException catch (e) {
      throw AuthException(_friendly(e.message));
    }
  }

  @override
  Future<AuthUser> signUp({
    required String username,
    required String password,
    required String name,
    required AuthRole role,
  }) async {
    if (username.trim().isEmpty || password.isEmpty || name.trim().isEmpty) {
      throw AuthException('請完整填寫姓名、帳號與密碼');
    }
    try {
      final res = await _sb.auth.signUp(
        email: _emailOf(username),
        password: password,
        data: {'name': name.trim(), 'role': role.name, 'phone': username.trim()},
      );
      _current = _fromSession(res.session);
      _ctrl.add(_current);
      if (_current == null) throw AuthException('註冊成功，請登入');
      return _current!;
    } on sb.AuthException catch (e) {
      throw AuthException(_friendly(e.message));
    }
  }

  @override
  Future<void> signOut() async {
    await _sb.auth.signOut();
    _current = null;
    _ctrl.add(null);
  }

  String _friendly(String m) {
    final s = m.toLowerCase();
    if (s.contains('invalid') && s.contains('credential')) return '帳號或密碼錯誤';
    if (s.contains('already registered')) return '這個帳號已經註冊過了';
    return m;
  }

  void dispose() => _ctrl.close();
}
