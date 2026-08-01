# firmware（長輩端裝置）

收音機硬體端韌體。實測板為 **HUB8735 Ultra**（Realtek RTL8735B / AmebaPro2），語音互動 pipeline 已在此板實機跑通：**按鈕錄音 → 雲端 ASR → 雲端語音 Agent（`POST /voice`）→ 雲端 TTS → 喇叭播放**，並以 MQTT 常駐訂閱接收雲端下行指令。

程式碼：[`HUB-8735-Ultra-ASR-TTS.ino`](HUB-8735-Ultra-ASR-TTS.ino)

> 架構總覽與目標契約見 [`../docs/architecture.md`](../docs/architecture.md) 與
> [`../docs/requirements/hardware-integration.md`](../docs/requirements/hardware-integration.md)。
> 口袋型穿戴版（XIAO ESP32-S3）目前僅為設計概念，所有實測都在桌上型 HUB8735 Ultra 上進行。

## 已跑通的語音 pipeline（現況）

**上行（長輩主動觸發才錄音上雲）**

1. 長輩**按住按鈕 1 秒**（或**喊出聲**，見下方「本地聲音事件偵測」）→ 播 `init.wav` 提示音 → 開始錄音（板載 PDM 麥克風，16kHz mono，AAC/MP4 暫存 SD 卡；按鈕觸發最長 30 秒、**再按一下**或序列輸入 `stop` 提前結束，聲音喚醒則固定錄 8 秒後自動收工）
2. 錄音結束 → 播 `wait.wav` 墊住處理時間 → 音檔上傳**雲端 ASR**（faster-whisper Breeze-ASR-26，OpenAI 相容 `/v1/audio/transcriptions`）→ 取得中文文字
3. 文字送**雲端語音 Agent server**（`POST /voice`，帶 `device_serial`）→ 雲端做意圖分類、起 20 秒升級計時、必要時開派遣單，同步回一句要立刻播的 `reply`＋選用的 `action.command`
4. 回覆文字送**雲端 TTS**（回傳 WAV URL）→ 裝置以 HTTPS 串流邊下載邊播放（MAX98357 I2S 功放）

序列埠輸入 `sos` / `fall` 可模擬 SOS 鍵與相機跌倒事件（走同一條 `POST /voice`，`event` 欄位），沒有實體按鈕與相機時也能跑完整條鏈路。

## 本地聲音事件偵測（NPU / YAMNet）

板子的 NPU 從開機到關機一直在跑 YAMNet 音訊分類（521 類），**推論全程在裝置上、音訊從來不離開這塊板子**——
上行的只有「聽到什麼類別」導出的事件（`CLAUDE.md` 約束 1）。這補上了原本「長輩按不到按鈕就求救無門」的洞。

| 聽到 | 反應 |
|---|---|
| **求救聲**（Shout / Yell / Screaming / Crying / Whimper / Wail / Groan / Gasp，score ≥ 45） | 觸發**與長按按鈕完全相同**的喚醒錄音流程（錄 8 秒 → ASR → `POST /voice`），讓長輩把話講完再交給雲端分類 |
| **撞擊聲**（Thump / Bang / Slam / Smash / Breaking / Glass / Shatter…，score ≥ 60） | **只開一扇 3 秒「佐證窗」，絕不單獨上報** |
| **撞擊 → 3 秒內又聽到求救聲** | 兩個獨立訊號指向同一件事 → 直接送 `event:"fall_suspected"`，交給雲端 20 秒升級階梯（跳過問診：摔在地上的人可能已經講不出完整句子） |

設計上的幾個「為什麼」：

- **撞擊聲為什麼不能單獨上報**：關門、放鍋子、掉遙控器都會觸發，而每一次誤報都是一張真的志工派遣單。
  白名單也因此刻意排除 `Door` / `Knock` / `Dishes`——收進來的話佐證窗幾乎整天開著，等於沒有佐證。
- **喇叭出聲期間會關閉偵測**（`speakerOutputBegin/End`，停播後再多丟 1 秒）：麥克風聽得到自己的喇叭，
  不擋的話 TTS 的人聲會被判成 Shout → 「播報 → 誤判求救 → 又錄音 → 又播報」無限循環。
- **NN callback 只設旗標**（`onAudioClassified` 跑在 vipnn 執行緒），播音、開錄音、HTTPS 上報一律留到
  主迴圈的 `pumpSoundDetection()` 做——理由與 MQTT callback 那邊相同。
- **60 秒喚醒冷卻**：一次喚醒後面接的是錄音→ASR→/voice，幾十秒跑不完；沒有冷卻的話電視劇裡一段爭吵
  就能連開十幾張單。
