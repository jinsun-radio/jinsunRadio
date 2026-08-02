# 硬體對接規格（韌體工程師）

長輩端收音機（**HUB8735 Ultra / Realtek RTL8735B・AmebaPro2**）如何 ①由家屬 App 藍牙配網、
②連上雲端語音 Agent server（[`cloud/prototype/`](../../cloud/prototype/)）。看完即可獨立開發；server 已可跑、可對測（第 5 節）。

**裝置角色**：眼睛＋耳朵＋嘴巴（本地 NPU 視覺／聽覺感知、收音、觸發、播放、燈號、SOS 鍵；STT/TTS 呼叫雲端服務；影像與日常聲音永不上雲，只上傳事件）。**雲端＝大腦**（分類、對話、20 秒升級計時、派遣）。
RTL8735B 內建 WiFi + BLE 5.1，Ameba SDK 有 `BLEWifiConfig` 範例。實測韌體
（[`firmware/HUB-8735-Ultra-ASR-TTS.ino`](../../firmware/HUB-8735-Ultra-ASR-TTS.ino)）已跑通
「按鈕錄音 → 雲端 ASR → `POST /voice` → 雲端 TTS → 播放」整條 pipeline，**已接上本契約**：
上行打 Render 上的正式 server（`https://jinsun-voice-server-mg1f.onrender.com`），
下行以 PubSubClient 訂閱 `jinsun/{serial}/cmd`（QoS 1、LWT、退避重連），並支援 `sos`／`fall_suspected`／
`activity_report`／`inactivity_suspected` 事件上報。跌倒偵測由**裝置本地 NPU 視覺推論**觸發
（YOLO person 偵測，人形框 w/h > 1.3 持續 3 秒判定疑似跌倒；感知層設計見
[`../architecture.md`](../architecture.md) 的「長輩端本地感知層」）；序列埠指令 `sos`／`fall`
保留可模擬全鏈路（NN 模型停用時仍可 demo）。

---

## 1. STT / TTS 走雲端服務（依實測韌體修正）

- **STT 在雲端**：裝置只在長輩**主動觸發**時錄音，把該段音檔上傳 ASR 服務
  （現用 faster-whisper Breeze-ASR-26，OpenAI 相容 `/v1/audio/transcriptions`）取得文字，
  再把**文字**送 `POST /voice`。`/voice` 契約不變、仍只收文字；語音 Agent server 不收音檔。
  隱私邊界＝`CLAUDE.md` 約束 1：**只有主動觸發那段語音上雲**，日常聲音與影像不上傳。
  （device-side STT 改列未來隱私強化方向。）
- **觸發方式**：**按住按鈕 1 秒**開始錄音、再按一下結束；另有**聲音事件喚醒（✅ 已實作）**——裝置本地 NPU
  音訊分類（YAMNet，`NNAudioClassification` + `DEFAULT_YAMNET`）偵測到呼救/哭聲/尖叫（distress 類）
  即觸發同一條喚醒錄音流程（錄 8 秒後自動收工，因為沒有人會來按第二下）。撞擊類聲音**絕不單獨觸發**，
  只把 `lastImpactAt` 記下來開一扇 3 秒佐證窗；窗內若再聽到 distress 才判定高信心跌倒、
  直接送 `event:"fall_suspected"`（跳過問診——摔在地上的人可能已經講不出完整句子）。
  `recentImpact()` 也預留給之後的視覺跌倒推論當第二訊號源。開機 log（`[SND] 喚醒模式：…`）標明目前模式與門檻。
  ⚠️ 未做：**模型載入失敗時退回音量門檻**——`NNAudioClassification::begin()` 回傳 void、SDK 也沒有
  查詢載入結果的 API，目前只能靠編譯期的 `ENABLE_SOUND_DETECTION` 開關切回純按鈕模式。
  「小金孫」喚醒詞＋**離線急救詞**「救命」（聽到就先亮燈/響鈴並以 `event:"sos"` 上報，不依賴網路）
  仍為待辦——YAMNet 是**聲音場景分類器、不是關鍵字辨識器**，它分得出「有人在大聲喊」但分不出喊的是什麼字；
  不依賴網路的求救以實體 SOS 鍵為主。
