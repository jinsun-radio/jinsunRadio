import 'dart:convert';

import 'package:http/http.dart' as http;

/// 語音 server base URL。
/// 部署時以 `--dart-define=SIM_BASE=...` 注入；未指定時預設 Render 上的常駐 https 站
/// （必須是 https：家屬網頁走 https，呼叫 http 會被瀏覽器擋成 mixed content）。
const _simBase = String.fromEnvironment('SIM_BASE');
String get voiceServerBase => _simBase.isNotEmpty
    ? _simBase
    : 'https://jinsun-voice-server-mg1f.onrender.com';

/// 家屬手動按「立即提醒」：請雲端 server 把提醒語音下發到指定收音機。
///
/// server 端（POST /remind）會 enqueue 扇出：
///   ・MQTT publish → `jinsun/{serial}/cmd`（真收音機即時發聲）
///   ・長輪詢佇列    → 模擬器與長輩網頁（GET /commands）
/// 符合隱私邊界：只送「要念的文字」，沒有任何上行影音。成功回 true。
Future<bool> pushReminder({
  required String deviceSerial,
  required String text,
}) async {
  try {
    final res = await http
        .post(Uri.parse('$voiceServerBase/remind'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'device_serial': deviceSerial, 'text': text}))
        .timeout(const Duration(seconds: 20));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}
