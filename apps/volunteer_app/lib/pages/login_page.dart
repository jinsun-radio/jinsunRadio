import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController(text: '0921-000-111');
  final _password = TextEditingController(text: 'demo1234');
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth
          .signIn(username: _phone.text.trim(), password: _password.text);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Demo：以不同志工身分快速登入，示範「每位志工只看自己的長輩／任務」。
  static const _demoVolunteers = <(String, String)>[
    ('阿明', '0921-000-111'),
    ('秀蘭', '0921-222-333'),
    ('俊傑', '0921-444-555'),
    ('家豪', '0921-666-777'),
    ('淑惠', '0921-888-999'),
  ];

  Future<void> _loginAs(String name, String phone) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await widget.auth.signIn(username: phone, password: 'demo1234');
      } on AuthException {
        // demo 帳號還沒建立 → 直接以志工角色建立並登入。
        await widget.auth.signUp(
            username: phone,
            password: 'demo1234',
            name: name,
            role: AuthRole.volunteer);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RegisterScreen(auth: widget.auth)),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('註冊成功，已為你登入')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  const Center(child: JinsunLogoBadge()),
                  const SizedBox(height: 20),
                  const Text('金孫收音機',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: JinsunColors.ink)),
                  const SizedBox(height: 6),
                  const Text('志工端｜順路幫個忙，讓社區成為彼此的依靠',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13.5, color: JinsunColors.muted)),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: '手機號碼',
                        prefixIcon: Icon(Icons.phone_iphone)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    onSubmitted: (_) => _login(),
                    decoration: InputDecoration(
                      labelText: '密碼',
                      prefixIcon: const Icon(Icons.lock_outline),
                      errorText: _error,
                      suffixIcon: IconButton(
                        tooltip: _obscure ? '顯示密碼' : '隱藏密碼',
                        icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  JinsunGradientButton(
                    onPressed: _busy ? null : _login,
                    icon: _busy ? null : Icons.login,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white))
                        : const Text('登入'),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: _busy ? null : _register,
                    child: const Text('想成為志工？註冊',
                        style: TextStyle(color: JinsunColors.blueDeep)),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFEFEC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Demo：以不同志工身分登入（測試就近派單／來單受理）',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF52524E))),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final (name, phone) in _demoVolunteers)
                              ActionChip(
                                avatar: const Icon(Icons.person, size: 16),
                                label: Text('志工 $name'),
                                onPressed:
                                    _busy ? null : () => _loginAs(name, phone),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 註冊志工帳號（整頁，非彈窗）。欄位預設帶入 demo 帳號，一鍵即可註冊。
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // 預設帶入的示範帳號（與登入頁 demo 帳號不衝突，可直接註冊）
  final _name = TextEditingController(text: '陳志工');
  final _phone = TextEditingController(text: '0921-222-333');
  final _password = TextEditingController(text: 'demo1234');
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  /// 志工必須開啟定位才能被就近派單、隨移動更新 ETA、到場自動回報。
  /// 未授權（拒絕／服務關閉）回 false → 擋下註冊。
  Future<bool> _ensureLocationPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      return p == LocationPermission.whileInUse ||
          p == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // 定位是志工的必要條件——先強制取得權限，未授權就不給註冊。
    final locOk = await _ensureLocationPermission();
    if (!locOk) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '志工必須開啟定位權限才能註冊：就近派單、路線 ETA 與到場回報都需要你的位置。'
              '請在瀏覽器／系統設定允許定位後再試一次。';
        });
      }
      return;
    }
    try {
      await widget.auth.signUp(
        username: _phone.text.trim(),
        password: _password.text,
        name: _name.text.trim(),
        role: AuthRole.volunteer,
      );
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '註冊失敗，請檢查網路後再試一次');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('註冊志工帳號')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('建立你的志工帳號',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: JinsunColors.ink)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: JinsunColors.blueBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.my_location,
                            size: 18, color: JinsunColors.blueDeep),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '註冊需開啟定位權限——志工靠位置就近派單與到場回報，未開啟無法註冊。',
                            style: TextStyle(
                                fontSize: 12.5, color: JinsunColors.blueDeep),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                        labelText: '你的姓名',
                        prefixIcon: Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: '手機號碼',
                        prefixIcon: Icon(Icons.phone_iphone)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: '設定密碼',
                      prefixIcon: const Icon(Icons.lock_outline),
                      errorText: _error,
                      suffixIcon: IconButton(
                        tooltip: _obscure ? '顯示密碼' : '隱藏密碼',
                        icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white))
                        : const Text('註冊並登入'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