- **TTS 在雲端，且依 `lang` 分流到兩顆服務**（✅ 已實作）。下行 `speak` 帶 `lang`（`mandarin`/`taigi`），
  `text` 一律漢字（台語也是），裝置依 `lang` 選 TTS：

  | `lang` | 服務 | 回應形式 |
  |---|---|---|
  | `taigi` | **ATEN**（`kws.oaselab.org`）——**台語模型** | JSON `{status,url}` → 第二條連線抓 WAV 串流播放 |
  | `mandarin` | **Amazon Polly**（Zhiyu，`jinsun-tts` Lambda，`POST /tts`） | 帶 `Accept: audio/wav` → 直接回 WAV bytes，POST 完就邊收邊播 |

  `POST /tts` 同一條路由服務兩種呼叫者，靠 `Accept` 分辨：韌體帶 `audio/wav` 拿二進位；
  長輩端網頁版不帶，拿回 `{status,url}`（`url` 是 `data:audio/mpeg;base64,…`），
  沿用它原本打 Render `/tts` 的介面，前端不用改。

  **2026-08-01 已部署並上板實測通過**（`https://yr0ep335el.execute-api.us-west-2.amazonaws.com/tts`）：
  23 字 →`content-length: 142444`、**沒有 `transfer-encoding: chunked`**（韌體直接串流成立的前提）、
  4.45 秒 16kHz mono WAV，`amp.playWavStream()` 實機播放正常。
  Lambda 冷啟 329 ms／熱 225 ms／快取命中 3 ms，Polly neural 一次就過。
  同一句給瀏覽器的 mp3 是 27 KB（wav 的 1/5.3）。

  ⚠️ **Polly 的原始輸出偏小聲**（實測峰值只到 −10.0 dBFS、RMS −22.7），上板聽就是「有點小聲」。
  修法是在 Lambda 做**峰值正規化**到 −1 dBFS（`normalizePcm()`，實測 +9.0 dB、零削頂、
  長度不變所以語速語氣沒動）。**刻意不從韌體的 `ampVolume` 調**：它預設 0.8、上限 1.0，
  只剩 1.9 dB 可補，而且一調就連 ATEN（台語）也一起變大聲。
  目標值可用環境變數 `TTS_PEAK_DBFS`（預設 −1）與 `TTS_MAX_GAIN_DB`（預設 12）改。
  mp3（瀏覽器）那條不正規化——拿回來已是編碼後資料，且瀏覽器本來就有音量可調。
  ⚠️ AWS 這側**沒有台語 TTS**（Render 那台的 `/tts` 有代打 ATEN，這裡沒有），
  `lang=taigi` 回 404 讓網頁版整個 session 退回瀏覽器語音。裝置端不受影響——它自己直連 ATEN。

  ⚠️ **ATEN 那顆端點不吃 voice/lang 參數**（已確認），它只會講台語——所以國語一定得另一顆服務，
  這就是 Polly 那條路存在的原因。Polly 不可用時退回 ATEN（寧可語言不對也不要安靜），序列埠會印
  `[TTS] ⚠️ 國語 TTS 不可用 → 退回 ATEN`。
  Polly 端點刻意不隨 `BACKEND_AWS` 切換：TTS 是無狀態服務呼叫、沒有資料落地，
  與 ASR gateway 一樣兩套環境共用，不違反「不共用資料庫」。
- ASR／TTS 服務選型可抽換（.ino 開頭常數），不影響下列任何 API 契約。

## 2. 家屬 App 藍牙配網（BLE Provisioning）

長輩端無螢幕，到府安裝時家屬用手機 App 幫收音機設定 WiFi。裝置沒設過 WiFi 時進配網模式廣播 BLE，**廣播名稱以序號開頭（`JS-xxxx`）**，並廣播下方 provisioning 服務 UUID 供 App 過濾。

