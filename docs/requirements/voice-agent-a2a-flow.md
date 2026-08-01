# 語音多 Agent 架構（A2A）：架構圖・Flow・Sequence

> 定位：把 [`voice-agent-server.md`](voice-agent-server.md) 的六 Agent 設計，用 **A2A（Agent-to-Agent）架構**表述成一份可對外說明的規劃：
> **裝置觸發語音 → 雲端 ASR 轉文字 → 文字送 server endpoint（服務唯一入口）→ intent_agent 意圖判斷 → 透過 A2A 把任務轉交專責 agent 執行**。
> 裝置端現況（按鈕觸發、雲端 ASR/TTS）見 [`hardware-integration.md`](hardware-integration.md)；本文圖表以 Mermaid 繪製，GitHub 可直接預覽。

## 1. 端到端架構圖

```mermaid
flowchart LR
    subgraph DEVICE["長輩端裝置（HUB8735 Ultra）"]
        TRIG["觸發<br/>（按鈕，未來：喚醒詞／SOS／相機）"] --> REC["錄音<br/>16kHz PDM 麥克風"]
        MQ["MQTT client<br/>（訂閱 jinsun/{serial}/cmd，常駐連線）"]
        SPK["喇叭播放<br/>（MAX98357）"]
    end

    REC -- "音檔（僅主動觸發段落）" --> ASR["雲端 ASR<br/>faster-whisper Breeze-ASR-26"]
    ASR -- "中文文字" --> EP["server endpoint<br/>POST /voice（服務入口）"]

    subgraph SERVER["語音 Agent Server（A2A 多 Agent）"]
        EP --> INTENT["intent_agent<br/>意圖判斷（rule 快路徑 + LLM）"]
        INTENT -- "A2A: emergency" --> EMG["emergency_agent<br/>急救對話・逾時階梯・升級"]
        INTENT -- "A2A: need" --> NEEDS["needs_agent<br/>採購／探訪需求抽取"]
        INTENT -- "A2A: general" --> CONV["conversation_agent<br/>陪伴聊天"]
        INTENT -- "A2A: device" --> DEV["device_agent<br/>音量／停止／重說"]
        CONV <-- "A2A: 記憶讀寫" --> MEM["memory_agent<br/>長期記憶"]
        EMG --> DISP["dispatch<br/>寫事件＋開派遣單"]
        NEEDS --> DISP
    end

    DISP --> DB[("Supabase<br/>radio_events / dispatch_tasks")]
    DB -- "Realtime 推播" --> FAM["家屬 App"]
    DB -- "Realtime 推播" --> VOL["志工 App"]
    DB -- "Realtime 推播" --> ADM["社工後台"]

    DB -- "狀態變化（接單／抵達）<br/>志工 GPS 進 250m（快到門口）" --> PROG["進度播報 worker"]
    PROG -- "publish jinsun/{serial}/cmd<br/>speak（帶 lang）" --> BRK["MQTT broker<br/>（原型：aedes 內嵌於 server<br/>正式：AWS IoT Core）"]
    BRK -- "push（走裝置既有連線，<br/>NAT 後也收得到）" --> MQ

    EP -- "reply 文字＋lang" --> TTS["雲端 TTS（依 lang 分流）<br/>台語：ATEN（回 WAV URL）<br/>國語：Polly Zhiyu（直接回 WAV）"]
    MQ -- "speak 文字＋lang" --> TTS
    TTS -- "WAV 串流" --> SPK
```

要點：

- **隱私邊界**（架構約束 1）：只有長輩「主動觸發」那段語音會離開裝置去做 ASR；影像永不外傳。進到 server endpoint 的**只有文字**。
- **server endpoint 是唯一入口**：裝置不直連任何 agent，一律走 `POST /voice`；agent 的增減、拆分對裝置端完全透明。
- **下行是 MQTT push**：裝置開機連上 broker、訂閱 `jinsun/{serial}/cmd` 並保持連線，server 有話要說（急救階梯、進度播報）就 publish，裝置收到即觸發 TTS 發聲。因為是裝置主動向外連線，**家用 NAT 後面也收得到**；連上 broker 即等於註冊，Last Will 順帶給後台「裝置離線」偵測。原型 broker 用 server 內嵌的 aedes，正式換 AWS IoT Core（topic／payload 不變）。
- **雙向都經過雲端 TTS**：即問即答（`reply`）與主動下行（`speak`）最後都變成文字 → TTS → 裝置播放，長輩全程只用耳朵和嘴巴。

## 2. 整體 Flow 圖