- 門檻（`distressScoreThreshold` / `impactScoreThreshold`）與白名單都寫在 .ino 開頭，**預期要在場域實測後調**。
  每一筆進了白名單的偵測都會印 `[SND] …` log 帶類別名與分數，就是拿來調這兩個數字的。

不用真的摔東西也能驗判斷邏輯——序列埠輸入：

| 指令 | 作用 |
|---|---|
| `shout` | 偽造一筆求救聲偵測 |
| `bang` | 偽造一筆撞擊聲偵測（開佐證窗） |
| `sndreset` | 清除冷卻與佐證窗 |
| `snddebug` | 切換診斷模式：**每一次**推論都印出前 3 名（不管有沒有進白名單、有沒有過門檻） |

`bang` 後 3 秒內打 `shout` → 應該看到 `fall_suspected` 上報；單獨打 `shout` → 應該進喚醒錄音。

`snddebug` 是調門檻與確認模型活著的主要工具——平常的 `[SND]` log 本身就被門檻擋著，
「喊了沒反應」到底是模型沒載進去、麥克風沒收到聲音、還是分數差一點，只有這個模式分得出來：

```
[SND] (raw)  Silence(494)=87  Speech(0)=6  Inside, small room(506)=3
[SND] (raw)  Shout(6)=41  Speech(0)=33  Yell(9)=12     ← 41 差一點沒過 45，門檻要往下調
```

> ⚠️ **編譯設定**：Arduino IDE 的 **Tools → NN Model Load From 要維持 `Flash`**（預設值）。
> 選 SD Card 的話要自己把模型檔放進記憶卡根目錄，而這張卡同時在存錄音，不值得多這個變數。
>
> ⚠️ **YAMNet 不是關鍵字辨識器**：它分得出「有人在大聲喊」，分不出喊的是「救命」還是「小金孫」。
> 離線喚醒詞／急救詞仍是待辦，要另外訓練 KWS 模型。
>
> 整段功能可用 .ino 開頭的 `#define ENABLE_SOUND_DETECTION 0` 關掉，退回純按鈕觸發。

**下行（雲端主動找長輩說話）**

開機後以 MQTT 常駐訂閱 `jinsun/{serial}/cmd`（QoS 1），雲端的急救逾時階梯與志工進度播報就靠這條推過來：收到 `{"commands":[…]}` 後 `speak` 送 TTS 發聲、`device` 執行 `volume_up`／`volume_down`／`repeat`／`stop_speak`。連線設 Last Will（`jinsun/{serial}/status` = `offline`），後台的「裝置離線」顯示不需另做心跳。斷線以指數退避重連（1s→2s→…→30s），重連後重新訂閱並補發 `online`。

> 指令在 MQTT callback 裡只入佇列、回主迴圈才播——callback 內直接播 TTS 會卡住收訊迴圈導致 keep-alive 斷線，而 QoS 1 重連後 broker 會重送同一則，變成無限循環播報。

開機自檢：WiFi 連上後，SD 卡正常播 `ready.wav`（無檔案則合成上揚雙音）；SD 卡異常合成三聲低音警告。

## 硬體接線（HUB8735 Ultra）

| 元件 | 接法 |
|---|---|
| 觸發按鈕 | D9 ↔ GND（`INPUT_PULLUP`，按下 = LOW；D12 被 I2S 佔用、D13 是閃光燈 PWM，不可用） |
| MAX98357 I2S 功放 | BCLK→D24、LRC→D12、DIN→D11、SD_MODE→D10（同時佔用 D22/D23，板載按鈕不可用） |
| 麥克風 | 板載數位 PDM，`AudioSetting(3)`＝16kHz Mono Digital PDM（設成類比會錄到一片死寂，實測 -74dBFS）。同一份輸入以 SIMO StreamIO 分流給 AAC 錄音與 NPU 音訊分類——YAMNet 也只吃 16kHz，設定完全共用，不必開第二條音訊管線 |
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
| TTS（`lang=taigi`） | `kws.oaselab.org` `/nutntweng/tts/aten/` —— **ATEN 台語模型**（回 JSON 帶 WAV URL，再 GET 串流播放）。端點不吃 voice/lang 參數，只會講台語 |
| TTS（`lang=mandarin`） | `…execute-api.us-west-2.amazonaws.com` `/tts` —— **Amazon Polly Zhiyu**（`jinsun-tts` Lambda）。韌體帶 `Accept: audio/wav`，回應本身就是 WAV，POST 完直接串流播放（實機驗過）。部署：`bash cloud/aws/scripts/deploy-tts.sh`。兩套環境共用（無狀態服務，同 ASR gateway）。**音量在雲端正規化**（Polly 原始輸出峰值只到 −10 dBFS，聽起來偏小聲；Lambda 拉到 −1 dBFS，+9 dB）——不要改用 `ampVolume` 補，那會連台語一起變大聲 |

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