**家屬 App 端已實作**（`apps/family_app/lib/services/radio_ble.dart` + `screens/pairing_screen.dart`，用 `flutter_blue_plus`）。七步驟流程：搜尋藍牙 → 建立連線 → 選 Wi-Fi → 輸入密碼 → 透過 BLE 傳送 → 裝置連上 Wi-Fi → 完成（並以序號綁定長輩）。**韌體端請照下表複刻同一組 UUID 與 status 字串**（`RadioBleContract`）：

Provisioning Service UUID：`a1b2c3d4-0001-4a5b-8c6d-1234567890ab`

| Characteristic UUID | 屬性 | 內容 |
|---|---|---|
| `…-0002-…` `chSsid` | write | 選定的 Wi-Fi SSID（UTF-8 純字串） |
| `…-0003-…` `chPass` | write | Wi-Fi 密碼（UTF-8；BLE 加密連線後才收） |
| `…-0004-…` `chWifiList` | read/notify | 裝置掃到的 AP 清單，SSID 以 `\n` 分隔（可空→App 改手動輸入） |
| `…-0005-…` `chStatus` | read/notify | 佈建狀態字串（見下） |
| `…-0006-…` `chSerial` | read | `device_serial`（如 `JS-0001`，供綁定；缺此特徵值時 App 退回用廣播名） |

`chStatus` 允許的字串（App 大小寫不敏感）：`idle`｜`connecting`｜`connected`（或 `ok`）｜`wrong_password`（或 `auth_fail`）｜其它視為 `error`。App 寫入 SSID+密碼後訂閱 `chStatus`，收到 `connected` 即視為成功、`wrong_password` 退回密碼頁、40 秒無結果視為逾時。

安全：BLE LE Secure Connections 加密後才收密碼；配網視窗限時＋長按 SOS 才進配網（防劫持）。密碼只經 BLE 直傳裝置、**不上雲**。配好後 App 讀 `chSerial` 取得序號，寫入 `family_bindings` 與比對 `elders.device_serial` 完成綁定。UUID 需實機驗 GATT。

> Web 版不支援 BLE（`FlutterBluePlus.isSupported` 回 false），配對頁會提示改用序號／QR 綁定；藍牙配對僅在 iOS／Android App 可用。

## 3. API（裝置 ↔ server）

上行由裝置打 server（`POST /voice`）；**下行走 MQTT push**——裝置開機連上 MQTT broker、訂閱自己的 topic 並保持連線，server 有話要說就 publish，裝置收到 JSON 立刻觸發 TTS 發聲。`BASE_URL`（HTTP）與 `MQTT_URL`（broker）都做成可設定：本機同區網用 `http://<開發機IP>:8787`／`mqtt://<開發機IP>:1883`，正式接 API Gateway／AWS IoT Core。

**目前的正式部署（Render）**：`BASE_URL = https://jinsun-voice-server-mg1f.onrender.com`。
⚠️ Render 這類 PaaS 對外只開 HTTPS（443），server 內嵌的 aedes broker（1883）從公網進不來——
所以 **server 與裝置各自連到同一顆外部 broker 會合**：broker 用 **mqttgo.io**（台灣主機、
TLS 8883 實測 OK、憑證 Let's Encrypt／鏈根 ISRG Root X1）。server 在 Render 設環境變數
`MQTT_URL=mqtts://mqttgo.io:8883`（`src/mqtt.js` 會從內嵌 broker 模式切成 client 模式，
Let's Encrypt 在系統信任清單內、不需附 CA 檔；topic／payload 契約不變）；裝置韌體的
`mqtt_server` 指向 `mqttgo.io:8883`、`setRootCA` 用 ISRG Root X1。
⚠️ 裝置一律走 TLS 8883：此核心純 TCP（`WiFiClient`）收不到任何回應資料，僅 `WiFiSSLClient` 可靠。
⚠️ 板子無 RTC/NTP、開機強設時鐘，而 Let's Encrypt 是 90 天短效憑證——重燒韌體時記得把
`tv.tv_sec` 更新到接近當天，否則憑證驗證會失敗。
公共 broker 無認證、demo 專用；正式換 AWS IoT Core（換 endpoint＋憑證即可）。
另注意 Render 免費方案閒置會休眠，冷啟動可能 30–60 秒才回應，韌體上行逾時已放寬到 60 秒。

