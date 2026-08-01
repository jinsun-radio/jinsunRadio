# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案概要

金孫收音機（jinsun-radio）：給獨居與失能長者的近端 AI 陪伴與社區互助派遣系統。長輩端是一台零學習成本的收音機（跌倒偵測相機＋麥克風＋TTS＋SOS 按鈕），事件經雲端狀態機分級後，即時推播給家屬 App、志工 App 與社工後台，媒合志工到場，形成「感知 → 決策 → 行動 → 回報」閉環。2026 AI 創新獎參賽提案。

目前進度：Phase 1 閉環已實作（spec 見 `docs/requirements/phase1-mvp.md`）——`jinsun_core` 狀態機＋三端 UI 可跑、有測試，資料層已接 Supabase 真後端（三端共用、即時同步；`MockBackend` 保留作 demo 模擬）。`cloud/prototype/` 語音多 Agent server 已建（見 `docs/requirements/voice-agent-server.md`）。`firmware/` 已有 HUB8735 Ultra 實測韌體（`firmware/HUB-8735-Ultra-ASR-TTS.ino`：按鈕錄音 → 雲端 ASR → `POST /voice` → 雲端 TTS 播放），**已接上雲端契約**（上行打 Render 正式站 `https://jinsun-voice-server-mg1f.onrender.com/voice`＋下行 MQTT 訂閱 `jinsun/{serial}/cmd`；Render 只開 443，MQTT 靠外部 broker 會合——server 設 `MQTT_URL=mqtts://mqttgo.io:8883`（免 CA 檔），裝置照官方 MQTT-over-TLS 範例連同一顆、setRootCA 用 ISRG Root X1（實測此核心純 TCP 收不到資料、僅 `WiFiSSLClient` 可靠），細節見 `docs/requirements/hardware-integration.md`）；**ASR/TTS 實作上都走雲端服務**（僅長輩主動觸發那段語音上雲，符合約束 1），細節見 `docs/requirements/hardware-integration.md`。

另有一套**與正式環境完全獨立的 AWS 平行環境**在 `cloud/aws/`（API Gateway + Lambda + Step Functions + IoT Core + Aurora + Cognito），四端（家屬／志工／社工／長輩）靠 `--dart-define=BACKEND=aws` 切換（唯一切換點是 `apps/packages/core/lib/src/backend_factory.dart`），韌體靠 `.ino` 開頭的 `#define BACKEND_AWS`（走 AWS 要另外燒 IoT 裝置憑證，見 `firmware/README.md`）。**兩套環境不共用資料庫**，接手前先讀 `docs/requirements/aws-handoff.md`。

完整架構圖與跌倒偵測 sequence diagram 在 `docs/architecture.md`，修改任何一端之前先讀它。

## 不可違反的架構約束

1. **隱私邊界**：裝置端與雲端之間只透過 MQTT/TLS 傳「事件」，永遠不傳原始影音。跌倒推論、關鍵字偵測都在裝置本地端完成。只有長輩「主動」語音求助／代辦（如「我想買牛奶跟雞蛋」）那段語音才上雲做 ASR。任何新功能設計都不能打破這條線。
2. **長輩端沒有 UI**：長輩不用 App、不用螢幕操作。所有對長輩的互動都是語音播報（TTS）、燈號、鈴聲、實體 SOS 按鈕。
3. **升級時效**：疑似跌倒 → 語音詢問 → 20 秒無回應即升級（推播家屬＋發志工派遣單）。狀態機邏輯改動要保住這個黃金時間鏈路。
4. **admin 後台必須有 Excel 匯出**，這是政府申報的硬需求。

## Repo 結構與放置規則

```
jinsun-radio/
├── docs/                     所有文件的家（見下方文件規則）
│   ├── architecture.md       系統架構總覽（single source of truth）
│   ├── assets/               架構圖、流程圖等圖檔
│   └── requirements/         需求文件、user story、場域驗證 KPI（建立時放這）
├── firmware/                 長輩端韌體（Himax WiseEye2 + Realtek AmebaPro2）
├── cloud/                    雲端後端
│   ├── prototype/            本地 Node.js 原型（建立時放這，見下方）
│   ├── supabase/             正式環境的 schema 與 Edge Functions（schema 是兩套環境的單一來源）
│   └── aws/                  AWS 平行環境（Lambda / Step Functions / IoT policy / 部署腳本）
├── deploy/                   部署腳本（S3 + CloudFront 三端靜態站、ECS Fargate 參考設定）
├── apps/                     所有 Flutter 程式碼（見下方 Flutter 規劃）
│   ├── family_app/           家屬 App
│   ├── volunteer_app/        志工 App
│   ├── elder_app/            長輩端收音機網頁版（大錄音按鈕；AWS 環境走裝置帳號自動登入）
│   └── packages/             兩個 App 共用的 Dart packages（建立時放這）
└── admin/                    社工 Web 後台（dashboard + Excel 匯出）
```