### MQTT 一直重連（連上約 0.5 秒就斷）

```
[MQTT] 已連線,訂閱 jinsun/JS-0001/cmd (QoS 1)
[MQTT] ✗ 斷線（這次連線撐了 535 ms）state=-3 errno=128
[MQTT] 連線中 …                                    ← 無限循環
```

**先讀那兩個數字，它們直接決定往哪查**（2026-08-01 實測到的就是下表第一列）：

| 症狀 | 意思 | 往哪查 |
|---|---|---|
| `state=-3` `errno=128` | `errno 128` = **ENOTCONN**（newlib 編號，見 toolchain 的 `sys/errno.h`；不是 lwIP 的 107）＝**對端主動關閉連線**。TLS 握手與 CONNECT 都過了才被踢 | **雲端授權**，見下方 |
| `state=-4` | keep-alive ping 沒等到回應 | 網路／broker 可達性，不是授權 |
| 連 `已連線` 都印不出來、`rc=-2` | TLS 握手就失敗 | 憑證內容、系統時鐘（`tv.tv_sec`） |

**「接受 CONNECT、半秒後斷線」是 AWS IoT 對授權失敗的標準反應**——它不回錯誤碼，直接斷 TCP。
`iot:Connect` 在 CONNECT 當下就判過了，subscribe／publish 是之後才被拒，那個時間差就是那半秒。

#### 已知成因：`setPublishQos(1)` 其實打開的是 RETAIN 旗標（2026-08-01 查明，已修）

這個坑值得完整寫下來，因為每一條線索都指向錯的方向：Thing、憑證、policy 三者查起來全都正確
（`list-thing-principals`／`list-attached-policies`／`get-policy-version` 都對得上），憑證也 ACTIVE、
時鐘也在 `notBefore` 之後，TLS 握手更是明明過了。

真正的原因在韌體這行（原本寫在 `setup()`）：

```cpp
mqtt.setPublishQos(1);    // 想讓上下線狀態走 QoS 1
```

SDK 的這支 API 收的是**已經位移過的常數**——`#define MQTTQOS1 (1 << 1)`，值是 **2 不是 1**。
而實作是 `header |= pub_qos;`，MQTT 固定標頭的位元配置是：

```
[type:4][DUP:1][QoS:2][RETAIN:1]        ← bit 0 是 RETAIN
```

所以傳 `1` 進去不是設 QoS 1，是**把 RETAIN 打開**。`publish("jinsun/{serial}/status","online")`
就變成一則保留訊息，而 **AWS IoT 對保留訊息要求另一個權限 `iot:RetainPublish`**，
[`device-policy.json`](../../cloud/aws/iot/device-policy.json) 只給了 `iot:Publish` → 被拒 → 關閉連線。

> 那改成 `setPublishQos(MQTTQOS1)` 不就好了？**不行**。SDK 的 QoS≥1 分支還有第二個 bug：
> ```cpp
> buffer[id_pos]   = (nextMsgId >> 8);
> buffer[id_pos++] = (nextMsgId & 0xFF);   // 後置遞增 → 兩行寫到同一格
> ```
> MSB 被 LSB 蓋掉，第二個位元組從沒被寫入（留著上一個封包的殘值），送出去的 packet identifier 是壞的。

**現在的作法是不呼叫 `setPublishQos()`，status 用預設 QoS 0。** 這不影響可靠性：status 只是「我在線」的
標記，離線那半由 LWT 負責；真正需要保證投遞的下行指令走的是 **subscribe QoS 1 + `cleanSession=false`**，
與 `setPublishQos` 無關。（若哪天真的想要 retained status，得同時在 policy 加 `iot:RetainPublish`
並把 LWT 也改成 `willRetain=true`，否則上線保留、離線不保留，後台看到的狀態會是錯的。）

#### 其它可能

- 憑證沒 attach 到 Thing → policy 的 `${iot:Connection.Thing.ThingName}` 解不出值 → 全被拒：
  ```bash
  aws iot list-thing-principals --thing-name JS-0001 --region us-west-2   # 空陣列就是這個原因
  aws iot attach-thing-principal --thing-name JS-0001 --principal "<certArn>" --region us-west-2
  ```
- 另一個 client 用同一個 client id 連線 → IoT Core 踢掉舊的那條，兩邊互踢。
  ⚠️ policy 把 client id 綁死成 Thing 名稱，所以**電腦上的 `mosquitto_sub` 只能用 `-i JS-0001`，
  必然跟裝置互踢**——要旁聽下行請先把裝置斷電，不能同時連。

