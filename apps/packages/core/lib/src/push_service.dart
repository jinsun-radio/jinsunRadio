import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'auth.dart';
import 'backend_client.dart';

/// 背景／App 被殺時收到推播的處理器。必須是頂層函式並標註 vm:entry-point，
/// 否則 release build 會被 tree-shaking 移除。這裡只做輕量處理（系統匣通知由
/// FCM 依 notification payload 自動顯示），不碰 UI。
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // 背景 isolate 需要自己初始化 Firebase（原生 google-services.json /
  // GoogleService-Info.plist 提供設定，因此不必帶 options）。
  await Firebase.initializeApp();
  // data-only 訊息若要在背景顯示，可在此用 flutter_local_notifications 補顯示。
  // 目前 send-push Edge Function 一律帶 notification payload，系統會自動顯示。
}

/// 推播被點擊時回呼（帶 data payload），App 端可據此深連結到對應畫面。
typedef PushTapHandler = void Function(Map<String, dynamic> data);

/// 金孫收音機推播服務（FCM + APNs）。三端共用。
///
/// 隱私邊界：推播只承載「事件通知」（跌倒/SOS/派遣單狀態），永遠不含原始影音。
/// 這條線與裝置端本地推論的約束一致（見 docs/architecture.md）。
///
/// 使用方式：
///   1. main() 內 `await PushService.instance.initialize();`（在 runApp 前）
///   2. 使用者登入後 `await PushService.instance.registerForUser(user, elderIds: [...]);`
///   3. 登出時 `await PushService.instance.unregister();`
///
/// 前置需求（見 docs/requirements/push-notifications.md）：
///   - Android：android/app/google-services.json + google-services Gradle plugin
///   - iOS：GoogleService-Info.plist + APNs Key、Push Notifications capability
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _channelId = 'jinsun_alerts';
  static const _channelName = '金孫收音機通知';
  static const _channelDesc = '長輩事件與派遣單即時通知';

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;
  bool _enabled = false; // Firebase 設定齊全且初始化成功才為 true
  PushTapHandler? _onTap;
  // 點擊推播的資料流：讓 UI 層（如 CallListener）自行訂閱處理特定 kind。
  // 冷啟動時點通知會早於 UI 掛載，先存 _pendingTap 待首個消費者取走。
  final StreamController<Map<String, dynamic>> _tapCtrl =
      StreamController.broadcast();
  Map<String, dynamic>? _pendingTap;
  StreamSubscription<String>? _tokenRefreshSub;
  AuthUser? _user;

  /// device_tokens 要寫進哪一套後端。App 啟動時指定（見 JinsunBackends）。
  /// 沒指定就只做本機的 FCM topic 訂閱、不落地 token——這比硬寫進某一家後端好，
  /// 否則 AWS 環境的 App 會把 token 偷偷寫進正式環境的 Supabase。
  BackendClient? backend;
  List<String> _topics = const [];
  // 最新的綁定長輩清單。registerForUser 等權限對話框期間 updateElderIds 可能先到，
  // 一律以此欄位為準，避免舊參數把新值蓋回去。
  List<String> _elderIds = const [];

  /// 通知權限是否被拒。家屬端據此顯示「可能收不到緊急通知」的明顯提醒——
  /// 安心產品最忌諱權限被關卻靜默失效、家屬全盲而不自知。
  final ValueNotifier<bool> permissionBlocked = ValueNotifier<bool>(false);

  /// 使用者「點擊推播」的資料流（data payload）。
  Stream<Map<String, dynamic>> get taps => _tapCtrl.stream;

  /// 取走冷啟動期間累積的最後一次點擊（消費一次即清空）。
  Map<String, dynamic>? takePendingTap() {
    final t = _pendingTap;
    _pendingTap = null;
    return t;
  }

  void _dispatchTap(Map<String, dynamic> data) {
    _pendingTap = data;
    _tapCtrl.add(data);
    _onTap?.call(data);
  }

  /// 在 runApp 之前呼叫一次。冪等。
  /// [onTap] 於使用者點擊推播開啟 App 時觸發（可用於導頁）。
  Future<void> initialize({PushTapHandler? onTap}) async {
    _onTap = onTap;
    if (_inited) return;

    // Web 端（demo 用）不接 FCM，直接略過。
    if (kIsWeb) {
      _inited = true;
      return;
    }

    // 沒有 Firebase 設定檔（google-services.json / GoogleService-Info.plist）時，
    // 初始化會失敗——視為「推播尚未設定」，靜默略過，App 其餘功能照常運作。
    // 之後放入設定檔即自動啟用，無需改動程式碼。
    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('[push] Firebase 尚未設定，略過推播：$e');
      _inited = true;
      return;
    }
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    // Android 高優先權通知 channel（緊急事件要能出現在鎖定畫面／橫幅）。
    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null && payload.isNotEmpty) {
          _dispatchTap(_decodePayload(payload));
        }
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ));

    // 前景收到訊息時自己畫一則本地通知（iOS 亦讓系統在前景顯示橫幅）。
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    FirebaseMessaging.onMessage.listen(_showForeground);

    // 由推播點擊喚醒／開啟 App。
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _dispatchTap(m.data));
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _dispatchTap(initial.data);

    _inited = true;
    _enabled = true;
  }

  /// 使用者登入後呼叫：要權限、取 token、寫入 Supabase、訂閱對應 topic。
  /// [elderIds]：家屬綁定的長輩清單（只收這些長輩的事件通知）。志工／志工可留空。
  Future<void> registerForUser(AuthUser user,
      {List<String> elderIds = const []}) async {
    if (!_enabled) return;
    _user = user;
    _elderIds = elderIds;

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[push] 使用者拒絕通知權限');
      permissionBlocked.value = true; // UI 顯示提醒，不再靜默失敗
      return;
    }
    permissionBlocked.value = false; // 已授權（或臨時授權）→ 清除提醒

    final token = await messaging.getToken();
    if (token != null) await _upsertToken(user, token, _elderIds);

    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = messaging.onTokenRefresh
        .listen((t) => _upsertToken(user, t, _elderIds));

    // Topic 訂閱：角色廣播（志工新派遣單）＋各綁定長輩（家屬）。
    await _subscribeTopics(user, _elderIds);
  }

  /// 登出／解除綁定時呼叫：退訂 topic 並刪除本裝置 token。
  Future<void> unregister() async {
    if (!_enabled) return;
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    for (final t in _topics) {
      await FirebaseMessaging.instance.unsubscribeFromTopic(t);
    }
    _topics = const [];
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await backend?.unregisterDeviceToken(token);
    } catch (e) {
      debugPrint('[push] 刪除 token 失敗：$e');
    }
    _user = null;
    _elderIds = const [];
  }

  /// 家屬綁定的長輩清單變動時，重新同步 topic 與 token 上的 elder_ids。
  Future<void> updateElderIds(List<String> elderIds) async {
    final user = _user;
    if (user == null) return;
    _elderIds = elderIds;
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _upsertToken(user, token, _elderIds);
    await _subscribeTopics(user, _elderIds);
  }

  // ---- 內部 ----

  Future<void> _upsertToken(
      AuthUser user, String token, List<String> elderIds) async {
    try {
      await backend?.registerDeviceToken(
        token: token,
        role: user.role.name,
        platform: _platformName,
        elderIds: elderIds,
      );
    } catch (e) {
      debugPrint('[push] 寫入 device_tokens 失敗：$e');
    }
  }

  Future<void> _subscribeTopics(AuthUser user, List<String> elderIds) async {
    final messaging = FirebaseMessaging.instance;
    // 先退訂舊 topic，避免綁定變動後殘留。
    for (final t in _topics) {
      await messaging.unsubscribeFromTopic(t);
    }
    final next = <String>{
      'role_${user.role.name}',
      for (final id in elderIds) 'elder_$id',
    }.toList();
    for (final t in next) {
      await messaging.subscribeToTopic(t);
    }
    _topics = next;
  }

  void _showForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return; // data-only 訊息不在前景硬跳
    // 來電在前景由 CallListener（realtime）直接彈全螢幕，不再重複跳橫幅。
    if (message.data['kind'] == 'call') return;
    _local.show(
      n.hashCode,
      n.title,
      n.body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: _encodePayload(message.data),
    );
  }

  String get _platformName {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'other';
    }
  }

  // payload 以簡單 k=v;k=v 編碼（避免額外 json 依賴；值不含 ; 與 =）。
  String _encodePayload(Map<String, dynamic> data) =>
      data.entries.map((e) => '${e.key}=${e.value}').join(';');

  Map<String, dynamic> _decodePayload(String raw) {
    final out = <String, dynamic>{};
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i > 0) out[part.substring(0, i)] = part.substring(i + 1);
    }
    return out;
  }
}
