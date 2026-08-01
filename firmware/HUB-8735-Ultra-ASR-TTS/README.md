# firmware（長輩端裝置）

收音機硬體端韌體。實測板為 **HUB8735 Ultra**（Realtek RTL8735B / AmebaPro2），語音互動 pipeline 已在此板實機跑通：**按鈕錄音 → 雲端 ASR → 雲端語音 Agent（`POST /voice`）→ 雲端 TTS → 喇叭播放**，並以 MQTT 常駐訂閱接收雲端下行指令。

程式碼：[`HUB-8735-Ultra-ASR-TTS.ino`](HUB-8735-Ultra-ASR-TTS.ino)

> 架構總覽與目標契約見 [`../docs/architecture.md`](../docs/architecture.md) 與
> [`../docs/requirements/hardware-integration.md`](../docs/requirements/hardware-integration.md)。
> 口袋型穿戴版（XIAO ESP32-S3）目前僅為設計概念，所有實測都在桌上型 HUB8735 Ultra 上進行。

## 已跑通的語音 pipeline（現況）

**上行（長輩主動觸發才錄音上雲）**

1. 長輩**按住按鈕 2 秒** → 播 `init.wav` 提示音 → 開始錄音（板載 PDM 麥克風，16kHz mono，AAC/MP4 暫存 SD 卡，最長 30 秒；**再按一下**或序列輸入 `stop` 提前結束）
2. 錄音結束 → 播 `wait.wav` 墊住處理時間 → 音檔上傳**雲端 ASR**（faster-whisper Breeze-ASR-26，OpenAI 相容 `/v1/audio/transcriptions`）→ 取得中文文字
3. 文字送**雲端語音 Agent server**（`POST /voice`，帶 `device_serial`）→ 雲端做意圖分類、起 20 秒升級計時、必要時開派遣單，同步回一句要立刻播的 `reply`＋選用的 `action.command`
4. 回覆文字送**雲端 TTS**（回傳 WAV URL）→ 裝置以 HTTPS 串流邊下載邊播放（MAX98357 I2S 功放）

序列埠輸入 `sos` / `fall` 可模擬 SOS 鍵與相機跌倒事件（走同一條 `POST /voice`，`event` 欄位），沒有實體按鈕與相機時也能跑完整條鏈路。

**下行（雲端主動找長輩說話）**

開機後以 MQTT 常駐訂閱 `jinsun/{serial}/cmd`（QoS 1），雲端的急救逾時階梯與志工進度播報就靠這條推過來：收到 `{"commands":[…]}` 後 `speak` 送 TTS 發聲、`device` 執行 `volume_up`／`volume_down`／`repeat`／`stop_speak`。連線設 Last Will（`jinsun/{serial}/status` = `offline`），後台的「裝置離線」顯示不需另做心跳。斷線以指數退避重連（1s→2s→…→30s），重連後重新訂閱並補發 `online`。

> 指令在 MQTT callback 裡只入佇列、回主迴圈才播——callback 內直接播 TTS 會卡住收訊迴圈導致 keep-alive 斷線，而 QoS 1 重連後 broker 會重送同一則，變成無限循環播報。

開機自檢：WiFi 連上後，SD 卡正常播 `ready.wav`（無檔案則合成上揚雙音）；SD 卡異常合成三聲低音警告。

## 硬體接線（HUB8735 Ultra）

| 元件 | 接法 |
|---|---|
| 觸發按鈕 | D9 ↔ GND（`INPUT_PULLUP`，按下 = LOW；D12 被 I2S 佔用、D13 是閃光燈 PWM，不可用） |
| MAX98357 I2S 功放 | BCLK→D24、LRC→D12、DIN→D11、SD_MODE→D10（同時佔用 D22/D23，板載按鈕不可用） |
| 麥克風 | 板載數位 PDM，`AudioSetting(3)`＝16kHz Mono Digital PDM（設成類比會錄到一片死寂，實測 -74dBFS） |
| SD 卡 | 錄音暫存 `test.mp4`；提示音 `ready.wav` / `init.wav` / `wait.wav` |

## 外部服務（常數寫在 .ino 開頭，可抽換）

**兩套雲端環境**共存，靠 .ino 開頭的 `#define BACKEND_AWS`（`0`／`1`）切換，**契約完全相同**——
topic、payload、QoS、LWT、`/voice` 的請求與回應逐欄位一致，差別只有端點與憑證：

| 用途 | `BACKEND_AWS 0`（正式環境） | `BACKEND_AWS 1`（AWS 平行環境） |
|---|---|---|
| 語音 Agent（大腦） | `jinsun-voice-server-mg1f.onrender.com/voice`（Render + Supabase） | `yr0ep335el.execute-api.us-west-2.amazonaws.com/voice`（API Gateway → `jinsun-voice` Lambda + Aurora） |
| MQTT broker（下行） | `mqttgo.io:8883`（TLS，公共 broker、無認證；鏈根 ISRG Root X1） | `a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com:8883`（AWS IoT Core，**X.509 雙向 TLS**；鏈根 Amazon Root CA 1） |
| 上行逾時 | 60 秒（Render 免費方案冷啟動 30–60 秒） | 30 秒（API Gateway 整合逾時上限） |

⚠️ **兩套環境不共用資料庫**：切到 AWS 之後，這台的事件只會出現在 AWS 那三端網址上，正式環境的家屬 App 看不到（反之亦然）。開機第一行 `[ENV] …` log 就是在講現在連的是哪一套。詳見 [`../docs/requirements/aws-handoff.md`](../docs/requirements/aws-handoff.md)。

