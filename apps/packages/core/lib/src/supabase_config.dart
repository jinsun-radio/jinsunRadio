import 'package:supabase_flutter/supabase_flutter.dart';

/// 金孫收音機 Supabase 連線設定。
/// anon（publishable）金鑰為公開金鑰，可安全放前端；只用它讀資料與寫入
/// 授權範圍內的表。SECRET 金鑰只在後端／建表腳本使用，永不放這裡。
class JinsunSupabase {
  static const url = 'https://ykfxmoubynnbhnburawl.supabase.co';
  static const anonKey = 'sb_publishable_1252UHs0uFhEvQ_LSjXQdg_w-EIyPIG';

  static bool _inited = false;

  /// 在 runApp 之前呼叫一次。
  static Future<void> ensureInitialized() async {
    if (_inited) return;
    await Supabase.initialize(url: url, anonKey: anonKey);
    _inited = true;
  }

  static SupabaseClient get client => Supabase.instance.client;
}
