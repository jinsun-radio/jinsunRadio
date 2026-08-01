# 雲端語音多 Agent Server

> 對象：長輩端「主動語音互動」的雲端大腦。原型見 [`cloud/prototype/`](../../cloud/prototype/)。
> 本文是需求／設計 single source；架構總覽同步在 [`architecture.md`](../architecture.md)。
> A2A 多 Agent 架構圖、flow 圖與 sequence diagram 見 [`voice-agent-a2a-flow.md`](voice-agent-a2a-flow.md)。

## 1. 這一層在整個系統的位置

金孫收音機已有一條成熟鏈路：**事件 → 分級 → 派遣 → 三端推播**（Supabase `radio_events` /
`dispatch_tasks`，家屬 App／志工 App／社工後台即時同步）。

語音 Agent Server 不是另起爐灶，而是**在這條鏈路前面加一個「語音入口」**：
把長輩說的話（跌倒、求救、口渴、想買東西、閒聊）翻譯成系統聽得懂的「事件／派遣單」，
再讓既有鏈路接手。閒聊與裝置控制則就地回覆、不進派遣。

```
長輩說話 → 硬體(觸發+錄音) → 雲端 ASR → 語音 Agent Server ──(緊急/需求)──▶ radio_events + dispatch_tasks ─▶ 三端推播
                                                    └──(閒聊/裝置)──▶ 回文字給硬體 → 雲端 TTS 發聲
```

## 2. 對「硬體只收音」流程的判斷（回答提問）

**方向正確；ASR 依實測韌體改走雲端服務，但進到本 server 的仍然只有文字。** 理由：

1. **符合本專案隱私鐵律**（`CLAUDE.md` 約束 1）：影像不外傳，語音只有長輩**主動觸發**的段落上雲。
   實測韌體是裝置把主動錄音上傳外部 ASR 服務轉文字、再把文字送上來；`POST /voice` 契約不變：
   只吃文字、本 server 不開音檔端點。ASR 服務屬裝置側的前置依賴（硬體對接契約見
   [`hardware-integration.md`](hardware-integration.md)）；device-side STT 改列未來隱私強化方向。
2. **喚醒詞與急救詞要雙層**：
   - 裝置端本地有一組**離線喚醒/求救詞**（喊「救命」時就算網路不好也要能觸發本地燈號/鈴聲）。
   - 雲端再有一份**權威觸發表**（本文第 3 節），做最終分類與對話。兩者內容可重疊，職責不同。
3. **計時器（20 秒無回應升級）必須放雲端**，不能放硬體或 App。
   目前 demo 的升級計時器跑在 Flutter App 內（`SupabaseBackend`），App 一關就失效；
   正式版要由這個 Server 的 Emergency Agent（→ Step Functions）持有，才守得住黃金時間合約。

一句話：**硬體＝耳朵＋嘴巴（收音、觸發、播放、燈號、SOS 鍵，ASR/TTS 呼叫雲端服務）；雲端＝大腦（分類、對話、決策、計時、派遣）。**

## 3. Server 端寫死的觸發表（Rule-based）

實作於 [`cloud/prototype/src/config/triggers.js`](../../cloud/prototype/src/config/triggers.js)。
這層不進 LLM：快、穩、可審計；命中即定案，省一次模型呼叫。

### 3.1 喚醒詞 Wake Words
品牌名可調（預設「小金孫」）：

`小金孫`、`金孫`、`嘿金孫`、`金孫你好`、`阿金`、`救命`、`help`、`sos`、`有人嗎`

### 3.2 高優先急救詞 Emergency（→ Emergency Agent，不等 LLM）
`救命`、`救我`、`快來人`、`我跌倒/跌倒了/摔倒`、`起不來/爬不起來/站不起來`、
`好痛/很痛/不舒服`、`喘不過氣/不能呼吸/呼吸困難`、`胸口痛/心臟`、`流血`、`昏倒/頭暈/暈倒`

### 3.3 日常需求詞 Need（→ Needs Agent）
| 說法 | 建立的代辦 |
|---|---|
| 想喝水／口渴 | 喝水 |
| 餓了／肚子餓／想吃飯 | 吃飯 |
| 要吃藥／忘記吃藥 | 吃藥提醒 |
| 要上廁所 | 如廁協助 |
| 睡不著／失眠 | 休息 |
| 叫家人／找兒子女兒 | 聯絡家人 |
| 叫看護／找志工／需要幫忙 | 生活協助 |
| 我想買 X 跟 Y | 由 Needs Agent 抽出品項 → 物資派遣單 |

