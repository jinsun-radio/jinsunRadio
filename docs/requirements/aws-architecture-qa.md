# 架構圖 Q&A · 評審備詢

> 對象：看完 [`docs/assets/aws-architecture.drawio`](../assets/aws-architecture.drawio) 之後的提問。
> 撰寫於 2026-08-02。每題都是「一句話先答完 → 追問才展開」的格式，數字一律取自實測。
> 佐證來源：[`aws-architecture.md`](aws-architecture.md)（設計理由與實測數據）、
> [`aws-handoff.md`](aws-handoff.md)（環境識別碼與踩雷紀錄）、
> [`hardware-integration.md`](hardware-integration.md)（裝置契約）。
>
> **一句話講完整套系統**：長輩家裡一台沒有螢幕的收音機，偵測到疑似跌倒後語音問候，
> 20 秒沒回應就自動升級——推播家屬、開派遣單、就近媒合志工，全程在 AWS 上跑閉環，
> 而**影像永遠不離開那個家**。

---

## 目錄

- [A. 一分鐘看懂這張圖](#a-一分鐘看懂這張圖)
- [B. 架構選型（最常被問）](#b-架構選型最常被問)
- [C. 隱私與資安](#c-隱私與資安)
- [D. AI 的部分](#d-ai-的部分)
- [E. 可靠性與規模](#e-可靠性與規模)
- [F. 圖上細節的追問](#f-圖上細節的追問)
- [G. 誠實面對的缺口](#g-誠實面對的缺口)
- [H. 一頁速查表](#h-一頁速查表)

---

## A. 一分鐘看懂這張圖

圖上有兩條進雲的路，這是理解整張圖的關鍵：

| | 誰在用 | 走哪 | 為什麼分開 |
|---|---|---|---|
| **上行** | 收音機 | HTTPS → API Gateway | 事件與文字，請求／回應，同步拿到要立刻播的那句話 |
| **下行** | 收音機 | IoT Core MQTT → 裝置 | 雲端要「主動」對長輩說話，HTTPS 做不到 |

四端（長輩／家屬／志工／社工）是同一套 Flutter 程式碼，走 CloudFront + S3 靜態站，
資料一律打 `/data/*` 並帶 Cognito 的 JWT。

**黃金鏈路**（整套系統的核心，20 秒）：

```
疑似跌倒 → jinsun-voice 同步回一句「阿春，您還好嗎？」→ 寫 radio_events(attention)
        → Step Functions 開始計時
        ├─ T0+8s   沒回應 → jinsun-speak → IoT Core publish →「我沒有聽到您的聲音…」
        └─ T0+20s  仍沒回應 → 升級：開派遣單、就近派志工、推播家屬、長輩燈號轉紅
長輩若回「我沒事」→ StopExecution，整條升級鏈當場中止
```

---

## B. 架構選型（最常被問）

### Q1. 為什麼 20 秒的計時器要用 Step Functions？程式裡寫個 `setTimeout` 不就好了？

**因為計時器不能活在單一行程的記憶體裡。** 原本的 `emergency.js` 就是 `setTimeout`——
只要那個行程重啟、擴容、被回收，正在等待的那位長輩就永遠等不到升級，而且**不會有任何錯誤訊息**。
這是我們認定的單一最高風險，所以是遷移清單裡的第一項。

追問時可以展開三個實作細節，都是實測踩出來的：

1. **不能用相對 `Wait`。** 用 `Seconds: 8` / `Seconds: 12` 時，每一步的轉場開銷會累積，
   實測升級落在 **21.55 秒、超窗 1.55 秒**。改成絕對時間戳（`TimestampPath`）後，
   各步偏差彼此獨立且有界，穩定落在 **T0+20.11s**。
2. **Step Functions 不能直接發 MQTT。** AWS SDK 整合清單沒有 IoT Data Plane，
   `aws-sdk:iotdata:publish` 會 `SCHEMA_VALIDATION_FAILED`，一律要經 `jinsun-speak` Lambda 代打。
3. **選 Standard 不選 Express**，因為 Standard 保留完整執行歷史——
   每一次升級的完整時間戳，正好就是政府稽核要的證據鏈。成本一天 100 次事件約 $0.02/月。

**解除路徑也驗過**：長輩說「我沒事」→ 用 DynamoDB 存的 `executionArn` 呼叫 `StopExecution`，
execution 轉 `ABORTED`，後續 25 秒收音機零指令。

---

### Q2. 為什麼是 Lambda 而不是一直開著的容器？

**因為這個系統的流量長相是「絕大多數時間沒事，有事的時候要在 20 秒內走完一條多步驟鏈路」。**
常駐容器在 99% 的時間是空轉付費，而 Lambda 的冷啟（實測 `jinsun-tts` 冷啟 329ms、熱 225ms）
相對 20 秒的窗口可以忽略。

補充一個**誠實的背景**：我們原本也準備了容器那條路當保底（`deploy/aws/`），
但實測 App Runner 在主辦帳號被 SCP 擋死（`no service control policy allows apprunner:ListServices`），
後來改寫成 ECS Fargate + ALB，但**那條沒有實跑過**。目前真正在跑的是 Lambda 這條。

---

### Q3. 為什麼資料庫選 Aurora（關聯式），而不是全用 DynamoDB？

**因為業務本身就是關聯式的，而且我們有一份已經在正式環境跑過的 schema。**

長輩 ↔ 家屬綁定 ↔ 派遣單 ↔ 志工 ↔ 聊天訊息 ↔ 時間銀行點數，共 13 張表、彼此都有外鍵。
硬要壓成 DynamoDB 的 single-table design，等於重新設計整個資料模型——
在有限時間內這是高風險低報酬。實際做法是 `transform-schema.mjs` 從
`cloud/supabase/schema.sql` 自動轉出 Aurora 版本（只砍掉 Supabase 專屬的四塊），
**兩套環境共用同一份 schema 定義**。

**DynamoDB 我們也在用**，但只用在它擅長的三件事——都是 key-value 且都設了 TTL：

| 表 | 用途 |
|---|---|
| `jinsun_emergency_sessions` | 誰正在等回應、對應的 Step Functions execution ARN |
| `jinsun_progress_announced` | 播報去重（同一張單不重複念） |
| `jinsun_downlink` | 下行扇出佇列，給瀏覽器版硬體模擬器長輪詢用 |

---

### Q4. Aurora 在 VPC 裡，但 Lambda 不在 VPC，這樣連得到嗎？安全嗎？

**走 RDS Data API**，那是一個 HTTPS 端點，用 IAM 授權，所以 Lambda 不必進 VPC。

這帶來兩個好處：**沒有 VPC 冷啟延遲**（ENI 附掛會讓冷啟多好幾秒，直接吃掉黃金窗），
以及**資料庫沒有對外的網路路徑**——它待在 private subnet，誰都連不進去，
存取一律經過 IAM + Secrets Manager（主密碼由 RDS 託管輪替，無人經手）。

另一個容易被追問的點：**Aurora 的最小容量刻意設 0.5 ACU 而不是 0。**
Serverless v2 從零擴容約 15 秒，那會直接吃掉 20 秒黃金窗。代價是它成為整套環境
**唯一持續計費**的資源（約 $43/月）。這是我們明知成本仍然選的——救命鏈路不能等資料庫醒來。

---

### Q5. 為什麼三端是「輪詢」而不是 AppSync 訂閱？這樣不夠即時吧？

**這題我們準備了，而且第一個理由是決定性的：訂閱對最重要的那條鏈路根本不會響。**

AppSync 的 subscription 只在「經過 AppSync 的 mutation」時觸發。但 20 秒逾時升級、開派遣單，
是 Step Functions 叫 Lambda **直接寫 Aurora**——黃金鏈路刻意不繞路。
要讓訂閱響，就得讓每一支後端 Lambda 寫完資料庫後反手再呼叫一次 AppSync publish，
**多一個相依、多一個失敗點，而那個失敗點正好落在系統最不能失敗的地方。**

第二，這個系統的即時性標準是 20 秒，不是 200 毫秒。而且做法不是笨輪詢：

- `GET /data/version` 回六張表的**變更指紋**，App 每 3 秒打一次，指紋沒變就不抓快照。
- 指紋不是 `count(*)` + `max(時間)`——事件從 `open` 翻成 `escalated`、燈號從黃翻紅，
  這兩件事都不新增列也不動時間欄位，卻正是最需要立刻反映的變化，所以指紋涵蓋「會影響畫面的欄位」本身。
- **使用者自己的動作永遠是即時的**：每次寫入後立刻強制抓一次快照。3 秒只發生在「別人動的」。

第三個理由是誠實的：交接當下 AWS 憑證已過期，AppSync 無法實際部署驗證，
**一套沒跑過的訂閱鏈路不該進 demo。**

要升級成真訂閱時**介面完全不必動**——`AwsBackend` 對外仍是那 8 個 `Stream`，
只要把 `_tick()` 換成訂閱回呼。

---

### Q6. 這張圖的單點故障在哪裡？

誠實列給評審看，比被問出來好：

| 元件 | 掛掉的後果 | 現況 |
|---|---|---|
| **Aurora** | 派遣、快照全停；語音對話仍可回應 | 單一 cluster，無跨區。Demo 規模的取捨 |
| **IoT Core** | 雲端無法主動對長輩說話（上行仍通） | 區域級服務，AWS 託管 |
| **Bedrock** | 對話降級 | `llm/bedrock.js` 有三段 fallback（bedrock → mock），不會整條斷 |
| **API Gateway** | 上行全斷 | 唯一入口，是真正的單點 |
| **SageMaker ASR endpoint** | 長輩講話沒人聽得懂 | 單一 endpoint。韌體裡保留 XCC Gateway 為註解掉的備援，換兩行重燒即切回 |
| 台語 TTS（ATEN） | 台語念不出來 | **非 AWS**，且 Polly 無閩南語音色，目前無等價替代 |

Demo 當天的保底：Render 那套環境仍在線，韌體開頭 `#define BACKEND_AWS 0` 重燒即切回。
⚠️ 但切回去等於換一套資料庫，家屬 App 也要一起切。

---

## C. 隱私與資安

### Q7. 相機會拍到長輩，影像會傳到雲端嗎？

**不會，而且這是我們寫死在架構約束裡的第一條：影像永遠不離開那個家。**

跌倒推論在裝置端的 Himax WiseEye2 上做，**跨越裝置與雲端那條線的只有「事件」與「文字」**。
唯一會上雲的音訊，是長輩**主動觸發**的那一段（按住按鈕、或本地 NPU 聽到求救聲），
上傳做 ASR、轉成文字之後就結束——`POST /voice` 的契約**只收文字，不收音檔**。

追問「怎麼保證不是嘴上說說」時，答**在 IAM 層強制**：
裝置憑證的 IoT Policy 不授予任何 S3 或媒體上傳權限，裝置在技術上就沒有把影像送上去的能力。

還有一個設計細節值得講，它顯示我們對「誤報」的態度：
本地音訊分類聽到**撞擊聲絕不單獨上報**，只開一扇 3 秒佐證窗，
窗內再聽到求救聲才判定跌倒。寧可漏，不要天天誤報把長輩的信任耗光。

---

### Q8. 裝置怎麼認證？會不會有人冒充收音機發假的求救訊號？

**IoT Core 用 per-device 的 X.509 雙向 TLS**，而且 policy 用 `${iot:Connection.Thing.ThingName}`
變數限縮，每台裝置**只能**訂閱與發布自己的 topic：

```json
"iot:Subscribe" → "topicfilter/jinsun/${iot:Connection.Thing.ThingName}/cmd"
"iot:Publish"   → "topic/jinsun/${iot:Connection.Thing.ThingName}/status"
```

這一步同時解掉了正式環境的一個真實資安洞：那邊用的是公共 MQTT broker（`mqttgo.io`），
**無認證，任何人都能 publish `jinsun/#`**——也就是任何人都能叫任何一台收音機說任何話。
搬上 IoT Core 是這次遷移在資安上最實質的改善。

（一個除錯 SOP 值得順帶講，顯示我們真的踩過：IoT Core 對授權失敗是**直接切斷連線**、
不回 SUBACK 128，所以 topic 打錯一個字，症狀會長得像「網路不穩」。）

---

### Q9. Supabase 的 RLS 拿掉之後，越權怎麼防？

**改寫成 `cloud/aws/lambda/data/authz.mjs`，分讀寫兩層，而且比原本嚴格。**

坦白講，原環境的 RLS 其實是 demo 全開（`for select using (true)`），不能照搬也不值得照搬。

- **讀**：角色 → SQL 述詞。家屬只看得到 `family_bindings` 綁定的長輩；
  志工只看得到指派給自己或已開放搶的單；社工全看。**沒有角色＝什麼都看不到**（預設拒絕）。
- **寫**：op → 允許角色白名單 + 擁有權檢查。未知 op 一律拒絕。

兩個刻意的收緊，可以主動講出來：

1. **社工角色不能自助註冊。** `worker` 在授權表裡是「全看全改」，
   如果註冊表單自己選就能當社工，整套授權等於沒做。`jinsun-auth` 的 PostConfirmation
   只接受 `family` / `volunteer`，其餘一律退回 `family`——**這條實測過，申請 `worker` 確實被降級**。
2. **角色只認 Cognito Group，不認自訂屬性。** `custom:role` 使用者自己就能改。

實測擋下的越權：家屬改注記（社工限定）、志工改別人位置、家屬碰未綁定的長輩、未知 op。

---

### Q10. 長輩端沒有 UI，那它怎麼登入？那組帳密會不會是破口？

長輩端是**裝置帳號**，不是人的帳號——架構約束 2 說長輩不用 App、不用螢幕，
不可能叫他登入，所以帳密在 build 時用 `--dart-define` 注入、開網頁自動登入。

**破口風險用最小權限收斂**：那個帳號只綁定 elder-1，在 `/data/snapshot` 只看得到林阿春一位。
一台收音機就是一位長輩的，看得到別人反而才是授權破口。要再開一台就另建一組帳號綁對應長輩。

---

### Q11. 資料加密與保存多久？

| 面向 | 做法 |
|---|---|
| 傳輸 | 全鏈路 TLS 1.2+（IoT MQTT 8883、API Gateway HTTPS、Aurora Data API） |
| 靜態 | Aurora / DynamoDB / S3 加密；`radio_events.transcript` 與 `task_messages.text` 含個人對話內容 |
| 金鑰 | Aurora 主密碼由 Secrets Manager 託管輪替；外部服務 PAT 存 Lambda 環境變數，不進版控、不進前端封包 |
| 稽核 | Step Functions 執行歷史保留每一次升級的完整時間戳 |
| 語音檔 | ASR 完成即刪，不落地 |

⚠️ **一個要誠實承認的缺口**：CloudWatch Logs 目前**沒有設 retention，等於永久保留**。
正式上線前必須設定，這已列在賽後清理清單。

---

## D. AI 的部分

### Q12. 用了哪些模型？為什麼是這幾顆？

| 用途 | 模型 | 理由 |
|---|---|---|
| 意圖分類（量大、要快要便宜） | `us.anthropic.claude-haiku-4-5` | `llm()` 的 `fast` 參數已做好分流 |
| 陪伴對話、需求解析 | `us.anthropic.claude-sonnet-4-6` | 實測延遲 2.7–3.2s |

**誠實補充**：這個帳號只授權這兩顆。Opus 5 / Sonnet 5 / Opus 4.8 全部 `AccessDenied`，
換 API key、換區域都試過，是帳號層級的 entitlement。實測下來 Sonnet 4.6 的品質與延遲可接受。

一個值得講的細節，顯示我們真的在意長輩體驗：**換到 Bedrock 之後跑了語氣驗收**，
浮現兩個問題——模型會用「阿公／阿嬤」稱呼長輩（專案已定案移除稱謂），
以及回覆結尾加 emoji（**輸出直接送進 TTS，emoji 念不出來**）。兩者都已在 system prompt 修正。

---

### Q13. 台語怎麼辦？AWS 有支援嗎？

**沒有，這是我們自己補的。** Transcribe 沒有台語，Polly 也沒有閩南語音色。

| | 服務 | 誰在用 |
|---|---|---|
| **ASR** | SageMaker endpoint `breeze-asr-26`（`ml.g4dn.xlarge`，faster-whisper Breeze-ASR-26 fp16） | **收音機**（韌體直打，已接線） |
| **ASR（備援／網頁版）** | 外部 XCC Gateway，經 `jinsun-voice` 的 `POST /asr` 代理 | 長輩端網頁版；韌體裡保留為註解掉的備援 |
| **TTS 國語** | Amazon Polly Zhiyu neural（`jinsun-tts` Lambda） | 兩套環境共用 |
| **TTS 台語** | 外部 ATEN（`kws.oaselab.org`） | 裝置端直連 |

刻意**不把 ASR 換成 Transcribe**——它沒有台語，而語音是長輩唯一的輸入方式，
為了少一個外部相依而讓一半使用者不能用，不划算。所以我們自己在 SageMaker 上跑 Breeze-ASR-26。

Polly 那條有個實測細節可以講：**原始輸出偏小聲**（峰值只到 −10.0 dBFS），上板聽就是不清楚。
修法是在 Lambda 做峰值正規化到 −1 dBFS（實測 +9.0 dB、零削頂、長度不變所以語速沒跑掉）。
刻意不從韌體的音量調——那樣會連台語 TTS 一起變大聲。

**這條已經接起來了，而且值得主動講**——它是「不依賴別人的服務」的關鍵一步。
SageMaker 的傳輸層強制 AWS SigV4 簽章，所以 endpoint 不能直接 curl，也不該把 IAM 憑證燒進韌體。
我們補了一支 `jinsun-asr-openai` Lambda 當門面，把它開成 OpenAI 相容的
`POST /v1/audio/transcriptions`，韌體只要換 host 與金鑰、**組請求的程式碼一行都沒動**
（那支 Lambda 同時吃 `x-bf-vk` 與 `Authorization: Bearer`，刻意與原本的 gateway 對齊）。

換過來的好處：模型權重與 endpoint 都在自己的 AWS 帳號裡，不再依賴外部 gateway
（那顆是別人的服務、金鑰也是別人發的）。

一個實作上的坑值得講：門面轉發時 **ContentType 刻意標成 `octet-stream` 而不是原本的
`multipart/form-data`**——SageMaker 容器裡的 MMS 看到 multipart 會自己先把 parts 拆掉，
HF toolkit 接著只取名為 `body` 的那一份，handler 收到 `None` 就炸。

---

### Q14. LLM 會不會對長輩亂講話？譬如給錯誤的醫療建議？

**目前的防線是 system prompt，Bedrock Guardrails 還沒設——這是已知缺口。**

服務對象是失能長者，我們認為 Guardrails 是**必須有**的一層（醫療建議、金融詐騙誘導、自傷內容），
已列為下一階段的第一優先。

現階段的實質保護有兩層：
1. 緊急鏈路**不經過 LLM 判斷生死**——「20 秒沒回應就升級」是狀態機的硬規則，不是模型決定的。
   LLM 只負責「怎麼講話」，不負責「要不要救」。
2. 後台可即時切換 LLM 供應商，模型出問題可當場降級。
   ⚠️ 但這裡有個坑我們已經處理：後台選了機器做不到的供應商時會**靜默退回 mock**、
   長輩收到罐頭回覆而不易察覺，所以 Lambda 設 `LLM_PROVIDER_FORCE=bedrock` 跳過後台查詢。

---

### Q15. 為什麼跌倒偵測不放雲端做？雲端模型不是更強？

三個理由，第一個是不能妥協的：

1. **隱私。** 雲端推論代表影像必須上傳，架構約束 1 直接否決。
2. **延遲與可用性。** 網路斷了長輩就沒人守著，這對獨居長者是不可接受的失效模式。
3. **成本。** 24 小時串流影像的頻寬與 GPU 推論費用，不可能規模化到每一戶。

代價是裝置端算力有限。目前 AmebaPro2 的 NPU 已跑**本地音訊分類**（YAMNet），
求救聲會自動開始錄音；⚠️ **視覺跌倒推論本身尚未實作**——flash 已因 YAMNet 從 28% 跳到 84%
（`yamnet_fp16.nb` 就 8.7 MB），再加視覺模型幾乎塞不下，這是要誠實講的硬體限制。

---

## E. 可靠性與規模

### Q16. 家裡網路斷了怎麼辦？

分兩種情況誠實回答：

- **完全斷網**：雲端鏈路失效。實體 SOS 按鈕與本地燈號／鈴聲仍然作動，
  但無法通知家屬。這是目前的真實限制，緩解方向是 4G 備援模組。
- **短暫斷線**：MQTT 有 LWT（`jinsun/{serial}/status`），裝置離線雲端知道；
  重連後恢復訂閱。上行的 HTTPS 請求有重試。

---

### Q17. 20 秒真的準嗎？有實測數字嗎？

有，而且分兩層講比較誠實：

| 量測點 | 實測 |
|---|---|
| Step Functions 狀態機本身 | **T0+20.11s** |
| 家屬 App 畫面上看到「已升級」 | **T0+24s**（含 3 秒的變更指紋輪詢誤差） |
| MQTT 下行投遞 | 14ms |
| Bedrock 對話回應 | 2.7–3.2s |

完整的端到端鏈路已在真 AWS 上跑通並記錄：
疑似跌倒 → 家屬端 3 秒內看到「確認中」→ 20 秒升級 → 開派遣單並就近派給志工
→ 志工接單（重複接單回 409）→ 家屬↔志工聊天 → 到場 → presigned S3 上傳結案照片
→ 結案 → 時間銀行 +21 分 → 長輩燈號回綠。

⚠️ 一個要誠實標註的：上述驗證多數是用 curl 與檢查產出檔完成的，
**UI 層還沒有由真人在瀏覽器完整走過一遍**。這個缺口咬過我們一次——
三端在瀏覽器打 `/data/*` 全部失敗，因為 `OPTIONS` preflight 被 `$default` 路由吃掉回 404，
而 curl 不發 preflight 所以測不出來。已修，並加進 `smoke-test.sh` 的第 3 項。

---

### Q18. 一台變一萬台會怎樣？瓶頸在哪？

先講**不會是瓶頸的**：API Gateway、Lambda、IoT Core、DynamoDB、S3、CloudFront 都隨用量水平擴展。
Step Functions 每個事件一條獨立 execution，彼此不影響。

**會先撞牆的三個**，按先後順序：

1. **Aurora 的 ACU 上限**（目前 0.5–4）。快照查詢是一整句 `json_agg`，長輩數一多會變重。
   解法是提高上限 + 讀取走 read replica，schema 不必動。
2. **輪詢的放大效應**。一萬個 App 每 3 秒打一次 `/data/version` ≈ 3300 QPS。
   這是必須升級成真訂閱的臨界點——介面已經預留好（Q5）。
3. **SageMaker GPU endpoint**。台語 ASR 的 GPU 常開約 $530/月，要改成
   Asynchronous Inference（無請求縮到 0 台）或多台 auto scaling。

規模化的正解不是重寫，而是**把已經預留好的三個開關打開**。

---

### Q19. 成本多少？

Demo 規模（10 台裝置、20 位使用者）估算 **≈ $130–220 / 月**，最大的兩塊是：

| 服務 | 月成本 | 備註 |
|---|---|---|
| SageMaker ASR | $60–90（定時起停）／~$530（常開） | 最大單一支出。⚠️ 它在**正式鏈路上**，起停期間長輩講話沒人聽得懂——demo 前務必確認是 InService |
| Bedrock | $20–45 | Haiku 分類 + Sonnet 對話 |
| Aurora Serverless v2 | $20–45 | **唯一持續計費**，min 0.5 ACU 是為了黃金窗刻意付的 |
| 其餘（IoT / API GW / Lambda / DynamoDB / S3 / CloudFront / Cognito） | 合計 < $10 | 多數在免費額度內 |

成本控制的三招都已內建：意圖分類走 Haiku（`fast` 參數已分流）、
SageMaker 用 EventBridge Scheduler 定時起停、另設 AWS Budgets 告警。

---

## F. 圖上細節的追問

### Q20. 為什麼裝置有兩條線進雲？一條不行嗎？

不行，因為兩條線的**方向性**不同：

- **上行走 HTTPS**：長輩主動說話 → 要**同步**拿到要立刻播的那一句。請求／回應模型最自然。
- **下行走 MQTT**：雲端要**主動**對長輩說話（20 秒升級後的「志工已在路上」）。
  HTTPS 做不到 server push，而 Render 那類 PaaS 只開 443 也擺不了 broker——
  這正是正式環境被迫用公共 broker 會合的原因。IoT Core 一次解決連線與憑證認證兩件事。

### Q21. 圖上寫 publish / subscribe，那是廣播嗎？一台講話全部都聽得到？

**不是廣播，是 per-device topic 的點對點下發。** topic 是 `jinsun/{serial}/cmd`，
`{serial}` 就是那台機器的序號，而 IoT Policy 用 Thing name 變數把裝置鎖死在自己的 topic 上（見 Q8），
訂別人的會被拒。另外 MQTT client id 必須等於 Thing 名稱，憑證也要 attach 到同一個 Thing。

### Q22. 為什麼一定要 CloudFront？S3 靜態網站不就好了？

**因為 S3 網站端點只有 HTTP，而瀏覽器在非 HTTPS 下不給硬體權限。**

- 志工端的 GPS 上報與家屬地圖的志工位置會整條失效。
- 長輩端更嚴重：麥克風同樣要 HTTPS，走 S3 端點的話「按住說話」那顆大按鈕**整個是啞的**。

### Q23. 圖上的 S3 有兩個，差在哪？

左邊那個是**四端 Flutter Web 的靜態站**（`jinsun-{family,volunteer,admin,elder}-web`），
右邊那個是**結案證明照片**（`jinsun-proofs`）——志工到場後拍照結單，走 presigned PUT
**直傳、不經 Lambda**，避免大檔案佔用函式的記憶體與執行時間。

### Q24. 社工後台的 Excel 匯出在圖上哪裡？

它是 `jinsun-data` Lambda 的一條路徑：查 Aurora → 產 xlsx → 寫 S3 → 回 presigned URL。
這是**政府申報的硬需求**（架構約束 4），不是加分項。
資料量放大到全縣市年度申報時，路線是 Aurora → S3(Parquet) → Athena → Step Functions 組表。

---

## G. 誠實面對的缺口

評審一定會問「還有什麼沒做」。主動講完整比被問出來好，也更能顯示我們知道自己在哪。

| 項目 | 狀態 | 影響與計畫 |
|---|---|---|
| **視覺跌倒推論** | ❌ 未實作 | 目前靠本地音訊分類（求救聲）＋ SOS 按鈕觸發。flash 已用到 84%，再塞視覺模型是硬體瓶頸 |
| **Bedrock Guardrails** | ❌ 未設 | 服務對象是失能長者，這是下一階段第一優先（見 Q14） |
| **SNS 背景推播** | ❌ 未接 | `device_tokens` 已會寫進 Aurora，發送端未接。目前 App 在前景才收得到 |
| **AppSync 真訂閱** | ❌ 未建 | **刻意的取捨**（見 Q5），介面已預留 |
| **UI 層真人驗證** | ⚠️ 未完整走過 | 後端 API 全綠但瀏覽器可能另有問題，已被 CORS preflight 咬過一次 |
| **CloudWatch Logs retention** | ⚠️ 未設 | 等於永久保留，正式上線前必須設定 |
| **ECS Fargate 備援路徑** | ⚠️ 已改寫但未實跑 | 不確定帳號 SCP 是否放行 `ecs:*` |

---

### Q25. 為什麼還有另一套 Supabase 環境並存？不會混淆嗎？

**這是刻意的，而且兩套環境完全不共用資料庫。**

AWS 這套（`cloud/aws/`）用自己的 Aurora，與正式環境的 Supabase 徹底斷開。
理由是如果指向同一個資料庫會有三個問題：播報打架（兩邊的 worker 都反應同一筆變化）、
測試污染正式資料（跑一次升級測試就在正式環境開出真的派遣單、推播到真實手機）、
以及那根本不算兩套環境——資料層是單點，一邊改壞 schema 兩邊一起死。

切換點收斂到**兩個地方**，其餘程式碼完全共用：
四端靠 `apps/packages/core/lib/src/backend_factory.dart`（`--dart-define=BACKEND=aws`），
韌體靠 `.ino` 開頭一個 `#define BACKEND_AWS`（topic、payload、QoS、LWT 全部不變）。

唯一兩套共用的是 `jinsun-tts`（Polly）與 ASR gateway——它們是**無狀態服務呼叫、沒有資料落地**，
不違反「不共用資料庫」的原則。

---

## H. 一頁速查表

**最可能被問的五題與一句話答案：**

| 問題 | 一句話 |
|---|---|
| 為什麼 Step Functions？ | 計時器不能活在單一行程記憶體裡，行程一重啟長輩就永遠等不到升級 |
| 為什麼不是訂閱？ | 訂閱對最重要的那條鏈路不會響，而且會把失敗點加在最不能失敗的地方 |
| 影像會上雲嗎？ | 不會，而且是在 IAM 層強制——裝置憑證根本沒有媒體上傳權限 |
| 20 秒準嗎？ | 狀態機 T0+20.11s，家屬端看到是 T0+24s（含 3 秒輪詢誤差） |
| 還有什麼沒做？ | 視覺跌倒推論、Bedrock Guardrails、SNS 背景推播——見 §G |

**三個可以主動秀出來的實測細節**（顯示不是紙上談兵）：

1. 相對 `Wait` 會累積開銷、實測超窗到 21.55s，改絕對時間戳才穩定在 20.11s。
2. `JSON.stringify` 會丟掉 `undefined`——裝置依契約不送 `elder_id`，
   欄位消失導致 ASL 找不到路徑，**每一次真實升級都會炸**。所有進狀態機的欄位一律 `?? null`。
3. `jinsun-progress` 移除 Supabase 依賴時 import 沒清乾淨，Lambda **載入即死**，
   症狀是「什麼都沒發生」——三端畫面正常、資料庫正常，只有長輩那端永遠沒聲音，
   錯誤只進 CloudWatch 的 `INIT_REPORT`，不回到任何呼叫端。

**一句話收尾**：這套系統把「感知 → 決策 → 行動 → 回報」做成閉環，
而 AWS 在其中負責的是**最不能失手的那 20 秒**——
用 Step Functions 保住它跨行程存活，用 IoT Core 保住那句話一定送得到，
用 IAM 保住影像永遠不會離開那個家。
