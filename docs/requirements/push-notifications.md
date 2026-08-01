# 推播通知（FCM + APNs）接入指南

家屬要即時收到「疑似跌倒／SOS」、志工要即時收到派遣單——**即使 App 沒開著**。
本文件說明推播的架構、已實作的程式碼，以及要讓它真正跑起來、你需要親自完成的外部設定。

對應架構總覽見 [`../architecture.md`](../architecture.md)「使用者端 / 推播是雙軌的」段落。

---

## 1. 架構：推播是雙軌的

| 軌道 | 何時 | 機制 | 現行實作 | 正式 AWS 對應 |
|---|---|---|---|---|
| 前景即時同步 | App 開著 | Supabase Realtime → App 內通知 | `SupabaseBackend`（已有） | AppSync / WebSocket |
| 背景系統推播 | App 在背景／關閉 | FCM（Android）＋ APNs（iOS） | `PushService` + Edge Function `send-push`（本次新增） | SNS Mobile Push / Pinpoint |

背景推播資料流：

```
長輩事件 / 派遣單狀態寫入 Supabase (radio_events, dispatch_tasks)
        │  INSERT / UPDATE
        ▼
Supabase Database Webhook  ── x-webhook-secret 驗證 ──▶  Edge Function: send-push
                                                              │  ① 依規則產生通知文案＋收件者
                                                              │  ② 查 device_tokens（角色 / 綁定長輩）
                                                              │  ③ OAuth2 service account 換 access token
                                                              ▼
                                                    FCM HTTP v1  ──┬── Android 直接送達
                                                                   └── iOS 經 APNs 送達
                                                              ▼
                                          App 端 firebase_messaging 收訊
                                            ├─ 前景：flutter_local_notifications 顯示
                                            └─ 背景：系統匣自動顯示（notification payload）
```

**隱私邊界**：推播只承載事件文字（跌倒/SOS/派遣單狀態），永遠不含原始影音，與架構約束 1 一致。

---

## 2. 已實作的程式碼（本次新增／修改）

| 位置 | 內容 |
|---|---|
| `apps/packages/core/lib/src/push_service.dart` | 三端共用 `PushService`：Firebase 初始化、要權限、取 FCM token、寫入 `device_tokens`、topic 訂閱、前景/背景/點擊訊息處理 |
| `apps/packages/core/pubspec.yaml` | 加 `firebase_core` / `firebase_messaging` / `flutter_local_notifications` |
| `apps/family_app/lib/main.dart` | `PushService.initialize()`；登入後 `registerForUser`（帶綁定長輩）、綁定變動同步 topic、登出解除 |
| `apps/volunteer_app/lib/main.dart` | 同上（志工訂閱 `role_volunteer`，收派遣單廣播） |
| `apps/*/android/{settings,app}/build.gradle.kts` | 套用 `com.google.gms.google-services` plugin |
| `apps/*/android/app/src/main/AndroidManifest.xml` | `POST_NOTIFICATIONS` 權限＋預設通知 channel `jinsun_alerts` |
| `apps/*/ios/Runner/Info.plist` | `UIBackgroundModes: remote-notification` |
| `cloud/supabase/schema.sql` | `device_tokens` 表＋RLS（token 綁使用者；service_role 繞過） |
| `cloud/supabase/functions/send-push/index.ts` | 推播發送 Edge Function（FCM HTTP v1 代理） |

**收件者規則**（`send-push` 內 `buildMessages`，沿用 App 內通知文案）：

| 事件 | 家屬（綁定該長輩） | 志工（`role_volunteer`） |
|---|---|---|
| SOS | ✅ 已派遣志工前往 | ✅ 請盡快支援 |
| 疑似跌倒（確認中） | ✅ 收音機確認中 | — |
| 跌倒無回應（升級） | ✅ 已派遣 | ✅ 請盡快支援 |
| 事件解除（我沒事） | ✅ | — |
| 新緊急／物資派遣單 | — | ✅ 待接單 |
| 志工接單／抵達／完成 | ✅ | — |

家屬只收「自己綁定長輩」的通知：token 上帶 `elder_ids`，`send-push` 用 `elder_ids @> [elderId]` 過濾。

---

## 3. 你要完成的外部設定

程式碼是骨架，以下帳號層設定無法代做（涉及你的 Firebase／Apple 帳號）。

### 3.1 Firebase 專案

