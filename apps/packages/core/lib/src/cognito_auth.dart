import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart';
import 'aws_config.dart';

/// Amazon Cognito 版的帳號系統。與 [SupabaseAuthRepository] 同介面（[AuthRepository]），
/// 三端 App 換過來不必改任何 UI。
///
/// 直接打 Cognito 的 JSON API（`AWSCognitoIdentityProviderService.*`），沒有用 Amplify：
/// 這裡只需要「帳密換 token」與「refresh」兩件事，Amplify 會為此帶進一整套 plugin
/// 與各平台原生設定檔，對一個要同時跑 Web／Android／iOS 的 demo 是淨負擔。
///
/// 帳號沿用原環境的映射：手機號碼 → `{數字}@jinsun.local`（見 supabase_auth.dart），
/// 兩套環境的帳號長得一樣，demo 時不會拿錯帳號。
///
/// 角色以 **Cognito Group** 為準（token 裡的 `cognito:groups`），不是使用者自填的屬性——
/// 自訂屬性使用者自己就能改，拿它當授權依據等於沒有授權（後端 authz.mjs 同樣只認 group）。
class CognitoAuthRepository implements AuthRepository {
  CognitoAuthRepository({this.role, http.Client? client})
      : _http = client ?? http.Client();

  /// 若指定，signUp 預設角色、登入頁不需選角色（單一角色 App）。
  final AuthRole? role;
  final http.Client _http;

  static const _kSession = 'jinsun_cognito_session_v1';

  final _ctrl = StreamController<AuthUser?>.broadcast();
  AuthUser? _current;
  String? _refreshToken;
  String? _idToken;
  DateTime? _expiresAt;
  SharedPreferences? _prefs;

  @override
  AuthUser? get currentUser => _current;

  @override
  Stream<AuthUser?> authStateChanges() => _ctrl.stream;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  static String emailOf(String username) {
    if (username.contains('@')) return username.trim();
    final digits = username.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
    return '$digits@jinsun.local';
  }

  // ---------- Cognito JSON API ----------

