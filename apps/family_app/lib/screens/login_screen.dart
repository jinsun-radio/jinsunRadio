import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController(text: '0912-345-678');
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
      // 成功後 authStateChanges 會驅動 main 切換畫面
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RegisterScreen(auth: widget.auth)),
    );
    if (result == true && mounted) {
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
                  const Text('家屬端｜你無法近身守護的家人，我們替你默默守護',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13.5, color: JinsunColors.muted)),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: '手機號碼',
                      prefixIcon: Icon(Icons.phone_iphone),
                    ),
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
                    child: const Text('還沒有帳號？註冊',
                        style: TextStyle(color: JinsunColors.orangeDeep)),
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

/// 註冊家屬帳號（整頁，非彈窗）。欄位預設帶入 demo 帳號，一鍵即可註冊。
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // 預設帶入的示範帳號（與登入頁 demo 帳號不衝突，可直接註冊）
  final _name = TextEditingController(text: '王小明');
  final _phone = TextEditingController(text: '0900-123-456');
  final _password = TextEditingController(text: 'demo1234');
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.signUp(
        username: _phone.text.trim(),
        password: _password.text,
        name: _name.text.trim(),
        role: AuthRole.family,
      );
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // 網路等非 Auth 例外也要回饋，否則轉圈永遠停不下來
      if (mounted) setState(() => _error = '註冊失敗，請檢查網路後再試一次');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('註冊家屬帳號')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('建立你的家屬帳號',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: JinsunColors.ink)),
                  const SizedBox(height: 28),
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