1. 到 [Firebase Console](https://console.firebase.google.com/) 建一個專案（例如 `jinsun-radio`）。
2. 加入兩個 App（bundle id 已在 repo 設定好，直接對應）：
   - Android：`com.jinsunradio.family_app`、`com.jinsunradio.volunteer_app`
     → 各下載 `google-services.json`，分別放到
     `apps/family_app/android/app/google-services.json`、
     `apps/volunteer_app/android/app/google-services.json`
   - iOS：`com.jinsunradio.familyApp`、對應 volunteer 的 bundle id
     → 各下載 `GoogleService-Info.plist`，用 Xcode 拖進
     `ios/Runner/`（要勾選 target，讓它進 build，不要只放檔案）
3. 這些憑證檔**不要 commit**（`.gitignore` 建議加入）。

### 3.2 iOS APNs（需要 Apple Developer 帳號，US$99/年）

1. Apple Developer → Certificates, Identifiers & Profiles → Keys → 新增一把 **APNs Auth Key**（.p8），記下 Key ID 與 Team ID。
2. Firebase Console → 專案設定 → Cloud Messaging → Apple app → 上傳這把 APNs Key。
3. Xcode 開 `ios/Runner.xcworkspace`，Runner target → Signing & Capabilities：
   - 加 **Push Notifications**
   - 加 **Background Modes**，勾 **Remote notifications**
   （`Info.plist` 已有 `remote-notification`，capability 仍需在 Xcode 開）

> 沒有 Apple Developer 帳號時，iOS 推播無法測試；Android 可先獨立驗證。

### 3.3 FlutterFire（產生原生設定綁定）

建議用 CLI 一次設定好（會自動放置憑證與 `firebase_options.dart`）：

```bash
dart pub global activate flutterfire_cli
cd apps/family_app && flutterfire configure   # 選 Firebase 專案與 android/ios
cd ../volunteer_app && flutterfire configure
```

`PushService` 目前用 `Firebase.initializeApp()`（不帶 options），依賴原生
`google-services.json` / `GoogleService-Info.plist` 自動初始化，所以 `firebase_options.dart`
非必需；但用 `flutterfire configure` 是最不易出錯的路徑。

### 3.4 安裝依賴並建置

```bash
cd apps/packages/core && flutter pub get
cd ../../family_app   && flutter pub get && flutter build apk --debug
cd ../volunteer_app   && flutter pub get && flutter build apk --debug
```

---

## 4. Supabase 後端部署

```bash
cd cloud/supabase

# 1) 建 device_tokens 表（schema.sql 已含；套到遠端）
supabase db push --project-ref <ref>          # 或在 Studio SQL editor 貼上新增段落

# 2) 部署發送 Function
supabase functions deploy send-push --project-ref <ref>

# 3) 設定 secret（service account 來自 Firebase → 專案設定 → 服務帳戶 → 產生新的私密金鑰）
supabase secrets set \
  FCM_PROJECT_ID=<firebase-project-id> \
  FCM_CLIENT_EMAIL="$(jq -r .client_email sa.json)" \
  FCM_PRIVATE_KEY="$(jq -r .private_key sa.json)" \
  PUSH_WEBHOOK_SECRET=<自訂一組隨機字串> \
  --project-ref <ref>
```

### 資料庫 trigger（觸發 send-push）

**實際落地方式（2026-07-23）**：不用 Studio 的 Database Webhook（該功能首次啟用才會建立
`supabase_functions` schema，本專案沒有），改用 `pg_net` 自建 trigger，由 migration 管理：

- `cloud/supabase/migrations/20260723000001_device_tokens.sql` — `device_tokens` 表＋RLS
- `cloud/supabase/migrations/20260723000002_push_webhooks.sql` — `notify_send_push()` trigger function
  ＋ `radio_events`/`dispatch_tasks` 的 INSERT/UPDATE trigger（**含 webhook 密鑰，已 gitignore，不進版控**）

trigger 用 `net.http_post` 打 `send-push`，payload 對齊 Database Webhook 格式
`{type, table, schema, record, old_record}`（UPDATE 才帶 `old_record`，供判斷狀態是否真的變了），
並帶 `x-webhook-secret` header，與 `PUSH_WEBHOOK_SECRET` secret 同一把。

套用方式：`supabase db push`（migration 2 若要重產密鑰，改檔案內 header 值並同步
`supabase secrets set PUSH_WEBHOOK_SECRET=...` 即可）。

---

## 5. 測試

1. Android 實機安裝 debug apk，登入家屬帳號 → 首次啟動會跳通知權限。
2. 用社工後台的硬體模擬（`?sim=1`）或直接在 Supabase 對 `elder-1` insert 一筆 `radio_events(type='sos')`。
3. 把 App 切到背景 → 應收到系統通知「🆘 …按下 SOS…」。
4. 檢查 Function log：`supabase functions logs send-push --project-ref <ref>`（看 `sent` 數）。
5. 檢查 `device_tokens` 有無寫入該裝置 token。

常見問題：
- **收不到**：確認 `device_tokens` 有 token、Webhook header secret 一致、iOS 已開 capability 並上傳 APNs Key。
- **iOS 前景才收到、背景收不到**：多半是 APNs Key 或 Background Modes 未設。
- **token 一直變動／失效**：`send-push` 會在 FCM 回 404/400 時自動刪除死 token。

---

## 6. 待辦（正式化）

- RLS 目前 demo 全開；正式版 `device_tokens` 已收緊（只能管自己的 token），其餘表需按角色收緊。
- 點擊推播的深連結（`PushService.initialize(onTap:)`）目前只留 callback，尚未接各 App 導頁。
- 社工後台（Web）推播可另接 Web Push 或 email，本期未含。
- 正式遷移 AWS 時：`device_tokens` → SNS Platform Endpoints；`send-push` → Lambda（DynamoDB Streams 觸發）。