### ① 上行 `POST {BASE_URL}/voice`（同步拿要立刻播的話）
```jsonc
// 請求（擇一）
{ "device_serial":"JS-0001", "text":"我想買牛奶跟雞蛋" }   // 一般語音（STT 後文字）
{ "device_serial":"JS-0001", "event":"sos" }             // SOS 鍵／舉手求救確認後（=救命，立即升級不問診）
{ "device_serial":"JS-0001", "event":"fall_suspected" }  // 相機本地 NN 偵測疑似跌倒
{ "device_serial":"JS-0001", "event":"activity_report",
  "summary":[true,false /* …共 24 格 */] }               // 每日活動摘要（boolean[24]，第 N 格＝第 N 小時有無人形活動）
{ "device_serial":"JS-0001", "event":"inactivity_suspected" }  // 日間連續 6 小時未偵測到人形（無額外欄位）
// 回應 200
{ "reply":"…立刻 TTS…", "intent":"emergency|need|device|general",
  "action":{ "command":"volume_up" } }   // action.command 有值才執行裝置動作
```
裝置：POST → 播 `reply` →（有 `action.command` 就執行）。**不要送 `elder_id`**，server 靠 `device_serial` 反查。

**活動類事件**（server 在進問診鏈路前分流，不走 sos/fall_suspected 的派遣問診；既有兩型別形狀不變）：

- `activity_report`：**每日固定時段上報一次**，`summary` 為 24 格布林陣列（第 N 格＝第 N 小時有無人形活動）。
  server 回 **200、無 `reply`（不產生語音回覆）、不產生派遣**，僅寫資料層（家屬 App 安心日報資料源）。
  上行失敗**裝置端靜默丟棄**（非緊急資料，次日報表補上）。
- `inactivity_suspected`：無額外欄位；**僅日間時段**連續 6 小時未偵測到人形時**上報一次**（下次偵測到人形即重置）。
  server 產生「**注意**」級家屬通知、**不派志工**。上行失敗**裝置端重試一次**（比照 `sos`）。
- 未知 `event` 值：維持既有 **400** 行為不變。

### ② 下行 MQTT（server publish → 裝置）

裝置開機連上 broker（原型：server 內嵌的 **aedes**，`mqtt://<開發機IP>:1883`）、訂閱自己的 topic，之後保持連線；server 有話要說（急救逾時階梯、進度播報）就 publish：

```jsonc
// topic: jinsun/{device_serial}/cmd（例：jinsun/JS-0001/cmd），payload：
{ "commands":[
    { "type":"speak",  "text":"志工林志明大約 8 分鐘就到，您再等一下喔。", "lang":"taigi" }, // 依 lang 選語音 TTS
    { "type":"device", "command":"volume_up" }   // volume_up/volume_down/stop_speak/repeat
] }
```
裝置收到後逐一執行：`speak` → 文字送 TTS 服務 → 串流播放；`device` → 執行指令。

> **`text` 一律是正常中文（國語書寫），雲端不做台語翻譯。** 台語由**裝置端 TTS 依 `lang` 自行把中文念成台語**（`lang` 只是選語音的旗標，不改變文字內容）。所以同一句 `text` 不論 `lang` 是 `mandarin` 或 `taigi` 都相同；`reply`（上行 `POST /voice` 的回覆）也同此規則。
>
> ✅ **已聽過確認：ATEN 台語 TTS 餵國語書寫念得出來、沒問題。** 這條原本是有風險的假設——台語 TTS 通常期待台文漢字或台羅（「雞蛋」台文寫作「雞卵」），餵國語書寫有可能念得生硬。實聽後確認可行，所以**雲端維持不做台語翻譯**、`jinsun-voice` 的 prompt 不用為 `lang` 分岔，`text` 兩種語言共用一份。