  Future<Map<String, dynamic>> _call(String action, Map<String, dynamic> body) async {
    final res = await _http.post(
      Uri.parse(JinsunAws.idpEndpoint),
      headers: {
        'content-type': 'application/x-amz-json-1.1',
        'x-amz-target': 'AWSCognitoIdentityProviderService.$action',
      },
      body: jsonEncode(body),
    );
    final decoded = res.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw AuthException(_friendly(
        (decoded['__type'] ?? '') as String,
        (decoded['message'] ?? res.body) as String,
      ));
    }
    return decoded;
  }

  /// Cognito 的錯誤型別 → 使用者看得懂的話。原文是英文技術訊息，長輩家屬看不懂。
  String _friendly(String type, String message) {
    if (type.contains('NotAuthorized')) return '帳號或密碼錯誤';
    if (type.contains('UserNotFound')) return '帳號或密碼錯誤';
    if (type.contains('UsernameExists')) return '這個帳號已經註冊過了';
    if (type.contains('InvalidPassword')) return '密碼至少 8 個字';
    if (type.contains('InvalidParameter')) return '帳號或密碼格式不正確';
    if (type.contains('TooManyRequests') || type.contains('LimitExceeded')) {
      return '嘗試次數太多，請稍後再試';
    }
    return message;
  }

  // ---------- session ----------

  /// JWT payload（不驗簽——簽章由 API Gateway 的 authorizer 驗，
  /// 這裡只是要把顯示名與角色讀出來給 UI 用）。
  static Map<String, dynamic> _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return {};
    var p = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    p = p.padRight((p.length + 3) ~/ 4 * 4, '=');
    try {
      return jsonDecode(utf8.decode(base64.decode(p))) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  AuthRole _roleFrom(Map<String, dynamic> claims) {
    final raw = claims['cognito:groups'];
    final groups = raw is List ? raw.cast<String>() : <String>[];
    if (groups.contains('worker')) return AuthRole.worker;
    if (groups.contains('volunteer')) return AuthRole.volunteer;
    if (groups.contains('family')) return AuthRole.family;
    // 沒有 group＝後端會一律拒絕。這裡退回 App 自己的角色只為了讓 UI 有東西顯示，
    // 不影響授權（授權在 jinsun-data，看的是 token 裡的 group）。
    return role ?? AuthRole.family;
  }

  Future<AuthUser> _establish(Map<String, dynamic> authResult) async {
    final id = authResult['IdToken'] as String?;
    if (id == null) throw AuthException('登入失敗：Cognito 沒有回傳 token');
    _idToken = id;
    _refreshToken = (authResult['RefreshToken'] as String?) ?? _refreshToken;
    final expiresIn = (authResult['ExpiresIn'] as num?)?.toInt() ?? 3600;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

    final c = _claims(id);
    final user = AuthUser(
      id: (c['sub'] ?? '') as String,
      name: (c['name'] ?? (c['email'] as String?)?.split('@').first ?? '') as String,
      username: (c['phone_number'] ?? c['email'] ?? '') as String,
      role: _roleFrom(c),
      token: id,
    );
    final p = await _p;
    await p.setString(_kSession, jsonEncode({
      'refresh': _refreshToken,
      'id': _idToken,
      'exp': _expiresAt!.toIso8601String(),
    }));
    _current = user;
    _ctrl.add(user);
    return user;
  }

  @override
  Future<void> restore() async {
    final p = await _p;
    final raw = p.getString(_kSession);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _refreshToken = j['refresh'] as String?;
        _idToken = j['id'] as String?;
        _expiresAt = DateTime.tryParse((j['exp'] ?? '') as String);
        if (_idToken != null) {
          final c = _claims(_idToken!);
          _current = AuthUser(
            id: (c['sub'] ?? '') as String,
            name: (c['name'] ?? '') as String,
            username: (c['phone_number'] ?? c['email'] ?? '') as String,
            role: _roleFrom(c),
            token: _idToken!,
          );
        }
        // 冷啟動時 token 多半已過期（id token 只有 60 分鐘）→ 先換一張再放行，
        // 否則使用者會看到已登入的畫面、但每一個請求都 401。
        await freshIdToken();
      } catch (_) {
        await signOut();
        return;
      }
    }
    _ctrl.add(_current);
  }

  /// 取一張還沒過期的 id token（提前 2 分鐘換）。給 [AwsBackend] 每次請求前呼叫。
  /// 換不到（refresh token 也失效）就登出並回 null，讓 UI 回到登入頁。
  Future<String?> freshIdToken() async {
    if (_idToken != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!.subtract(const Duration(minutes: 2)))) {
      return _idToken;
    }
    if (_refreshToken == null) return null;
    try {
      final r = await _call('InitiateAuth', {
        'AuthFlow': 'REFRESH_TOKEN_AUTH',
        'ClientId': JinsunAws.cognitoClientId,
        'AuthParameters': {'REFRESH_TOKEN': _refreshToken},
      });
      final result = r['AuthenticationResult'] as Map<String, dynamic>?;
      if (result == null) return null;
      await _establish(result);
      return _idToken;
    } on AuthException {
      await signOut();
      return null;
    }
  }

  // ---------- AuthRepository ----------

  @override
  Future<AuthUser> signIn(
      {required String username, required String password}) async {
    final r = await _call('InitiateAuth', {
      'AuthFlow': 'USER_PASSWORD_AUTH',
      'ClientId': JinsunAws.cognitoClientId,
      'AuthParameters': {
        'USERNAME': emailOf(username),
        'PASSWORD': password,
      },
    });
    final result = r['AuthenticationResult'] as Map<String, dynamic>?;
    if (result == null) {
      // 例如 NEW_PASSWORD_REQUIRED（管理者建帳號時沒有 --permanent）
      throw AuthException('這個帳號需要由管理者重設密碼後才能登入');
    }
    return _establish(result);
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
    final email = emailOf(username);
    await _call('SignUp', {
      'ClientId': JinsunAws.cognitoClientId,
      'Username': email,
      'Password': password,
      'UserAttributes': [
        {'Name': 'email', 'Value': email},
        {'Name': 'name', 'Value': name.trim()},
        // 只是「申請」的角色；真正生效與否由 jinsun-auth 決定
        // （worker 不接受自助註冊，會被退回 family）。
        {'Name': 'custom:role', 'Value': role.name},
      ],
    });
    // PreSignUp 觸發器已自動確認帳號 → 直接登入，維持與原環境相同的註冊流程
    //（三端沒有「輸入驗證碼」畫面）。
    return signIn(username: username, password: password);
  }

  @override
  Future<void> signOut() async {
    final p = await _p;
    await p.remove(_kSession);
    _idToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _current = null;
    _ctrl.add(null);
  }

  @override
  void dispose() => _ctrl.close();
}