放置規則：
- 新的規劃／需求／會議決議文件 → `docs/requirements/`，圖檔一律進 `docs/assets/`。不要把文件散落在各子專案裡；子專案 README 只寫該端的職責與啟動方式，細節連回 `docs/`。
- 架構有變動（新增服務、改事件流程）→ 同步更新 `docs/architecture.md`，不要只改子專案 README。
- 跨 App 共用的東西（API client、事件 model、推播處理、設計系統）→ `apps/packages/` 下開獨立 package，不要在兩個 App 之間複製貼上。

## Flutter 規劃（apps/）

- 兩個獨立的 Flutter app：`family_app`（家屬：安心日報、緊急通知、派遣進度）與 `volunteer_app`（志工：物資需求接單、緊急派遣單、到場回報、時間銀行點數）。目標平台 Android + iOS。
- 共用程式碼放 `apps/packages/`，預期至少會有：
  - `core`（或拆成 `api_client` / `models`）：事件與派遣單的資料 model、後端 API/WebSocket client、Cognito 認證
  - `ui_kit`：共用 widget 與主題
  App 的 `pubspec.yaml` 以 path dependency 引用（`path: ../packages/core`）。
- 推播是兩個 App 的核心功能（家屬要即時收到「疑似跌倒」、志工要即時收到派遣單），新功能不能破壞通知鏈路。

常用指令（在各 app 目錄下執行；`admin/` 與 `apps/packages/core` 亦同）：

```bash
flutter pub get          # 安裝依賴
flutter run -d chrome    # iOS/Android 工具鏈未備齊時用 chrome 或 macos 跑
flutter run              # 跑在連接的裝置/模擬器
flutter analyze          # 靜態分析（lint）
flutter test             # 全部測試
flutter test test/xxx_test.dart   # 跑單一測試檔
flutter build apk / flutter build ios / flutter build web
```

Demo 操作：app 開啟後按右下角「模擬收音機」觸發事件（疑似跌倒／SOS／物資需求）。改動 `MockBackend` 狀態機（20 秒升級、派遣轉移、點數）必須跑 `apps/packages/core` 的 `flutter test`，該鏈路是黃金時間合約。

## Cloud 規劃（cloud/）

策略：先寫本地 Node.js 原型驗證狀態機邏輯，介面設計成可直接換成對應 AWS 服務。

| 原型模組（放 `cloud/prototype/`） | 對應 AWS 正式服務 |
|---|---|
| aedes MQTT broker | AWS IoT Core |
| `core.js` 派遣狀態機（事件分級、20 秒升級、派工、回報） | Step Functions + Lambda |
| `ai.js`（ASR/LLM/TTS 介面，可切真 Bedrock） | Bedrock / Transcribe / Polly |
| `db.js` 資料層與角色權限 | DynamoDB + Cognito |

即時推播給使用者端走 WebSocket（正式為 AppSync）。裝置事件的 MQTT topic 與 payload schema 一旦定案，firmware 與 cloud 要共用同一份定義，schema 文件放 `docs/`。

角色權限三種：家屬、志工、社工（Cognito 區分），API 設計時就要帶角色概念。

## Firmware（firmware/）

Himax WiseEye2 跑跌倒視覺推論（影像不外傳），Realtek AmebaPro2 做主控／麥克風／Wi-Fi／MQTT。裝置接收雲端下發的指令目前有 `ask`（語音詢問）與 `speak`（播報／安撫），新增指令類型時同步更新 `docs/architecture.md` 的 sequence 說明。

## Admin（admin/）

Web 優先。功能：全體長輩即時狀態 dashboard（正常／注意／緊急）、關注排序、派遣監控、Excel 匯出（政府需求，必備）。技術棧尚未定案，選型時記錄決策到 `docs/requirements/`。
