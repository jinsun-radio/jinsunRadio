# Phase 1 MVP：服務閉環原型（薄閉環）

> 目標時程：2026-08 中前可錄 3 分鐘 demo 影片，供 2026 AI 創新獎初審（8–9 月）使用。
> 拍板日期：2026-07-11。

## 功能目標

用最小的軟體面積讓「感知 → 決策 → 行動 → 回報」整條故事線在螢幕上走得完：收音機（mock）偵測到跌倒或收到物資需求 → 家屬 App 收到通知並看到即時狀態 → 志工 App 接單並回報 ETA 與完成 → 社工後台全程可見並可匯出 Excel。長輩端無任何 UI（硬體不在本階段範圍），以 MockBackend 模擬其事件流。

## 邏輯摘要

MockBackend 作為單一事件來源，模擬收音機端裝置事件（`sos`／`fall_suspected`／`supply_request`）並實作雲端派遣狀態機：事件進入後先分級為〔正常／注意／緊急〕，`fall_suspected` 觸發後啟動 20 秒語音確認計時器，逾時無回應即升級為緊急——推送家屬通知並開立志工派遣單；派遣單狀態機為 `pending` → `accepted(ETA)` → `arrived` → `resolved`，每次轉移都廣播給該 app 內的 stream 訂閱者，志工完成後時間銀行點數 +2（緊急）／+1（物資）。因三端為獨立 process 且零 infra，MockBackend 內建「虛擬角色」補齊閉環：家屬端與 admin 端的 mock 會由虛擬志工自動接單→回 ETA→到場→回報，志工端則由真人操作接單、虛擬家屬隱含存在。所有狀態存在記憶體內、無持久化，app 重啟即重置為 seed 資料；MockBackend 對外只暴露抽象介面（`BackendClient`），Phase 2 換成真 API/WebSocket client 後三端才有真正的跨裝置同步，UI 不需改動。

## 拍板決策（2026-07-11）

| 決策 | 內容 | 理由 |
|---|---|---|
| 資料層 | in-app mock，零 infra | demo 階段接真後端是 over-build；8 月要準備初審 |
| admin 技術棧 | Flutter web（放 `admin/`） | 與兩個 App 單一語言棧；Excel 匯出用 dart package 產 `.xlsx` 供瀏覽器下載；之後不合用再換 |
| 共用碼 | `apps/packages/core`（package 名 `jinsun_core`） | 依 repo CLAUDE.md 放置規則 |
| 長輩端 | 無 UI、無 app | 收音機為純硬體，本階段以 MockBackend 模擬事件 |

## In Scope

- `jinsun_core`：Elder／RadioEvent／DispatchTask／SupplyRequest model、severity 三級、`BackendClient` 抽象介面、`MockBackend` 實作（含 20 秒升級計時器與 demo 劇本觸發器）
- 家屬 App：長輩即時狀態卡、緊急事件通知（in-app banner）、派遣進度（誰接單、ETA、已安全）
- 志工 App：物資需求列表與接單、緊急派遣單（接單→回 ETA→到場→回報已安全）、時間銀行點數
- admin（Flutter web）：全體長輩狀態 dashboard（正常／注意／緊急排序）、事件與派遣即時列表、Excel 匯出鈕
- Demo 控制：可手動觸發「疑似跌倒」「SOS」「物資需求」事件的開發者面板

## Out of Scope（backlog，驗證後才考慮）

- `cloud/` 原型（aedes MQTT／Node.js 狀態機）與任何 AWS 服務
- `firmware/`（Himax WiseEye2）
- 真推播（FCM/APNs）、登入與角色權限（Cognito）
- 真時間銀行帳本（點數僅 mock 顯示）
- 安心週報／日報生成

## 驗證訊號

- 2026-08-15 前：3 分鐘 demo 影片能完整講完「跌倒 → 升級 → 派遣 → 回報」故事線
- 給隊友／潛在評審看過至少一輪並收到反饋，再決定下一塊（cloud 原型 vs. firmware 驗證）

## 驗收條件

1. 家屬 App：demo 面板觸發 `fall_suspected` → 20 秒無確認即看到「疑似跌倒」升級通知 → 虛擬志工自動接單並顯示 ETA → 到場 → 「已安全」，全程狀態卡同步變化
2. 志工 App：demo 面板觸發後收到緊急派遣單，真人操作接單（填 ETA）→ 到場 → 回報已安全，時間銀行點數 +2；物資需求接單完成 +1
3. admin：dashboard 依〔緊急→注意→正常〕排序全體長輩，事件與派遣列表即時更新，可下載含當前事件紀錄的 `.xlsx`
4. `jinsun_core` 狀態機有 unit test：20 秒升級、確認沒事取消升級、派遣單狀態轉移、點數累計

## 已知限制（Phase 1 刻意保留）

- 三端各自獨立模擬，無跨裝置同步；跨裝置即時互動（評審現場兩支手機互動）需 Phase 2 真後端，`BackendClient` 抽象層已為此預留
- 決賽（12 月）現場 live demo 前必須完成 Phase 2，否則只能放影片