連線參數：client id ＝ `device_serial`；**QoS 1**（至少送達一次，斷線重連後 broker 補投）；keep-alive 30s；
斷線**指數退避重連**（1s→2s→…上限 30s），重連後重新 subscribe。
⚠️ **`cleanSession` 必須為 false**——否則 broker 一斷線就丟掉 session，QoS 1 的離線補投完全不會發生，
急救逾時階梯的指令只要遇上一次短暫斷線就永遠消失。注意 PubSubClient 的 7 參數 `connect()` 多載把
`cleanSession` 寫死成 true，**要用帶 `cleanSession` 的 8 參數版本**。
（2026-07-26 實測 mqttgo.io 支援持久 session：斷線期間 publish 的 QoS 1 訊息，重連後 `sessionPresent=true` 並確實補投。）
**上下線偵測**：連上時 publish `jinsun/{serial}/status` = `online`，並設 Last Will 同 topic = `offline`
——broker 偵測到斷線自動發布，後台「裝置離線」顯示免費取得，不需要另做心跳。

⚠️ **這則 status publish 走 QoS 0、且不得帶 RETAIN**（2026-08-01 實測踩到，別再「順手改成 QoS 1」）。
上面那句「QoS 1」指的是**下行指令的 subscribe**，不是這則 status。在 AmebaPro2 的 PubSubClient 上
呼叫 `setPublishQos(1)` 會**打開 RETAIN 旗標而不是設 QoS 1**（該 API 收的是已位移的 `MQTTQOS1`＝2，
而實作 `header |= pub_qos` 的 bit 0 正好是 RETAIN），而 AWS IoT 對保留訊息要求額外的
`iot:RetainPublish` 權限 → 被拒 → **IoT Core 在 CONNECT 成功後約 500ms 直接關閉連線、不回任何錯誤碼**，
症狀是無限重連且所有 Thing／憑證／policy 都查不出問題。完整分析見
[`firmware/HUB-8735-Ultra-ASR-TTS/README.md`](../../firmware/HUB-8735-Ultra-ASR-TTS/README.md) 的
「MQTT 一直重連」。可靠性不受影響：離線由 LWT 負責，需要保證投遞的下行指令靠 subscribe QoS 1 ＋
`cleanSession=false`。

> 為什麼是 MQTT 而不是裝置開 HTTP callback server：MQTT 是裝置**主動向外連 broker 並保持連線**，
> 雲端 push 走這條既有連線——裝置在家用 NAT 後面也收得到，不需要可被公網存取；
> 且「連上 broker」本身就等於註冊，免去 callback URL 註冊與 IP 心跳。正式版換 AWS IoT Core
> 只是換 endpoint＋憑證，topic 與 payload 完全不變。

> ✅ **server 端已實作**（`cloud/prototype/src/mqtt.js`）：內嵌 aedes broker（`MQTT_PORT` 預設 1883），
> enqueue 扇出——同一筆指令走 MQTT publish（真裝置）＋`GET /commands` 長輪詢佇列
> （瀏覽器模擬控制台 sim.html 與 curl 對測用）。未安裝 aedes 時自動降級為僅長輪詢。

### 韌體主迴圈（含錯誤處理）
```c
setup(): load(BASE_URL, MQTT_URL, device_serial); if 無WiFi: BLE配網(); 連WiFi()
         mqtt_connect(MQTT_URL, client_id=device_serial, keepalive=30s, qos=1,
                      will={topic:"jinsun/"+serial+"/status", payload:"offline"})
         subscribe("jinsun/"+serial+"/cmd", on_cmd)
         publish("jinsun/"+serial+"/status", "online")
on_cmd(msg): for c in msg.commands: c.type=="speak"? 雲端TTS播放(c.text, c.lang) : do(c.command)
on mqtt斷線: 指數退避重連(1s→2s→…→30s)；重連後重新 subscribe＋發 online
on 觸發(按鈕/聲音事件喚醒): POST_voice({device_serial, text: 雲端ASR(錄音())})   // 只有這段主動錄音上雲
on SOS鍵/舉手確認: 本地燈號+鈴聲(); POST_voice({device_serial, event:"sos"})
on 本地NN判定跌倒: POST_voice({device_serial, event:"fall_suspected"})
on 每日回報時段: POST_voice({device_serial, event:"activity_report", summary:bool[24]})  // 失敗靜默丟棄，次日補報
on 日間連續6小時無人形: POST_voice({device_serial, event:"inactivity_suspected"})        // 失敗重試一次（比照 sos）
POST_voice(b): r=post(BASE+"/voice", b, 8s); if ok{ if r.reply 雲端TTS播放(r.reply); if r.action.command do(r.action.command) }
               else if b.event=="sos" 本地播("已通知，正在幫您聯絡家人"); retry_backoff()   // SOS 一定要有本地退路
```
要點：下行 QoS 1、斷線退避重連、LWT 上下線；**SOS 上行失敗必須有本地退路**（不能靜默）；`device_serial` 全程固定（＝MQTT client id）。

