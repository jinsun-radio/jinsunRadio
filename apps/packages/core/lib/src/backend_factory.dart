import 'package:flutter/foundation.dart';

import 'auth.dart';
import 'aws_backend.dart';
import 'aws_config.dart';
import 'backend_client.dart';
import 'cognito_auth.dart';
import 'supabase_auth.dart';
import 'supabase_backend.dart';
import 'supabase_config.dart';

/// 三端 App 的後端選擇點——**唯一一處**知道「現在跑在哪一套環境」的程式碼。
///
/// 兩套環境是同一份原始碼，靠建置參數 `--dart-define=BACKEND=aws|supabase` 切換
/// （見 aws_config.dart 與 deploy/aws/deploy-web.sh）。App 的 main.dart 只呼叫這裡，
/// 不 import 任何一邊的實作，換環境時 UI 一行都不用改。
class JinsunBackends {
  /// 啟動時的初始化。Supabase 需要先 initialize；AWS 那套是純 HTTPS，不需要。
  ///
  /// 刻意在 AWS 模式下**不初始化 Supabase**：初始化了就會有人不小心又直接用
  /// `JinsunSupabase.client`，兩套環境的資料就悄悄混在一起了。
  static Future<void> ensureInitialized() async {
    if (useAws) {
      debugPrint('[jinsun] 後端：${JinsunAws.describe()}');
      return;
    }
    await JinsunSupabase.ensureInitialized();
  }

  /// 設定齊全才真的走 AWS；缺參數就退回 Supabase 並吵一聲，
  /// 而不是連到一個空 URL 之後每 3 秒失敗一次還查不出原因。
  static bool get useAws {
    if (!JinsunAws.isAws) return false;
    if (JinsunAws.configured) return true;
    debugPrint('[jinsun] ⚠️ BACKEND=aws 但缺 AWS_API_BASE／COGNITO_CLIENT_ID，退回 Supabase');
    return false;
  }

  static AuthRepository createAuth(AuthRole role) =>
      useAws ? CognitoAuthRepository(role: role) : SupabaseAuthRepository(role: role);

  /// [auth] 必須是 [createAuth] 回傳的那一個——AWS 版的 backend 每次請求前
  /// 都要向它要一張沒過期的 id token。
  static BackendClient createBackend(AuthRepository auth,
      {bool dispatchWatchdog = false}) {
    if (!useAws) return SupabaseBackend(dispatchWatchdog: dispatchWatchdog);
    final cognito = auth as CognitoAuthRepository;
    return AwsBackend(
      idToken: cognito.freshIdToken,
      dispatchWatchdog: dispatchWatchdog,
    );
  }
}
