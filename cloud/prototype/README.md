# cloud/prototype · 語音多 Agent server（本地原型）

硬體只做「喚醒 + 錄音 + ASR → 文字」；**所有意圖判斷、對話、急救與需求決策都在這個 server**。
設計成介面可直接切換成 AWS 服務（見 [`../../docs/architecture.md`](../../docs/architecture.md)、
[`../../docs/requirements/voice-agent-server.md`](../../docs/requirements/voice-agent-server.md)）。

## 資料流

```
硬體(喚醒+ASR) → POST /voice {device_serial,text}
      → Orchestrator
         ├─ 急救對話進行中？ → Emergency Agent（吃掉「我沒事」/後續回應）
         ├─ Intent Agent 分類（rule 快路徑優先，未命中才問 Bedrock）
         │    emergency → Emergency Agent（逾時階梯 → 升級派遣）
         │    need      → Needs Agent（建 supply 派遣單）
         │    device    → Device Agent（音量/停止…）
         │    general   → Conversation Agent（帶 Memory）
         └─ Response Generator → { reply, intent, action }
      → 硬體 TTS 播 reply；action.command 由硬體執行
```

Emergency / Needs 的決策會寫進既有 Supabase（`radio_events` + `dispatch_tasks`），
**自動觸發家屬 App／志工 App／社工後台的即時推播**——不另建通知系統。

## 跑起來（零設定、離線可跑）

```bash
cd cloud/prototype
npm test          # 黃金時間鏈路合約測試（假計時器，秒過）
npm start         # 啟動 server（預設 mock LLM + dry-run 派遣）

curl -s localhost:8787/voice -d '{"device_serial":"JS-0001","text":"我跌倒了"}'
curl -s localhost:8787/voice -d '{"device_serial":"JS-0001","text":"我想買牛奶跟雞蛋"}'
```

不填任何金鑰時：LLM 走 mock（規則化回覆）、派遣走 dry-run（印 log），狀態機與測試照跑。

## 端到端測試：硬體發聲 → server → 三端亮起

目標：證明「裝置上報 → server 處理 → 寫進 Supabase → 家屬/志工/社工三端即時亮」整條通。

**關鍵前提**：server 要用 Supabase **SERVICE key**（secret，非 anon）才寫得進 `dispatch_tasks`。
用 anon key 只能寫 `radio_events`、寫不了派遣單 → 志工端不會出現接單。

```bash
cd cloud/prototype
npm i @supabase/supabase-js          # 讓 dispatch 能真的寫 Supabase

# 終端 A：啟動 server（填 service key → 啟動日誌要顯示 dispatch=live）
SUPABASE_SERVICE_KEY=<你的-service-key> EMERGENCY_WAIT1_MS=4000 EMERGENCY_WAIT2_MS=4000 npm start

# 終端 B：即時盯著 Supabase（不用開三個 App 也能確認寫進去了）
npm run watch
```

然後**模擬硬體**（或用真裝置對 `/voice` 發同樣的請求）：

```bash
# ① 實體 SOS 鍵 → 立即升級（終端 B 會馬上冒出 sos/escalated + emergency 待接單，長輩轉🔴）
curl -s localhost:8787/voice -d '{"device_serial":"JS-0001","event":"sos"}'

# ② 語音「我跌倒了」→ 問診 → 沒回應 → 約 8 秒後升級（用上面的 WAIT 環境變數縮短）
curl -s localhost:8787/voice -d '{"device_serial":"JS-0001","text":"我跌倒了"}'

# ③ 物資需求「我想買牛奶跟雞蛋」→ 立即出現 supply 待接單
curl -s localhost:8787/voice -d '{"device_serial":"JS-0001","text":"我想買牛奶跟雞蛋"}'
```

**驗收點**：
1. `npm run watch` 的「最新事件／派遣單」冒出新列、長輩燈號變色 → **server→Supabase 通**。
2. 打開家屬 App（該長輩收到緊急通知）、志工 App（出現待接單）、社工後台（dashboard 轉🔴）
   → **Supabase→三端推播通**。
3. 真裝置測下行：裝置訂閱 `jinsun/JS-0001/cmd`，急救逾時後應收到 speak 指令並發聲。
   瀏覽器模擬控制台仍走 `GET /commands` 長輪詢（enqueue 扇出，兩通道都會收到同一筆指令）。
   broker 有兩種型態，看 `/health` 的 `mqtt` 欄位確認目前模式：

   | 模式 | 怎麼啟動 | 裝置／對測連哪 |
   |---|---|---|
   | `live`（內嵌 aedes，本機開發） | `npm start`（預設，`MQTT_PORT` 可改埠、`0`＝停用） | `mosquitto_sub -h <server IP> -t 'jinsun/JS-0001/cmd' -v` |
   | `client`（外部 broker，Render 部署） | `MQTT_URL=mqtts://mqttgo.io:8883 npm start` | `mosquitto_sub -h mqttgo.io -t 'jinsun/JS-0001/cmd' -v` |

   Render 這類 PaaS 只對外開 HTTPS(443)，內嵌 broker 的 1883 從公網進不來，所以改設 `MQTT_URL`
   讓 server 與裝置各自連上同一顆外部 broker 會合（topic／payload／QoS 契約完全相同）。
   沒裝 mosquitto 的話 `npx mqtt sub …` 等效。

> `device_serial` 要用資料庫既有的 `JS-0001/JS-0002/JS-0003`（seed 已綁 elder-1/2/3），
> 否則 trigger 反查不到 elder_id。

## 接真服務

複製 `.env.example` 為 `.env` 並填：

- `LLM_PROVIDER=bedrock` + AWS 憑證 → Intent/Needs/Conversation 走真 Amazon Bedrock（Claude）。
  需 `npm i @aws-sdk/client-bedrock-runtime`。
- `SUPABASE_SERVICE_KEY=...` → Emergency/Needs 真的寫派遣單、觸發三端推播。
  需 `npm i @supabase/supabase-js`。

## 檔案

| 檔 | 職責 | 正式對應 |
|---|---|---|
| `src/config/triggers.js` | **喚醒詞／急救詞／需求詞／裝置詞＋急救對話腳本與逾時階梯**（寫死在 server） | Lambda 設定／參數表 |
| `src/agents/intent.js` | 意圖分類（rule + LLM） | Bedrock |
| `src/agents/emergency.js` | 急救對話狀態機（黃金時間鏈路） | Step Functions |
| `src/agents/needs.js` | 需求解析 → 物資派遣單 | Bedrock + Step Functions |
| `src/agents/conversation.js` | 陪伴聊天（帶記憶） | Bedrock |
| `src/agents/device.js` | 裝置控制指令 | IoT Core 下發 |
| `src/agents/memory.js` | 長期記憶 | DynamoDB |
| `src/llm/bedrock.js` | LLM 可切換介面（mock/bedrock） | Bedrock Runtime |
| `src/dispatch.js` | 寫 Supabase 觸發三端 | Step Functions + AppSync |
| `src/orchestrator.js` | 路由大腦 | — |
| `src/server.js` | HTTP 入口 | API Gateway + Lambda |

> ⚠️ 改動 `triggers.js` 的急救腳本或 `emergency.js` 的逾時階梯，必跑 `npm test`——
> 那是「20 秒無回應必升級」的黃金時間合約。