## 4. 裝置登錄

server 靠 `device_serial` 反查長輩開派遣單。新裝置要先在 `elders` 登錄（正式版由配網自動寫；測試期手動 seed）：
```sql
insert into elders (id, device_serial, name, preferred_lang)
values ('elder-test-01','JS-REAL-0001','測試阿嬤','taigi')
on conflict (id) do update set device_serial=excluded.device_serial;
-- 綁家屬：insert into family_bindings (family_id, elder_id) values ('<家屬 uid>','elder-test-01');
```
`preferred_lang`（`mandarin`/`taigi`）＝長輩偏好語言，家屬在 App 設定，server 產播報時帶進 `speak.lang`。`JS-0001` 是既有種子可直接對測。

## 5. 現在就能測（不用等實機）

server 已接真 Bedrock，用 `curl` 當假裝置驗契約（直接打 Render 正式站即可）：
```bash
BASE=https://jinsun-voice-server-mg1f.onrender.com   # 或本機 http://localhost:8787
curl -s $BASE/health        # 看 mqtt 欄位：client=外部 broker、live=內嵌、off=僅長輪詢
curl -s $BASE/voice -d '{"device_serial":"JS-0001","text":"我想買牛奶跟雞蛋"}'
curl -s $BASE/voice -d '{"device_serial":"JS-0001","event":"sos"}'
curl -s $BASE/voice -d '{"device_serial":"JS-0001","event":"activity_report","summary":[false,false,false,false,false,false,false,true,true,false,false,false,true,false,false,false,false,false,true,false,false,false,false,false]}'   # 回 200、無 reply
curl -s $BASE/voice -d '{"device_serial":"JS-0001","event":"inactivity_suspected"}'   # 「注意」級家屬通知、不派志工
```
下行（Render 部署）用公共 broker mqttgo.io 對測（筆電走 1883 明文即可；板子一律走 TLS 8883。也可用 https://mqttgo.io 網頁儀表板訂閱 `jinsun/#` 現場監看／手動發布）：
```bash
mosquitto_sub -h mqttgo.io -t 'jinsun/JS-0001/cmd' -v       # 當假裝置收 server push
mosquitto_pub -h mqttgo.io -t 'jinsun/JS-0001/cmd' \
  -m '{"commands":[{"type":"speak","text":"測試播報","lang":"mandarin"}]}'   # 手動餵真板子
```

> ✅ **兩種模式都已端對端對測過**（2026-07-26）：
> - 內嵌模式（`npm start`）：`/health` 回 `mqtt:"live"`，假裝置訂閱 `jinsun/JS-0001/cmd` 後打 `/voice`（`text:"救命"`），逾時階梯的 3 句 speak 都收到，且**同一筆指令在 `GET /commands` 長輪詢端逐欄位相同**（扇出正確）。
> - client 模式（`MQTT_URL=mqtts://mqttgo.io:8883 npm start`）：`/health` 回 `mqtt:"client"`，訂閱端**從公網 broker** 收到同樣 3 句 speak → Render 部署路徑（PaaS 只開 443）成立。
> - 降級：移走 aedes 後 `npm start` 正常服務，`mqtt` 轉為 `off`、警告含 `npm i aedes`，長輪詢不受影響。