```mermaid
flowchart TD
    A["長輩觸發（按住按鈕 1 秒）"] --> B["裝置錄音（最長 30s，再按一下結束）"]
    B --> C["音檔上傳雲端 ASR → 中文文字"]
    C --> D["POST /voice<br/>{device_serial, text}"]
    D --> E{"rule 快路徑命中？<br/>（triggers.js：急救詞／需求詞／裝置詞）"}
    E -- "命中" --> G
    E -- "未命中" --> F["intent_agent 以 LLM 分類"]
    F --> G{"意圖"}

    G -- "emergency<br/>（救命／跌倒／不舒服）" --> H["emergency_agent<br/>啟動急救對話＋雲端計時"]
    H --> H1{"確認窗口內<br/>長輩有回應？"}
    H1 -- "說『我沒事』" --> H2["解除，安撫收尾，不派遣"]
    H1 -- "20 秒級無回應" --> H3["升級：寫 radio_events(escalated)<br/>＋dispatch_tasks(emergency)"]
    H3 --> P["三端推播：家屬通知＋志工派遣單＋後台監控"]

    G -- "need<br/>（採購／探訪／生活協助）" --> I["needs_agent<br/>抽出品項／需求 → supply 派遣單"]
    I --> P

    G -- "general（閒聊）" --> J["conversation_agent<br/>帶 memory_agent 記憶回覆"]
    G -- "device（大聲點／安靜）" --> K["device_agent<br/>回裝置指令 volume_up 等"]

    P --> Q["志工接單／GPS 快到門口／抵達 → 進度播報 worker"]
    Q --> R["server publish MQTT<br/>jinsun/{serial}/cmd：speak（帶 lang 國語／台語）"]

    H2 --> S["回覆文字 → 雲端 TTS → 裝置播放"]
    H3 --> S
    I --> S
    J --> S
    K --> S
    R --> S
```

## 3. Sequence Diagrams

### 3.1 閒聊（general）——最短路徑，不進派遣

```mermaid
sequenceDiagram
    actor E as 長輩
    participant D as 裝置
    participant ASR as 雲端 ASR
    participant EP as server endpoint<br/>(POST /voice)
    participant INT as intent_agent
    participant CONV as conversation_agent
    participant MEM as memory_agent
    participant TTS as 雲端 TTS

    E->>D: 按住按鈕 1 秒，說「今天好無聊喔」
    D->>ASR: 上傳錄音音檔
    ASR-->>D: 文字
    D->>EP: POST /voice {device_serial, text}
    EP->>INT: 文字
    INT->>CONV: A2A task（intent=general）
    CONV->>MEM: A2A 讀記憶（偏好／近況）
    MEM-->>CONV: 記憶片段
    CONV-->>EP: reply（一句話陪伴回覆）
    EP-->>D: 200 {reply, intent:"general"}
    D->>TTS: POST reply 文字
    TTS-->>D: WAV URL → 串流
    D-->>E: 喇叭播放回覆
```

### 3.2 採購／探訪需求（need）——開派遣單、三端推播、進度回報

```mermaid
sequenceDiagram
    actor E as 長輩
    participant D as 裝置
    participant EP as server endpoint
    participant INT as intent_agent
    participant NEED as needs_agent
    participant DB as Supabase<br/>(radio_events / dispatch_tasks)
    participant V as 志工 App
    participant F as 家屬 App
    participant PW as 進度播報 worker

    E->>D: 觸發＋說「我想買牛奶跟雞蛋」
    D->>EP: （錄音→ASR）POST /voice {text}
    EP->>INT: 文字
    INT->>NEED: A2A task（intent=need）
    NEED->>NEED: LLM 抽品項：牛奶、雞蛋
    NEED->>DB: 寫事件＋supply 派遣單
    DB-->>V: Realtime：新派遣單
    DB-->>F: Realtime：安心日報更新
    NEED-->>EP: reply「好，幫您記下牛奶跟雞蛋…」
    EP-->>D: 200 {reply, intent:"need"}
    D-->>E: TTS 播放確認

    V->>DB: 志工接單（accepted, ETA 8 分）
    DB-->>PW: Realtime 狀態變化
    PW->>DB: 反查 device_serial＋preferred_lang
    PW->>D: MQTT publish jinsun/{serial}/cmd<br/>{speak, lang=taigi}（QoS 1）
    D-->>E: （文字→雲端 TTS→串流）播「志工○○大約 8 分鐘到，您再等一下喔」
```

### 3.3 緊急求救（emergency）——逾時階梯與黃金時間升級

