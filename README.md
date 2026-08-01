# jinsun-radio（金孫收音機）

給獨居與失能長者的近端 AI 陪伴與社區互助派遣系統。

以長輩熟悉的收音機作為入口，打開、按下、說話——零學習成本。平常資料在地處理、不監控、不上雲；只有主動求助或授權週報才啟用 ASR／LLM／TTS。當長者提出需求或發生緊急狀況，系統會通知家人並媒合附近志工、物業、照服員，以時間銀行回饋，形成可追蹤、可派遣、可回報的照顧閉環。

> 一句話定位：不是讓長輩學會用 App，而是讓 AI 長得像他本來就會用的收音機。

2026 AI 創新獎・組別二：智慧照護與居家健康（Smart Care & Home Health）參賽提案。

![金孫收音機｜口袋型穿戴式 AI 安心夥伴](docs/assets/product-design.jpg)

> ⚠️ 硬體型態迭代中：目前有兩個版本的設計圖並存——`docs/assets/system-architecture.jpg`（桌上型收音機，主控為 Realtek AmebaPro2）與上圖（口袋型穿戴式，主控為 XIAO ESP32-S3）。以哪個為準尚待確認，見下方「技術架構」。

## 核心場景

- **大按鈕 SOS**：一按直接求助，不必解鎖打字
- **跌倒／久臥偵測**：近端視覺＋麥克風陣列偵測異常，語音確認「有沒有撞到？」
- **語音求助／代辦**：長輩以自然語言（含台語）說出需求，如「我想買牛奶跟雞蛋」
- **吃藥／復健提醒**：可由兒女預先錄音
- **安心週報**：授權後由 AI 摘要活動、提醒、異常、互動狀況
- **社區派遣**：偵測到緊急狀況 → 通知監護人 → 派送附近志工／物業／照服員 → 回報 ETA → 到場回報「已安全」

## 角色與軟體類型

| 角色 | 需要看到／做到什麼 | 軟體類型 |
|---|---|---|
| 長輩 | 不需要 App，只需要收音機：跌倒偵測相機＋聲音偵測＋語音播報（是否需要幫助／還有多久會到）＋ SOS 時 TTS | 嵌入式裝置，零學習成本 |
| 家屬 | 掌握老人家即時狀態、接收緊急通知 | Flutter App（跨 Android／iOS） |
| 志工 | 看到老人家需要什麼物資、接單去採買／到場確認安全 | Flutter App |
| 管理介面後台（社工／我們） | 所有長輩即時狀態的 dashboard，需可匯出 Excel 以符合政府申報需求 | Web（App 亦可） |

## 技術架構：感知 → 決策 → 行動 → 回報

![系統架構圖](docs/assets/system-architecture.jpg)

- **感知層（長輩端裝置，全國產晶片，預設不上雲）**：Himax WiseEye2（奇景光電，跌倒視覺推論，透過 Grove Vision AI V2／XIAO ESP32-S3 兩種硬體型態都在評估中，見上方警示）＋麥克風陣列；裝置與雲端之間僅透過 MQTT/TLS 傳送事件，不傳影音
- **決策層（AWS 雲端）**：AWS IoT Core 接事件 → Step Functions + Lambda 做事件分級與逾時升級判斷 → Bedrock／Transcribe／Polly 處理 ASR／LLM／TTS → DynamoDB + Cognito 做資料層與角色權限
- **行動層**：裝置端語音對講與安撫回應（「已經幫你叫人，預計 6 分鐘內到」）＋透過 WebSocket／AppSync 即時推播給家屬 App／志工 App／社工 Web 後台，媒合志工到場確認安全（Physical AI in the Loop，類似 Uber 的派工與 ETA 回報）

完整架構圖與跌倒偵測事件流程（sequence diagram）見 [`docs/architecture.md`](docs/architecture.md)。

技術落地路線：Himax WiseEye2 → 延伸至 Kneron + Andes RISC-V 國產邊緣 AI 生態。

## 隱私與資安設計