本機開發（內嵌 aedes broker）：
下行用 mosquitto CLI 當假裝置（`brew install mosquitto`）：
```bash
mosquitto_sub -h <開發機IP> -t 'jinsun/JS-0001/cmd' -v          # 當假裝置：收 server publish 的下行
mosquitto_pub -h <開發機IP> -t 'jinsun/JS-0001/cmd' \
  -m '{"commands":[{"type":"speak","text":"測試播報","lang":"mandarin"}]}'   # 手動餵真板子
```
把 curl／mosquitto 行為用 http/mqtt client 複刻即可，契約一致。（沒裝 mosquitto 的話，`npx mqtt sub -h <開發機IP> -t 'jinsun/JS-0001/cmd' -v` 等效。）

## 6. AWS 平行環境（已建好，韌體端一個開關切換）

`cloud/aws/` 是一套**與正式環境完全獨立**的平行環境，伺服器端已實測跑通整條黃金鏈路。
**契約完全不變**——topic、payload、QoS、LWT、`/voice` 的請求與回應逐欄位相同，只有端點與憑證不同。

| 原型／正式環境 | AWS 平行環境 |
|---|---|
| `POST /voice`（Render，HTTP） | API Gateway `$default` → `jinsun-voice` Lambda |
| aedes／mqttgo.io broker | **AWS IoT Core**（X.509 雙向 TLS） |
| 上下線偵測（broker 連線事件＋LWT） | IoT Core lifecycle events（LWT 用法不變） |
| 進度播報 worker | Step Functions + `jinsun-speak` Lambda → IoT Core |

韌體端切換點是 `HUB-8735-Ultra-ASR-TTS.ino` 開頭的 `#define BACKEND_AWS`（`0`／`1`），
主迴圈與所有指令處理邏輯完全不動：

```
BACKEND_AWS 0   BASE_URL=https://jinsun-voice-server-mg1f.onrender.com
                MQTT=mqttgo.io:8883（ISRG Root X1，無認證）
BACKEND_AWS 1   BASE_URL=https://yr0ep335el.execute-api.us-west-2.amazonaws.com
                MQTT=a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com:8883
                     （Amazon Root CA 1 ＋ 裝置憑證/私鑰，走 secrets.h）
```

⚠️ 走 AWS 要注意三件事（都是「不會給錯誤碼」的失敗）：

1. **一定要燒裝置憑證**。IoT Core 認證失敗是直接切斷 TCP，PubSubClient 只會回 `rc=-2`，
   看起來就像網路不穩。產生指令見 [`../../firmware/README.md`](../../firmware/README.md)。
2. **MQTT client id 必須等於 IoT Thing 名稱**（＝`device_serial`）。Policy 用
   `${iot:Connection.Thing.ThingName}` 限縮 client id 與 topic，差一個字就被斷線。
3. **不要改用 443**。IoT Core 的 443 需要 ALPN `x-amzn-mqtt-ca`，AmebaPro2 這個核心送不出去；
   8883 才是這塊板子唯一可行的路。

**兩套環境不共用資料庫**，切過去之後事件只會出現在 AWS 那三端網址上。接手前先讀
[`aws-handoff.md`](aws-handoff.md)。ASR／TTS 兩邊共用同一組雲端服務（ASR 走 `jinsun-asr-openai`
Lambda → SageMaker `breeze-asr-26`，舊的 XCC gateway 保留在 .ino 註解裡當備援；
TTS 台語走 ATEN、國語走 `jinsun-tts` Lambda——這些雖然跑在 AWS 上，但兩套環境都打它，
理由見 §1），所以只有上面這兩個端點會變。

