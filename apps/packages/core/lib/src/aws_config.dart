/// AWS 平行環境的連線設定。
///
/// 全部由 `--dart-define` 注入，**不寫死在原始碼裡**——兩套環境（Render+Supabase／AWS）
/// 是同一份程式碼，靠建置參數決定連哪一套。部署指令見 deploy/aws/deploy-web.sh。
///
/// ```
/// flutter build web \
///   --dart-define=BACKEND=aws \
///   --dart-define=AWS_API_BASE=https://xxxx.execute-api.us-west-2.amazonaws.com \
///   --dart-define=AWS_REGION=us-west-2 \
///   --dart-define=COGNITO_CLIENT_ID=xxxx
/// ```
class JinsunAws {
  /// `aws` 或 `supabase`（預設）。決定 App 啟動時要建哪一組 backend/auth。
  static const backend =
      String.fromEnvironment('BACKEND', defaultValue: 'supabase');

  static bool get isAws => backend.toLowerCase() == 'aws';

  /// API Gateway 的 base url（同時提供 /voice 與 /data/*）。
  static const apiBase = String.fromEnvironment('AWS_API_BASE');

  static const region =
      String.fromEnvironment('AWS_REGION', defaultValue: 'us-west-2');

  /// Cognito User Pool 的 App Client id（公開客戶端，無 secret）。
  static const cognitoClientId = String.fromEnvironment('COGNITO_CLIENT_ID');

  /// 輪詢間隔。黃金窗是 20 秒，3 秒的偵測延遲綽綽有餘；
  /// 真正省成本的是 /data/version——指紋沒變就不抓快照。
  static const pollSeconds =
      int.fromEnvironment('AWS_POLL_SECONDS', defaultValue: 3);

  /// 設定齊全才算可用；缺任何一項就讓呼叫端退回 Supabase，而不是連到一個空 URL 後
  /// 每 3 秒噴一次錯誤還查不出原因。
  static bool get configured =>
      apiBase.isNotEmpty && cognitoClientId.isNotEmpty;

  static String get idpEndpoint => 'https://cognito-idp.$region.amazonaws.com/';

  static String describe() => isAws
      ? 'AWS（api=$apiBase, region=$region, poll=${pollSeconds}s）'
      : 'Supabase';
}
