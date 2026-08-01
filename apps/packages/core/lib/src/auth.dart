import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum AuthRole { family, volunteer, worker }

String authRoleLabel(AuthRole r) => switch (r) {
      AuthRole.family => '家屬',
      AuthRole.volunteer => '志工',
      AuthRole.worker => '志工',
    };

class AuthUser {
  const AuthUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.token,
  });

  final String id;
  final String name;
  final String username; // 手機號碼或 email
  final AuthRole role;
  final String token; // session token（正式版為 Cognito idToken/JWT）

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'username': username,
        'role': role.name,
        'token': token,
      };

  static AuthUser fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id'] as String,
        name: j['name'] as String,
        username: j['username'] as String,
        role: AuthRole.values.byName(j['role'] as String),
        token: j['token'] as String,
      );
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 認證介面。目前實作為 [LocalAuthRepository]（帳號持久化於裝置，
/// session 存 SharedPreferences）；正式版換成打 Amazon Cognito 的
/// CognitoAuthRepository，同介面、UI 不需改動。
abstract class AuthRepository {
  Stream<AuthUser?> authStateChanges();
  AuthUser? get currentUser;

  Future<void> restore(); // 啟動時還原已登入的 session
  Future<AuthUser> signIn(
      {required String username, required String password});
  Future<AuthUser> signUp({
    required String username,
    required String password,
    required String name,
    required AuthRole role,
  });
  Future<void> signOut();
  void dispose();
}

class LocalAuthRepository implements AuthRepository {
  LocalAuthRepository({this.role});

  /// 若指定，signUp 預設角色、登入頁不需選角色（單一角色 App）
  final AuthRole? role;

  static const _kAccounts = 'jinsun_accounts_v1';
  static const _kSession = 'jinsun_session_v1';

  final _ctrl = StreamController<AuthUser?>.broadcast();
  AuthUser? _current;
  SharedPreferences? _prefs;

  @override
  AuthUser? get currentUser => _current;

  @override
  Stream<AuthUser?> authStateChanges() => _ctrl.stream;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<void> restore() async {
    final p = await _p;
    await _seedIfEmpty(p);
    final raw = p.getString(_kSession);
    if (raw != null) {
      try {
        _current = AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    _ctrl.add(_current);
  }

  Future<void> _seedIfEmpty(SharedPreferences p) async {
    if (p.getString(_kAccounts) != null) return;
    // 預設帳號（demo），密碼一律 demo1234
    final seed = [
      _acct('u-fam', '0912-345-678', 'demo1234', '陳怡君', AuthRole.family),
      _acct('u-vol', '0921-000-111', 'demo1234', '阿明', AuthRole.volunteer),
      _acct('u-wrk', '0933-222-333', 'demo1234', '王淑芬', AuthRole.worker),
    ];
    await p.setString(_kAccounts, jsonEncode(seed));
  }

  Map<String, dynamic> _acct(String id, String username, String password,
          String name, AuthRole role) =>
      {
        'id': id,
        'username': username,
        'password': password,
        'name': name,
        'role': role.name,
      };

  Future<List<Map<String, dynamic>>> _accounts(SharedPreferences p) async {
    final raw = p.getString(_kAccounts);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<AuthUser> signIn(
      {required String username, required String password}) async {
    final p = await _p;
    await _seedIfEmpty(p);
    final u = username.trim();
    final accts = await _accounts(p);
    final match = accts.where((a) =>
        a['username'] == u &&
        a['password'] == password &&
        (role == null || a['role'] == role!.name));
    if (match.isEmpty) {
      throw AuthException('帳號或密碼錯誤');
    }
    return _establish(p, match.first);
  }

  @override
  Future<AuthUser> signUp({
    required String username,
    required String password,
    required String name,
    required AuthRole role,
  }) async {
    final p = await _p;
    await _seedIfEmpty(p);
    final u = username.trim();
    if (u.isEmpty || password.isEmpty || name.trim().isEmpty) {
      throw AuthException('請完整填寫姓名、帳號與密碼');
    }
    final accts = await _accounts(p);
    if (accts.any((a) => a['username'] == u)) {
      throw AuthException('這個帳號已經註冊過了');
    }
    final acct = _acct('u-${DateTime.fromMillisecondsSinceEpoch(0).hashCode}'
        '${accts.length}', u, password, name.trim(), role);
    accts.add(acct);
    await p.setString(_kAccounts, jsonEncode(accts));
    return _establish(p, acct);
  }

  Future<AuthUser> _establish(
      SharedPreferences p, Map<String, dynamic> acct) async {
    final user = AuthUser(
      id: acct['id'] as String,
      name: acct['name'] as String,
      username: acct['username'] as String,
      role: AuthRole.values.byName(acct['role'] as String),
      token: 'local-${acct['id']}-${acct['username']}',
    );
    await p.setString(_kSession, jsonEncode(user.toJson()));
    _current = user;
    _ctrl.add(user);
    return user;
  }

  @override
  Future<void> signOut() async {
    final p = await _p;
    await p.remove(_kSession);
    _current = null;
    _ctrl.add(null);
  }

  void dispose() => _ctrl.close();
}