**不用 AWS 帳號也能先分流**：把 `.ino` 的 `BACKEND_AWS` 改成 `0` 燒一次，那條走 mqttgo.io（公共 broker、
無認證，也不在意 retain）。MQTT 穩了 → 確定是 AWS 授權那側；一樣每 0.5 秒斷 → 成因在更底層。

> 斷線期間**聲音偵測與上行 `POST /voice` 都不受影響**（走序列埠與 HTTPS，不經 MQTT），
> 只有「雲端主動下發 `speak`」那條下行鏈路會斷。

## 已知限制／注意事項

- WiFi SSID/密碼、ASR API key、AWS IoT 裝置憑證與私鑰都走 `secrets.h`（未追蹤，範本
  [`secrets.h.example`](secrets.h.example)）。.ino 只留佔位符，沒有 `secrets.h` 也編得過但連不上。
  長期目標仍是 BLE 配網＋安全儲存（Flash 加密分割區）
- 開機以 `settimeofday` 強制設定系統時間來通過 SSL 憑證驗證（板子無 RTC/NTP）。
  ⚠️ **重燒韌體時必須把 `tv.tv_sec` 更新到接近當天**（`date +%s`）：mqttgo.io 用 Let's Encrypt
  的 90 天短效憑證，時間設得太早會被判「憑證尚未生效」而連不上 MQTT。走 AWS 時根憑證雖然到 2038，
  但**裝置憑證是重簽當天才生效**，一樣會被時鐘卡住
- `lang` 分流已實作：`taigi` → ATEN（台語模型）、`mandarin` → Polly Zhiyu。雲端不做台語翻譯
  （`text` 一律正常中文，`lang` 只是選語音的旗標）。Polly 那條路失敗時**退回 ATEN**，長輩會聽到
  台語版的同一句——寧可語言不對也不要安靜，序列埠會印 `[TTS] ⚠️ 國語 TTS 不可用 → 退回 ATEN`。
  ✅ **台語餵國語書寫已實聽確認可行**（台文寫法雖然不同，例：「雞蛋」→「雞卵」，但 ATEN 念得出來），
  所以雲端不必為 `lang` 產兩份文字
- `stop_speak` 只能清空待播佇列，無法中斷正在播放的那一句（`playWavStream` 是阻塞的）
- MQTT 連線在長時間阻塞操作（ASR 上傳、TTS 播放）期間可能逾時斷線，**這是刻意接受的**：
  在 ASR 等待迴圈裡呼叫 `mqttPump()` 會讓 TLS 握手阻塞數秒、誤判「安靜夠久＝收完了」而截斷回應。
  改靠 `cleanSession=false` ＋ QoS 1，斷線期間的指令由 broker 在重連後補投
- ⚠️ **flash 只剩約 16%**：加上音訊分類後從 28% 跳到 84%（`yamnet_fp16.nb` 一個模型就 8.7 MB）。
  之後要加 YOLO 跌倒偵測（`yolov4_tiny.nb` 4.1 MB／`yolov7_tiny.nb` 4.7 MB）**幾乎確定塞不下**。
  逃生口是 `variants/common_nn_models/yamnet_s_hybrid.nb`（只有 320 KB，SDK 內部符號 `yamnet_s`），
  但 `NNAudioClassification::begin()` 把 `&yamnet`（fp16）寫死了，要用小模型得繞過包裝層直接呼叫
  `vipnn_control(CMD_VIPNN_SET_MODEL, &yamnet_s)`——**尚未驗證**
- 聲音偵測**沒有「模型載入失敗就退回音量門檻」的降級路徑**：`NNAudioClassification::begin()` 回傳 void，
  SDK 也沒有查詢載入結果的 API。目前只能靠編譯期的 `ENABLE_SOUND_DETECTION` 開關切回純按鈕模式，
  開機的 `[SND] 喚醒模式：…` log 是現場唯一能確認偵測有沒有開的依據
- `NNAudioClassification.h` 為了引入 `<vector>` 會 `#undef min` / `#undef max`，**Arduino 的 min()/max()
  巨集在這個 .ino 裡已經不存在**（音量夾值改用自寫的 `clampVolume()`）。之後在本檔案新增程式碼時要注意
- 尚未實作：跌倒偵測相機（Himax WiseEye2）、「小金孫」喚醒詞與離線急救詞「救命」、BLE 配網

## 編譯檢查（不用開 IDE）

Arduino IDE 2.x 內建了 arduino-cli，可以直接拿來驗證編譯：

```bash
CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
"$CLI" compile --fqbn ideasHatch:AmebaPro2:Ameba_HUB-8735_ultra firmware/HUB-8735-Ultra-ASR-TTS
```

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