| 模式 | 運作 | 內容 |
|---|---|---|
| 平常模式 | 近端運作 | 提醒、關鍵字偵測、跌倒判斷；原始影音不上雲 |
| 主動模式 | 需要時才上雲 | 求助、叫人、家屬授權週報；ASR／LLM／TTS 處理 |
| 對講模式 | 可被看見、可被拒絕 | 家人不能偷聽；長輩可說「好」或「不要」 |

設計底線：長輩永遠知道自己何時被連線、何時被求助、資料何時離開家。

## 硬體規格（口袋型穿戴版本，參考）

| 項目 | 規格 |
|---|---|
| 尺寸 | 55 × 38 × 18 mm（不含吊繩） |
| 重量 | 約 68g |
| 電池 | 18650 鋰電池 3.7V 2000mAh（可充電） |
| 充電 | USB-C 5V/1A |
| 續航 | 約 3–5 天（依使用情境） |
| 喇叭 | FM 收音，輸出功率 2W |
| 感測 | AI 視覺辨識（跌倒偵測）＋ 3 軸加速度計 ＋ 麥克風陣列 |
| 配戴方式 | 掛脖、夾於衣物／口袋、掛包包背帶；內建可折疊支架可桌面立式擺放 |

主要模組：外殼上蓋、布質吊繩、LED 狀態燈條、隱藏式攝影機模組（Himax WiseEye2 跌倒視覺辨識）、麥克風陣列、Grove Vision AI V2 視覺模組、MAX98357A 數位功放、內建喇叭、XIAO ESP32-S3 控制板（主控／Wi-Fi／藍牙／邊緣運算）、SOS 大按鍵模組、可充電鋰電池與充電保護板、可折疊立式支架、背夾結構。完整零件圖見上方產品外觀圖。

## Repo 結構

```
jinsun-radio/
├── docs/           系統架構、事件流程圖
├── firmware/       長輩端裝置韌體（Himax WiseEye2 + Realtek AmebaPro2）
├── cloud/          雲端後端（AWS IoT Core / Step Functions / Bedrock / DynamoDB）
├── apps/
│   ├── family_app/     家屬 App（Flutter）
│   └── volunteer_app/  志工 App（Flutter）
└── admin/          管理介面後台（社工 Web dashboard）
```

## 快速啟動（Phase 1 薄閉環 demo）

三端皆為 Flutter 專案，資料層為 `jinsun_core` 的 `MockBackend`（in-app mock，無真後端）。iOS／Android 工具鏈尚未備齊時，用 `-d chrome` 或 `-d macos` 即可跑。

```bash
# 家屬 App
cd apps/family_app && flutter pub get && flutter run -d chrome

# 志工 App
cd apps/volunteer_app && flutter pub get && flutter run -d chrome

# 社工後台（web，含下載 Excel）
cd admin && flutter pub get && flutter run -d chrome

# 核心狀態機測試（20 秒升級、派遣生命週期、點數）
cd apps/packages/core && flutter test
```

開啟後按右下角「模擬收音機」觸發事件：
- **疑似跌倒** → 20 秒未回應自動升級 → 通知＋開派遣單（家屬端有虛擬志工自動接單回 ETA）
- **SOS** → 立即開緊急派遣單
- **物資需求** → 志工端可接單採買、回報送達

各端功能與範圍見子專案 README；spec 與拍板決策見 [`docs/requirements/phase1-mvp.md`](docs/requirements/phase1-mvp.md)。

## 專案狀態

Phase 1 薄閉環已實作（2026-07-11）：`jinsun_core` 狀態機＋家屬／志工／社工三端可跑、有測試。`cloud/` 與 `firmware/` 尚未動工，三端目前各自獨立模擬（跨裝置同步待 Phase 2 真後端）。詳細背景與完整企劃書內容請見團隊內部文件。

技術落地路線圖（Phase 1–4）：
1. Web／PWA ＋ 收音機外殼 mockup（服務閉環可展示）
2. Himax WiseEye2 近端影像／語音偵測驗證
3. 串接社區物業、照服單位、地方政府、時間銀行
4. 導入獨居老人服務、關懷據點、銀髮宅、智慧社區