兩套環境共用的部分（不隨開關改變）：

| 用途 | 服務 |
|---|---|
| ASR | `llm-gateway.xcc.tw` `/v1/audio/transcriptions`，model `paulpengtw/faster-whisper-Breeze-ASR-26`（OpenAI/Groq 相容介面）。AWS 版的 Transcribe Lambda 尚未做，所以兩邊都打這裡 |
| TTS | `kws.oaselab.org` `/nutntweng/tts/aten/`（回 JSON 帶 WAV URL，再 GET 串流播放） |

原本的「直連 Google Gemini」已移除——直連 LLM 時雲端不知道有人在求救，長輩的話進不了急救狀態機。

### 走 AWS 要先燒憑證

AWS IoT Core 用 X.509 認裝置身分，**沒有憑證就完全收不到下行指令**（急救逾時階梯的三句話都不會播）。
私鑰無法從 AWS 取回，遺失就重簽一組：

```bash
THING=JS-0001                    # 必須與 .ino 的 device_serial 完全相同
aws iot create-keys-and-certificate --set-as-active \
  --certificate-pem-outfile device.cert.pem \
  --private-key-outfile device.key.pem \
  --public-key-outfile device.public.pem \
  --query certificateArn --output text > cert.arn
aws iot attach-policy --policy-name JinsunDevicePolicy --target "$(cat cert.arn)"
aws iot attach-thing-principal --thing-name "$THING" --principal "$(cat cert.arn)"
```

把兩個 PEM 的內容貼進 `secrets.h`（複製 [`secrets.h.example`](secrets.h.example)，已在 `.gitignore`）。
沒填憑證時韌體**不會靜默重試**，開機會直接印出缺憑證的原因——因為 AWS IoT 對認證／授權失敗是
直接切斷 TCP、不回錯誤碼，症狀長得跟「網路不穩」一模一樣，不講清楚會查錯方向。

## 已知限制／注意事項

- WiFi SSID/密碼、ASR API key、AWS IoT 裝置憑證與私鑰都走 `secrets.h`（未追蹤，範本
  [`secrets.h.example`](secrets.h.example)）。.ino 只留佔位符，沒有 `secrets.h` 也編得過但連不上。
  長期目標仍是 BLE 配網＋安全儲存（Flash 加密分割區）
- 開機以 `settimeofday` 強制設定系統時間來通過 SSL 憑證驗證（板子無 RTC/NTP）。
  ⚠️ **重燒韌體時必須把 `tv.tv_sec` 更新到接近當天**（`date +%s`）：mqttgo.io 用 Let's Encrypt
  的 90 天短效憑證，時間設得太早會被判「憑證尚未生效」而連不上 MQTT。走 AWS 時根憑證雖然到 2038，
  但**裝置憑證是重簽當天才生效**，一樣會被時鐘卡住
- `lang=taigi` 目前**會被念成國語**——現接的 ATEN TTS 只有一種語音。雲端不做台語翻譯（`text`
  一律正常中文，`lang` 只是選語音的旗標），所以換到支援台語的 TTS 只要改 `requestTTS`。
  這是台語播報能否落地的關鍵未決項，韌體會在 log 明確標示而不是靜默忽略
- `stop_speak` 只能清空待播佇列，無法中斷正在播放的那一句（`playWavStream` 是阻塞的）
- MQTT 連線在長時間阻塞操作（ASR 上傳、TTS 播放）期間可能逾時斷線，**這是刻意接受的**：
  在 ASR 等待迴圈裡呼叫 `mqttPump()` 會讓 TLS 握手阻塞數秒、誤判「安靜夠久＝收完了」而截斷回應。
  改靠 `cleanSession=false` ＋ QoS 1，斷線期間的指令由 broker 在重連後補投
- 尚未實作：跌倒偵測相機（Himax WiseEye2）、「小金孫」喚醒詞與離線急救詞「救命」、BLE 配網

## 對測（不用實機）

`device_serial` 硬編碼在 .ino 開頭，預設 `JS-0001`。用 mosquitto 當假裝置即可驗下行：

```bash
# 正式環境（BACKEND_AWS 0）
mosquitto_sub -h mqttgo.io -t 'jinsun/JS-0001/cmd' -v     # 收雲端 push
curl -s https://jinsun-voice-server-mg1f.onrender.com/voice \
  -H 'content-type: application/json' \
  -d '{"device_serial":"JS-0001","text":"我跌倒了"}'      # 觸發問診→逾時階梯
```

AWS 環境（`BACKEND_AWS 1`）同一組驗證——下行要帶憑證才訂閱得到：

```bash
API=https://yr0ep335el.execute-api.us-west-2.amazonaws.com
curl -s $API/health                                        # {"ok":true,...,"ladder":true}
curl -s $API/voice -H 'content-type: application/json' \
  -d '{"device_serial":"JS-0001","text":"我跌倒了"}'

mosquitto_sub -h a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com -p 8883 \
  --cafile AmazonRootCA1.pem --cert device.cert.pem --key device.key.pem \
  -i JS-0001 -t 'jinsun/JS-0001/cmd' -v
```

> `-i JS-0001` 不能省：IoT Policy 用 `${iot:Connection.Thing.ThingName}` 限縮 client id，
> 名字對不上會被**直接斷線**（不是回錯誤碼）。

完整契約與交接清單見 [`../docs/requirements/hardware-integration.md`](../docs/requirements/hardware-integration.md)。