```mermaid
sequenceDiagram
    actor E as 長輩
    participant D as 裝置
    participant EP as server endpoint
    participant INT as intent_agent
    participant EMG as emergency_agent<br/>（雲端持有計時器）
    participant DB as Supabase
    participant F as 家屬 App
    participant V as 志工 App

    E->>D: 觸發＋說「救命」
    D->>EP: （錄音→ASR）POST /voice {text:"救命"}
    EP->>INT: 文字
    Note over INT: rule 快路徑命中急救詞<br/>不等 LLM
    INT->>EMG: A2A task（intent=emergency）
    EMG-->>EP: reply「我聽到您說救命了…還好嗎？」
    EP-->>D: 200 {reply}
    D-->>E: TTS 播放確認詢問

    Note over EMG: 等待 10s（計時器在雲端，<br/>裝置／App 關機不影響）

    alt 長輩回「我沒事」
        E->>D: 再次觸發＋「我沒事」
        D->>EP: POST /voice
        EP->>EMG: （急救對話中，直達 emergency_agent）
        EMG-->>D: reply「聽到您沒事我就放心了」→ 解除
    else 10s 無回應
        EMG->>D: MQTT publish：speak 再次確認（等 12s）
        Note over EMG: 仍無回應 → 總窗口 ≈ 22s，升級
        EMG->>DB: radio_events(escalated, emergency)<br/>＋dispatch_tasks(emergency)
        DB-->>F: 推播「疑似緊急狀況」
        DB-->>V: 緊急派遣單
        V->>DB: 接單（ETA 6 分）
        DB-->>D: 進度播報 worker MQTT publish：<br/>speak「已經幫你叫人，志工 6 分鐘到」
        D-->>E: TTS 安撫播放
        V->>DB: GPS 上報（LocationPublisher，每移動 20m）
        Note over DB: 進度播報 worker 算距離：<br/>進 250m → 預告；進 60m → 自動 arrived
        DB-->>D: speak「志工快到門口了，等一下會敲門」
        D-->>E: TTS 預告播放（長輩有時間走到門邊）
    end
```

## 4. A2A 溝通規範

每個 agent 以獨立單元看待，intent_agent 是 A2A 的 client、其餘 agent 是 server：

| 元素 | 內容 |
|---|---|
| Agent Card | 每個 agent 宣告 `{name, description, skills[], endpoint}`，intent_agent 依此路由 |
| Task 訊息 | `{task_id, intent, text, device_serial, elder_id, lang, context{急救對話狀態, 記憶}}` |
| 回覆 | `{reply_text, actions[]（開派遣單／裝置指令）, state（如急救對話 lock）}` |
| 狀態鎖 | **急救對話進行中，後續發言一律直達 emergency_agent**（非「我沒事」不解除），不會被誤判成閒聊——對齊 `orchestrator.js` 既有安全預設 |

實作分兩階段：

1. **原型（現況）**：`cloud/prototype/src/orchestrator.js` 以 in-process 呼叫模擬 A2A——訊息格式照上表，但 agent 都在同一個 Node process（可視為 A2A-lite）。
2. **正式**：各 agent 拆成獨立部署單元（Lambda／Bedrock Agents），之間走 A2A 協定（JSON-RPC over HTTP，Agent Card 探索）；intent_agent 保持唯一路由者，server endpoint（API Gateway）保持唯一入口。

## 5. 概念 ↔ 現況對照

| 本文概念 | 原型現況（repo 內） | 正式目標 |
|---|---|---|
| 板子觸發語音 | 按住按鈕 1 秒錄音（`firmware/HUB-8735-Ultra-ASR-TTS.ino`） | ＋喚醒詞「小金孫」／SOS 鍵／相機事件 |
| ASR 語音轉文字 | 雲端 Breeze-ASR-26（已跑通） | 同，服務可抽換 |
| server endpoint | `cloud/prototype` `POST /voice`（已建；**韌體已接上**，原本的直連 Gemini 已移除） | API Gateway + Lambda |
| intent_agent | `agents/intent` ＋ rule 快路徑 `triggers.js` | Bedrock（Claude） |
| A2A 溝通 | in-process orchestrator（A2A-lite） | 獨立部署 + A2A 協定 |
| 各 agent 執行 | emergency／needs／conversation／device／memory 六隻已建 | Step Functions／DynamoDB 等對應見 `voice-agent-server.md` §6 |
| 下行播報 | **已實作：MQTT push**（publish `jinsun/{serial}/cmd`、QoS 1、LWT 上下線；長輪詢保留給瀏覽器模擬控制台）。broker 兩型態：本機＝server 內嵌 aedes（`MQTT_PORT`）；Render 部署＝server 當 client 連外部 broker（`MQTT_URL=mqtts://mqttgo.io:8883`，因 PaaS 只開 443） | AWS IoT Core（換 endpoint＋憑證，topic／payload 不變） |