## 交接清單（韌體端 TODO）
- [x] 語音 pipeline 實機跑通：按鈕錄音 → 雲端 ASR → LLM → 雲端 TTS → 播放（`HUB-8735-Ultra-ASR-TTS.ino`）
- [x] 上行接本契約：直連 Gemini 已換成 `POST /voice`（Render 正式站，送 ASR 後文字＋`device_serial`），播 `reply`、執行 `action.command`；SOS/相機事件同樣走 `/voice`（序列埠 `sos`/`fall` 可模擬）
- [x] 下行：MQTT client（PubSubClient）連 broker、訂閱 `jinsun/{serial}/cmd`（QoS 1、斷線指數退避重連、LWT 上下線）；指令先入佇列、回主迴圈再播（callback 不阻塞）
- [x] （server 端）內嵌 aedes broker，enqueue 扇出 MQTT publish（`src/mqtt.js`；長輪詢保留給模擬器對測、含 LWT 上下線記錄）；另支援 `MQTT_URL` 外部 broker client 模式（Render 部署用）
- [ ] 實機驗證：MQTT 下行收播、`/voice` 上行往返（Render 冷啟動下的逾時行為）、`repeat`/`volume_*` 指令
      （2026-07-26 已完成**非實機**驗證：韌體以 arduino-cli 對 `ideasHatch:AmebaPro2:Ameba_HUB-8735_ultra`
      編譯通過（28% flash）；以 MQTT client 複刻韌體行為對正式站跑通「`POST /voice` → 問診 →
      逾時階梯 3 則 speak 從 mqttgo.io 收到」，`reply`/`intent`/`action`/`lang` 四個欄位齊備。
      仍待上板確認的是 TLS 握手、音訊播放與長時間連線穩定度）
- [ ] 本地感知層（change `add-local-perception`）：視訊管線＋YOLO 跌倒偵測、舉手求救（TTS 確認倒數）、活動統計（`activity_report`/`inactivity_suspected` 上行）——全部本地推論、僅事件上行；各模型載入失敗獨立降級、序列埠 `fall`/`sos` 保留
  - [x] **NPU 音訊分類喚醒**（YAMNet）：distress → 喚醒錄音、impact → 3 秒佐證窗（不單獨上報）、
        `impact + distress` → `fall_suspected`；喇叭出聲期間關閉偵測（否則裝置會被自己的 TTS 喚醒、無限循環）；
        序列埠 `bang`/`shout`/`sndreset` 可不靠實際聲響驗證判斷邏輯。編譯通過（84% flash，見下方 ⚠️）
  - ⚠️ **flash 用量從 28% 跳到 84%**：`yamnet_fp16.nb` 單一個模型就 8.7 MB。之後要加 YOLO 跌倒偵測
        （`yolov4_tiny.nb` 4.1 MB / `yolov7_tiny.nb` 4.7 MB）**幾乎確定塞不下**，屆時的逃生口是
        `variants/common_nn_models/yamnet_s_hybrid.nb`（只有 320 KB，SDK 內部符號 `yamnet_s`）——
        但 Arduino 包裝層的 `NNAudioClassification::begin()` 把 `&yamnet`（fp16）寫死了，
        要用小模型得繞過它直接呼叫 `vipnn_control(CMD_VIPNN_SET_MODEL, &yamnet_s)`，尚未驗證
- [ ] BLE 配網：跑通 `BLEWifiConfig` → 照第 2 節契約複刻（含回報 serial）；移除硬編碼的 WiFi 密碼與 API key
- [ ] 離線喚醒詞（小金孫）+ 急救詞（救命）——現況為按鈕觸發＋聲音事件喚醒。
      YAMNet 補不上這一項：它分得出「有人在大聲喊」，分不出喊的是哪幾個字，
      真正的關鍵字辨識要另外訓練 KWS 模型（而 flash 已經只剩 16%，見上）
- [x] **雙語播報落地**：ATEN（`kws.oaselab.org`）**本來就是台語模型**，所以 `lang=taigi`
      一直是對的；反而是**國語**沒有服務（該端點不吃 voice/lang 參數，只會講台語）。
      已補 `jinsun-tts` Lambda（Amazon Polly Zhiyu）走 `lang=mandarin`，`speak()` 依 lang 分流。
      **台語餵國語書寫已實聽確認可行** → 契約 §3② 維持「雲端不做台語翻譯」不變
- [x] **上板聽 Polly 那條路**：`amp.playWavStream()` 實機播放正常。
      初次實聽偏小聲 → 已在 Lambda 端做峰值正規化（+9.0 dB，見 §1）。
      失敗會退回 ATEN 講台語，序列埠印 `[TTS] ⚠️ 國語 TTS 不可用 → 退回 ATEN`
- [ ] `BASE_URL` 可設定；`device_serial` 固定並於配網回報
- [ ] 用第 5 節對測一輪，再上實機