### 3.4 裝置控制詞 Device（→ Device Agent）
`大聲/聽不清楚` → volume_up；`小聲/太吵` → volume_down；`關掉/安靜/別說了` → stop_speak；`再說一次` → repeat

### 3.5 解除詞 Stand-down（急救對話中）
`我沒事`、`沒事`、`沒關係`、`不用`、`好了`、`不痛了`、`我很好`

## 4. 急救對話腳本與逾時階梯（黃金時間合約）

長輩「主動」喊救命＝已在求救，確認窗口要短。腳本與秒數寫在 `triggers.js` 的 `EMERGENCY_SCRIPT`，
狀態機在 [`emergency.js`](../../cloud/prototype/src/agents/emergency.js)：

| 步驟 | 對長輩說（TTS） | 等待 | 無回應則 |
|---|---|---|---|
| 觸發 | 「我聽到您說『救命』了，我在這裡。請問您現在還好嗎？可以回我一聲嗎？」 | 10s | 進下一步 |
| 逾時① | 「我沒有聽到您的聲音。如果您沒事，請說『我沒事』；需要幫忙，說一聲就好。」 | 12s | **升級派遣** |
| 升級 | 「別擔心，志工已經在路上，大約 N 分鐘到，我會一直陪著您。」 | — | — |
| 解除 | 長輩說「我沒事」→「好，聽到您沒事我就放心了，有需要叫我『金孫』就好。」 | — | 結束、不派遣 |

- 總確認窗口 ≈ 22 秒，守住約束「疑似跌倒 20 秒內升級」的精神；秒數可在 config 調。
- **升級動作** = 寫 `radio_events(status=escalated, severity=emergency)` + `dispatch_tasks(kind=emergency)`
  → 觸發家屬推播＋志工派遣單（既有鏈路）。
- 相機偵測到的「疑似跌倒」仍走既有 20 秒單階梯；本階梯是給「語音主動求救」用。

## 5. 六個 Agent 職責

| Agent | 進 LLM？ | 職責 | 輸出 |
|---|---|---|---|
| Intent | 是（rule 未命中才問） | 只分類：emergency/need/device/general | 一個標籤 |
| Emergency | 對話 | 逾時階梯、安撫、升級派遣 | TTS 文字 + 升級 |
| Needs | 是 | 抽出物資／代辦品項 | TTS 文字 + supply 派遣單 |
| Conversation | 是 | 陪伴聊天，帶記憶 | TTS 文字 |
| Memory | 輕量（可 LLM） | 記住反覆狀態/偏好 | 供 Conversation 呼應 |
| Device | 否 | 音量／停止／重說 | 裝置指令 |

Orchestrator（[`orchestrator.js`](../../cloud/prototype/src/orchestrator.js)）：
先看「是否在急救對話中」，再 rule 快路徑＋Intent 分類，最後分派。安全預設：**急救對話進行中，
長輩的後續發言（非『我沒事』）一律留在急救情境**，不會被誤切成聊天。

## 6. AWS 對應

| 原型模組 | AWS 正式服務 |
|---|---|
| `server.js`（HTTP /voice） | API Gateway + Lambda（或 IoT Core rule → Lambda） |
| `agents/intent|needs|conversation` + `llm/bedrock.js` | **Amazon Bedrock（Claude）** |
| `agents/emergency.js`（逾時階梯狀態機） | **Step Functions**（含 wait state） |
| `agents/memory.js` | DynamoDB |
| `dispatch.js`（寫事件/派遣） | Step Functions + 既有資料層；即時推播 AppSync |
| Device Agent 指令下發 | IoT Core（MQTT）→ 裝置 |
| 通知家屬/志工 | 既有三端推播鏈路（不重造） |

Agent 間若要非同步解耦，用 EventBridge / SQS；監控用 CloudWatch。

## 7. 待決定

- **品牌／喚醒詞**：目前預設「小金孫」，需產品定案（影響裝置端本地喚醒模型訓練）。
- 逾時秒數（10s / 12s）需場域驗證微調。
- ~~裝置端是否具備本地 ASR 算力~~ → **已定案：ASR 走雲端服務**（實測用 faster-whisper Breeze-ASR-26，見第 2 節、`hardware-integration.md`）；device-side STT 改列未來隱私強化方向。
- Cognito 角色與這個 Server 的認證串接（長輩裝置以 device_serial 綁定 elder）。
