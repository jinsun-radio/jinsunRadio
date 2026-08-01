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

| 用途 | 服務 |
|---|---|
| ASR | `llm-gateway.xcc.tw` `/v1/audio/transcriptions`，model `paulpengtw/faster-whisper-Breeze-ASR-26`（OpenAI/Groq 相容介面） |
| 語音 Agent（大腦） | `https://jinsun-voice-server-mg1f.onrender.com/voice`（Render；意圖分類、20 秒升級、派遣） |
| MQTT broker（下行） | `mqttgo.io:8883`（TLS，憑證鏈根 ISRG Root X1 已內嵌於 .ino） |
| TTS | `kws.oaselab.org` `/nutntweng/tts/aten/`（回 JSON 帶 WAV URL，再 GET 串流播放） |

原本的「直連 Google Gemini」已移除——直連 LLM 時雲端不知道有人在求救，長輩的話進不了急救狀態機。

## 已知限制／注意事項

- WiFi SSID/密碼與各服務 API key **硬編碼在 .ino 裡**——commit／公開前必須處理（目標：BLE 配網＋安全儲存）
- 開機以 `settimeofday` 強制設定系統時間來通過 SSL 憑證驗證（板子無 RTC/NTP）。
  ⚠️ **重燒韌體時必須把 `tv.tv_sec` 更新到接近當天**（`date +%s`）：mqttgo.io 用 Let's Encrypt
  的 90 天短效憑證，時間設得太早會被判「憑證尚未生效」而連不上 MQTT
- `lang=taigi` 目前**會被念成國語**——現接的 ATEN TTS 只有一種語音。雲端不做台語翻譯（`text`
  一律正常中文，`lang` 只是選語音的旗標），所以換到支援台語的 TTS 只要改 `requestTTS`。
  這是台語播報能否落地的關鍵未決項，韌體會在 log 明確標示而不是靜默忽略
- `stop_speak` 只能清空待播佇列，無法中斷正在播放的那一句（`playWavStream` 是阻塞的）
- MQTT 連線在長時間阻塞操作（TTS 播放）期間可能逾時斷線，靠退避重連復原；ASR 等待迴圈中已插入
  `mqttPump()` 維持連線
- 尚未實作：跌倒偵測相機（Himax WiseEye2）、「小金孫」喚醒詞與離線急救詞「救命」、BLE 配網

## 對測（不用實機）

`device_serial` 硬編碼在 .ino 開頭，預設 `JS-0001`。用 mosquitto 當假裝置即可驗下行：

```bash
mosquitto_sub -h mqttgo.io -t 'jinsun/JS-0001/cmd' -v     # 收雲端 push
curl -s https://jinsun-voice-server-mg1f.onrender.com/voice \
  -H 'content-type: application/json' \
  -d '{"device_serial":"JS-0001","text":"我跌倒了"}'      # 觸發問診→逾時階梯
```

完整契約與交接清單見 [`../docs/requirements/hardware-integration.md`](../docs/requirements/hardware-integration.md)。
