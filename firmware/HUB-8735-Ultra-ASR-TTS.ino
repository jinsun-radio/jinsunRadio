#include <sys/time.h>
#include "StreamIO.h"
#include "AudioStream.h"
#include "AudioEncoder.h"
#include "MP4Recording.h"
#include "WiFi.h"
#include "AmebaFatFS.h"
#include "Base64.h"
#include <ArduinoJson.h>
#include <MAX98357.h>
#include <PubSubClient.h>

char ssid[] = "xxx";    // your network SSID (name)
char pass[] = "xxx";        // your network password
int status = WL_IDLE_STATUS;

String api_key = "sk-bf-";                         // Groq - > https://console.groq.com/keys
char api_server[] = "llm-gateway.xcc.tw";             // Groq - > api.groq.com
String api_path = "/v1/audio/transcriptions";     // Groq - > /openai/v1/audio/transcriptions
String model = "paulpengtw/faster-whisper-Breeze-ASR-26";                       // Groq - > whisper-large-v3-turbo or whisper-large-v3

#define FILENAME "test"
String FILENAME_EXT = String(FILENAME)+".mp4";
int recordSeconds = 30;         // 最長錄音上限(秒);可按鈕/序列輸入提前結束

// TTS(文字轉語音)伺服器
char tts_server[] = "kws.oaselab.org";
String tts_path = "/nutntweng/tts/aten/";

// ===== 雲端語音 Agent server(上行 POST /voice) =====
// 契約見 docs/requirements/hardware-integration.md §3①:
//   請求 {device_serial, text} 或 {device_serial, event:"sos"|"fall_suspected"|…}
//   回應 {reply, intent, action:{command}, lang}
// 「大腦」在雲端(意圖分類、問診、20 秒升級計時、派遣志工),裝置只負責
// 收音、上報事件、發聲。原本直連 Gemini 的做法已換成這條,長輩的話才進得了
// 急救狀態機——直連 LLM 時雲端根本不知道有人在求救。
char voice_server[] = "jinsun-voice-server-mg1f.onrender.com";
String voice_path = "/voice";
// device_serial 全程固定,同時是 MQTT client id 與 topic 的一部分。
// 正式版由 BLE 配網寫入;現在先硬編碼(JS-0001 是資料庫既有種子,可直接對測)。
String device_serial = "JS-0001";
// Render 免費方案閒置會休眠,冷啟動可能 30–60 秒才回應
const unsigned long voice_timeout_ms = 60000;

// ===== MQTT 下行(server publish → 裝置) =====
// 契約見 §3②:訂閱 jinsun/{serial}/cmd(QoS 1)、keep-alive 30s、
// 斷線指數退避重連(1s→2s→…→30s)、LWT jinsun/{serial}/status = "offline"。
// 為什麼要外部 broker:Render 這類 PaaS 只對外開 443,server 內嵌的 aedes(1883)
// 從公網進不來 → server 與裝置各自連上同一顆公共 broker 會合(契約完全不變)。
char mqtt_server[] = "mqttgo.io";
const int mqtt_port = 8883;    // 一律走 TLS:實測此核心純 TCP(WiFiClient)收不到任何資料
const int mqtt_keepalive = 30;
String cmd_topic = "jinsun/" + device_serial + "/cmd";
String status_topic = "jinsun/" + device_serial + "/status";

// mqttgo.io 憑證由 Let's Encrypt 簽發,鏈根為 ISRG Root X1(下面這張)。
// ⚠️ Let's Encrypt 是 90 天短效憑證,而本板無 RTC/NTP、開機硬設時鐘(見 setup()):
//    重燒韌體時務必把 tv.tv_sec 更新到接近當天,否則會被判「憑證尚未生效」而連不上。
char* mqtt_root_ca =
    "-----BEGIN CERTIFICATE-----\n"
    "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\n"
    "-----END CERTIFICATE-----\n";

// D12 被 I2S 的 LRC 佔用、D13 是閃光燈 PWM(恆為 LOW),按鈕用 D9。
// 按鈕接 D9 與 GND,用 INPUT_PULLUP(按下 = LOW)。
const int buttonPin = 9;          // the number of the pushbutton pin
const int buttonPressInterval = 2000;          // 按住 2 秒觸發

AmebaFatFS fs;
WiFiClient wifiClient;

// MQTT 下行:獨立一條 TLS 連線常駐(與 ASR/TTS/voice 的短連線互不干擾)
WiFiSSLClient mqttNet;
PubSubClient mqtt(mqttNet);

// 指令佇列:MQTT callback 只把 payload 丟進來就返回,實際發聲回主迴圈才做。
// callback 內若直接播 TTS(要連兩次 HTTPS、播放又是阻塞的),會卡住 MQTT
// 收訊迴圈導致 keep-alive 逾時斷線,而且斷線重連後 broker 會重送同一則(QoS 1),
// 變成無限循環播報。
#define CMD_QUEUE_SIZE 6
String cmdQueue[CMD_QUEUE_SIZE];
int cmdHead = 0;
int cmdCount = 0;

// MAX98357 I2S 揚聲器:BCLK→D24、LRC→D12、DIN→D11、SD_MODE→D10
// (同時佔用 D22/D23,板載按鈕不可用)
MAX98357 amp;
float ampVolume = 0.8;             // volume_up/volume_down 指令會調整這個值
String lastSpokenText = "";        // repeat 指令要重播的內容
String lastSpokenLang = "mandarin";

char buf[512];
char *p;
String filepath;
File file;

// Default audio preset configurations:
// 0 :  8kHz Mono Analog Mic
// 1 : 16kHz Mono Analog Mic
// 2 :  8kHz Mono Digital PDM Mic
// 3 : 16kHz Mono Digital PDM Mic
//
// HUB 8735 Ultra 板載麥克風是數位 PDM，用 1(類比) 會錄到一片死寂（實測 -74dBFS）。
// 改用 3 = 16kHz Mono Digital PDM Mic。若換板子或外接類比麥克風，再改回 1。
AudioSetting configA(3);
Audio audio;
AAC aac;
MP4Recording mp4;
StreamIO audioStreamer1(1, 1);    // 1 Input Audio -> 1 Output AAC
StreamIO audioStreamer2(1, 1);    // 1 Input AAC -> 1 Output MP4

// 初值設 HIGH(＝沒被按,因為是 INPUT_PULLUP)。若留預設 0(LOW),開機第一輪會
// 誤判成「剛剛放開按鈕」而印出一筆假的邊緣 log,診斷時會被誤導。
int buttonState = HIGH;                   // variable for reading the pushbutton status
bool longPressLogged = false;             // 長按門檻只印一次(每次按下重置),避免洗版
unsigned long buttonPressTime = 0;        // variable to store the time when button was pressed
bool buttonPressedFor2Seconds = false;    // flag to indicate if button is pressed for at least 2 seconds
int recordingstate = -1;
int previousRecordingState = -1;
bool stopArmed = false;                   // 錄音中且按鈕已放開,可接受「再按一下」提前結束
int prevButtonLevel = HIGH;               // 上一輪的按鈕電平,用於邊緣偵測
String serialLine = "";                   // 序列輸入緩衝(stop/sos/fall)

// MQTT 重連退避:1s→2s→…→30s(契約 §3②),用 millis 排程、不阻塞主迴圈
unsigned long mqttNextAttempt = 0;
unsigned long mqttBackoff = 1000;
const unsigned long mqttBackoffMax = 30000;

// 前向宣告(這些函式彼此互相呼叫,也在定義之前就被 setup()/loop() 用到)
void onMqttMessage(char* topic, uint8_t* payload, unsigned int length);
void mqttPump();
void drainCommandQueue();
void doDeviceCommand(const String &command);
bool postVoice(const String &body);
void sendText(const String &text);
void sendEvent(const String &event);
void speak(const String &text, const String &lang = "mandarin");
void playChime(bool ok);
String sendAudioTpWhisper();
bool skipHttpHeaders(WiFiSSLClient &c, uint32_t timeoutMs);
String collectJsonBody(WiFiSSLClient &client, uint32_t timeoutMs);
String extractJson(const String &raw);


void setup()
{
    Serial.begin(115200);

    // Connection to internet
    while (status != WL_CONNECTED) {
        Serial.print("Attempting to connect to WPA SSID: ");
        Serial.println(ssid);
        status = WiFi.begin(ssid, pass);
        delay(2000);
    }
    Serial.println("WiFi Connected!");

    // ★ 時光機駭客法:板子沒有 RTC/NTP,開機強設系統時間才能通過 SSL 憑證驗證。
    // ⚠️ 這個值必須接近「燒錄當天」,不能只是「某個 2026 年的日期」:
    //    mqttgo.io 用 Let's Encrypt 的 90 天短效憑證,設得太早會被判
    //    「憑證尚未生效」(notBefore 在未來)而連不上 MQTT。
    //    1785078232 = 2026-07-26。重燒韌體時請更新成當天的 epoch:
    //    macOS/Linux 用 `date +%s` 取得。
    struct timeval tv;
    tv.tv_sec = 1785078232;
    tv.tv_usec = 0;
    settimeofday(&tv, NULL);
    Serial.println("System time forcibly set to 2026-07-26 to pass SSL verification!");

    // list files under root directory
    bool sdOK = fs.begin();
    if (!sdOK) {
        Serial.println("[WARN] SD card init failed!");
    }

    // initialize the pushbutton pin as an input:
    pinMode(buttonPin, INPUT_PULLUP);    // 按鈕接 D9 與 GND
    Serial.println("[BTN] pin D" + String(buttonPin) + " INPUT_PULLUP（按下=LOW=0）,"
                   + "長按門檻 " + String(buttonPressInterval) + " ms,開機當下電平="
                   + String(digitalRead(buttonPin)));
    pinMode(LED_BUILTIN, OUTPUT);
    pinMode(LED_G, OUTPUT);

    // I2S 揚聲器
    amp.begin();
    amp.setShutdownPin(10);
    amp.setVolume(ampVolume);

    // MQTT 下行:設定好參數,實際連線交給 loop() 的 mqttPump()(帶退避重連),
    // 這樣即使開機時 broker 連不上也不會卡住開機流程。
    mqttNet.setRootCA((unsigned char*)mqtt_root_ca);
    mqtt.setServer(mqtt_server, mqtt_port);
    mqtt.setKeepAlive(mqtt_keepalive);
    mqtt.setCallback(onMqttMessage);
    // 預設 buffer 只有 512 bytes,而中文 speak 指令一個字就 3 bytes,
    // 進度播報那種長句加上 JSON 外殼很容易超過 → 封包會被整個丟掉。
    mqtt.setBufferSize(1024);
    mqtt.setPublishQos(1);    // 上下線狀態也走 QoS 1

    // Configure audio peripheral for audio data output
    audio.configAudio(configA);
    audio.begin();
    // Configure AAC audio encoder
    aac.configAudio(configA);
    aac.begin();

    // Configure MP4 recording settings
    mp4.configAudio(configA, CODEC_AAC);
    mp4.setRecordingDuration(recordSeconds);
    mp4.setRecordingFileCount(1);
    mp4.setRecordingFileName(String(FILENAME));
    mp4.setRecordingDataType(STORAGE_AUDIO);    // Set MP4 to record audio only

    // Configure StreamIO object to stream data from audio channel to AAC encoder
    audioStreamer1.registerInput(audio);
    audioStreamer1.registerOutput(aac);
    if (audioStreamer1.begin() != 0) {
        Serial.println("StreamIO link start failed");
    }

    // Configure StreamIO object to stream data from AAC encoder to MP4
    audioStreamer2.registerInput(aac);
    audioStreamer2.registerOutput(mp4);
    if (audioStreamer2.begin() != 0) {
        Serial.println("StreamIO link start failed");
    }

    // 開機自檢提示音:此時 WiFi 已連上(前面會卡到連上為止)。
    // SD 正常 → 播 ready.wav(若存在),否則合成「上揚雙音」;
    // SD 異常 → 合成「三聲低音」警告。
    if (sdOK) {
        if (!amp.playWav(fs, "ready.wav")) {
            playChime(true);
        }
        Serial.println("System ready!");
    } else {
        playChime(false);
    }
}

void loop()
{
    // MQTT:維持連線(斷了就退避重連)並收下行指令
    mqttPump();
    // 消化佇列裡的下行指令(在這裡播,不在 callback 裡播)。
    // 錄音中先不播,免得自己的喇叭聲被麥克風錄進去。
    if (recordingstate != 1) {
        drainCommandQueue();
    }

    // Button state
    // 診斷 log:每個電平邊緣印一次,帶上「維持了多久」——按鈕行為出問題時,
    // 從這裡可以直接看出是彈跳(極短的按下/放開)、還是狀態機判斷有誤。
    int newButtonState = digitalRead(buttonPin);
    if (newButtonState != buttonState) {
        unsigned long held = millis() - buttonPressTime;
        if (newButtonState == LOW) {
            Serial.println("[BTN] ↓ 按下（前一次放開後隔了 " + String(held) + " ms）");
        } else {
            Serial.println("[BTN] ↑ 放開（按住了 " + String(held) + " ms）");
        }
        buttonPressTime = millis();
        longPressLogged = false;    // 新的一次按壓,長按 log 重新武裝
    }
    // update button state
    buttonState = newButtonState;

    // update recording state(順便印出轉換,對照按鈕事件才知道誰觸發了誰)
    int newRecordingState = (int)(mp4.getRecordingState());
    if (newRecordingState != recordingstate) {
        Serial.println("[BTN] 錄音狀態 " + String(recordingstate) + " → " + String(newRecordingState)
                       + "（0=停止 1=錄音中）");
    }
    recordingstate = newRecordingState;

    // check if the button has been held for at least 2 seconds
    if (buttonState == LOW && millis() - buttonPressTime >= buttonPressInterval) {
        // button has been pressed for at least 2 seconds
        buttonPressedFor2Seconds = true;
    } else {
        // button was released before 2 seconds
        buttonPressedFor2Seconds = false;
    }
    // if button has been pressed for at least 2 seconds
    if (buttonPressedFor2Seconds) {
        if (!longPressLogged) {
            Serial.println("[BTN] 按住已達 " + String(buttonPressInterval) + " ms 門檻"
                           + "（此刻 recordingstate=" + String(recordingstate) + "）");
            longPressLogged = true;
        }
        if (recordingstate == 1) {
            digitalWrite(LED_BUILTIN, HIGH);
        } else {
            // ⚠️ 這行如果連續刷出很多筆,代表同一次按壓重複觸發了 mp4.begin():
            //    buttonPressTime 只在「電平改變」時更新,所以按著不放的話
            //    millis()-buttonPressTime 會一直 >= 門檻,這個分支每輪都會進來,
            //    直到 mp4 回報 recordingstate=1 為止。
            Serial.println("[BTN] → 開始錄音（本次已按住 "
                           + String(millis() - buttonPressTime) + " ms）");
            // 先播開場提示音,播完才開始錄音
            amp.playWav(fs, "init.wav");
            mp4.begin();
            stopArmed = false;    // 此刻按鈕還被按住,先不接受停止;放開後才 arm
            Serial.println("Recording (press button again or type 'stop' to finish)");
        }
    }

    // 錄音中:按鈕放開後「再按一下」→ 提前結束錄音
    if (recordingstate == 1) {
        if (buttonState == HIGH) {
            if (!stopArmed) {
                Serial.println("[BTN] 已武裝:再按一下即可結束錄音");
            }
            stopArmed = true;
        } else if (stopArmed && prevButtonLevel == HIGH) {
            Serial.println("[BTN] → 停止錄音（第二次按下的瞬間觸發）");
            mp4.end();    // 走 mp4RecordingStop,檔案一樣會正常收尾
            stopArmed = false;
        }
    }
    prevButtonLevel = buttonState;

    // 序列輸入:stop=提前結束錄音;sos/fall=模擬事件上報(沒有實體 SOS 鍵與
    // 相機時也能跑完整條「感知→決策→行動」鏈路,demo 用)
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n') {
            serialLine.trim();
            if (recordingstate == 1 && serialLine == "stop") {
                Serial.println("Stop recording (serial)");
                mp4.end();
            } else if (serialLine == "sos") {
                sendEvent("sos");
            } else if (serialLine == "fall") {
                sendEvent("fall_suspected");
            }
            serialLine = "";
        } else if (c != '\r') {
            serialLine += c;
        }
    }
    if (recordingstate == 1 && previousRecordingState == 0) {
        // Change from 0 to 1
        digitalWrite(LED_BUILTIN, HIGH);
    } else if (recordingstate == 0 && previousRecordingState == 1) {
        // Change from 1 to 0
        digitalWrite(LED_BUILTIN, LOW);
        // ⚠️ 從這裡到本區塊結束(wait.wav → ASR → /voice → TTS 播放)全部是阻塞的,
        //    可能長達數十秒;這段期間主迴圈不會執行,按鈕**完全不會被讀取**。
        //    使用者在這段時間內按的任何一下都會被吃掉——「按了沒反應」多半是這裡。
        unsigned long blockStart = millis();
        Serial.println("[BTN] ⏸ 進入阻塞處理（ASR→/voice→TTS）,期間按鈕不會有反應");
        // 300ms + wait.wav 的播放時間,足夠讓 MP4 檔案收尾寫完
        delay(300);
        // 等待期間播放提示音,墊住 STT/TTS 的處理時間
        amp.playWav(fs, "wait.wav");
        String text = sendAudioTpWhisper();
        Serial.println(text);
        if (text.length() > 0 && text != "null" && !text.startsWith("Connected to")) {
            // ASR 後的文字送雲端語音 Agent(不再直連 LLM):server 會做意圖分類、
            // 起 20 秒升級計時、必要時開派遣單,並同步回一句要立刻播的話。
            sendText(text);
        }
        // ⚠️ 診斷提示(目前刻意不修,先讓 log 呈現原始行為):
        //    若阻塞期間按鈕一直被按住,電平沒有變化 → buttonPressTime 仍停在很久以前,
        //    下一輪 millis()-buttonPressTime 必定 >= 2000,會「立刻」再開一次錄音。
        //    如果下面這行之後緊接著就出現 [BTN] → 開始錄音,而中間沒有 ↓按下 的邊緣 log,
        //    那就是這個成因。
        Serial.println("[BTN] ▶ 阻塞處理結束,共 " + String(millis() - blockStart)
                       + " ms;按鈕恢復反應（此刻電平=" + String(digitalRead(buttonPin)) + "）");
    }

    // Check if there are incoming bytes available from the server
    while (wifiClient.available()) {
        char c = wifiClient.read();
        Serial.write(c);
    }
    previousRecordingState = recordingstate;
    delay(10);
}

// ================= MQTT 下行 =================

// MQTT callback:只把 payload 複製進佇列就返回(不阻塞),實際發聲在主迴圈。
void onMqttMessage(char* topic, uint8_t* payload, unsigned int length)
{
    String msg = "";
    msg.reserve(length + 1);
    for (unsigned int i = 0; i < length; i++) {
        msg += (char)payload[i];
    }
    Serial.println("[MQTT] ◀ " + String(topic) + "  " + msg);

    if (cmdCount >= CMD_QUEUE_SIZE) {
        // 佇列滿:丟最舊的。急救場景下「最新的指示」比「補完舊的」重要。
        Serial.println("[MQTT] 佇列已滿,丟棄最舊的一筆");
        cmdHead = (cmdHead + 1) % CMD_QUEUE_SIZE;
        cmdCount--;
    }
    cmdQueue[(cmdHead + cmdCount) % CMD_QUEUE_SIZE] = msg;
    cmdCount++;
}

// 維持 MQTT 連線:斷線時依指數退避重連,重連後重新 subscribe 並發 online。
// 全程不阻塞主迴圈(用 millis 排程而不是 delay)。
void mqttPump()
{
    if (mqtt.connected()) {
        mqtt.loop();
        return;
    }
    if (millis() < mqttNextAttempt) {
        return;    // 還沒到下次重試時間
    }

    Serial.println("[MQTT] 連線中 " + String(mqtt_server) + ":" + String(mqtt_port) + " …");
    // LWT:broker 偵測到本機斷線時,自動幫我們發 offline
    // (後台「裝置離線」顯示免費取得,不用另外做心跳)
    //
    // ⚠️ 最後一個參數 cleanSession 必須是 false,而且一定要用這個 8 參數版本:
    //    7 參數的多載把 cleanSession 寫死成 true,broker 會在斷線時丟掉 session,
    //    QoS 1 的「斷線期間補投」就完全不會發生——急救逾時階梯的指令只要遇上
    //    一次短暫斷線就永遠消失。這台是急救裝置,漏一則升級指令的代價是人命。
    bool ok = mqtt.connect(
        device_serial.c_str(), NULL, NULL, status_topic.c_str(), 1, false, "offline", false);
    if (ok) {
        mqttBackoff = 1000;    // 連上就把退避重置
        mqtt.subscribe(cmd_topic.c_str(), 1);    // QoS 1:斷線期間的指令 broker 會補投
        mqtt.publish(status_topic.c_str(), "online");
        Serial.println("[MQTT] 已連線,訂閱 " + cmd_topic + " (QoS 1)");
    } else {
        mqttNextAttempt = millis() + mqttBackoff;
        Serial.println("[MQTT] 連線失敗 rc=" + String(mqtt.state()) + ","
                       + String(mqttBackoff / 1000) + " 秒後重試");
        mqttBackoff *= 2;
        if (mqttBackoff > mqttBackoffMax) {
            mqttBackoff = mqttBackoffMax;
        }
    }
}

// 消化佇列:每次主迴圈最多處理一則訊息(一則可含多個指令),處理完就返回,
// 這樣按鈕與錄音狀態不會因為連續播報而長時間失去反應。
void drainCommandQueue()
{
    if (cmdCount == 0) {
        return;
    }
    String msg = cmdQueue[cmdHead];
    cmdHead = (cmdHead + 1) % CMD_QUEUE_SIZE;
    cmdCount--;

    JsonDocument doc;
    if (deserializeJson(doc, msg) != DeserializationError::Ok) {
        Serial.println("[MQTT] payload 不是合法 JSON,忽略");
        return;
    }
    JsonArray commands = doc["commands"].as<JsonArray>();
    if (commands.isNull()) {
        Serial.println("[MQTT] payload 沒有 commands 陣列,忽略");
        return;
    }
    for (JsonObject c : commands) {
        String type = c["type"].as<String>();
        if (type == "speak") {
            String text = c["text"].as<String>();
            String lang = c["lang"].as<String>();    // mandarin / taigi
            Serial.println("[MQTT] speak(" + lang + "): " + text);
            speak(text, lang.length() > 0 && lang != "null" ? lang : "mandarin");
        } else if (type == "device") {
            doDeviceCommand(c["command"].as<String>());
        } else {
            Serial.println("[MQTT] 未知指令類型:" + type);
        }
    }
}

// 裝置動作指令:volume_up / volume_down / stop_speak / repeat
void doDeviceCommand(const String &command)
{
    Serial.println("[CMD] " + command);
    if (command == "volume_up") {
        ampVolume = min(1.0f, ampVolume + 0.2f);
        amp.setVolume(ampVolume);
    } else if (command == "volume_down") {
        ampVolume = max(0.0f, ampVolume - 0.2f);
        amp.setVolume(ampVolume);
    } else if (command == "repeat") {
        if (lastSpokenText.length() > 0) {
            speak(lastSpokenText, lastSpokenLang);
        }
    } else if (command == "stop_speak") {
        // 播放本身是阻塞的(playWavStream 跑完才回來),沒辦法從外面中斷,
        // 所以這裡的語意是「別再播後面排隊的了」:清空佇列。
        cmdCount = 0;
        Serial.println("[CMD] 已清空待播指令佇列");
    } else {
        Serial.println("[CMD] 未知裝置指令,忽略");
    }
}

// ================= 上行 POST /voice =================

// 送一筆 JSON 給語音 Agent server,處理回應(播 reply、執行 action.command)。
// 回傳是否成功拿到回應。
bool postVoice(const String &body)
{
    WiFiSSLClient client;

    Serial.println("[VOICE] POST https://" + String(voice_server) + voice_path);
    Serial.println("[VOICE] ▶ " + body);
    if (!client.connect(voice_server, 443)) {
        Serial.println("[VOICE] 連線失敗");
        return false;
    }

    client.println("POST " + voice_path + " HTTP/1.1");
    client.println("Host: " + String(voice_server));
    client.println("Content-Type: application/json");
    client.println("Content-Length: " + String(body.length()));
    client.println("Connection: close");
    client.println();
    client.print(body);
    client.flush();

    if (!skipHttpHeaders(client, voice_timeout_ms)) {
        Serial.println("[VOICE] 沒有 HTTP 回應(Render 冷啟動可能要 30–60 秒)");
        client.stop();
        return false;
    }
    String feedback = collectJsonBody(client, voice_timeout_ms);
    client.stop();

    // Render/Cloudflare 回 chunked,要剝掉夾在 body 裡的長度框架行
    feedback = extractJson(feedback);
    if (feedback.length() == 0) {
        Serial.println("[VOICE] 回應裡沒有 JSON");
        return false;
    }

    JsonDocument doc;
    if (deserializeJson(doc, feedback) != DeserializationError::Ok) {
        Serial.println("[VOICE] JSON 解析失敗:" + feedback);
        return false;
    }

    String reply = doc["reply"].as<String>();
    String intent = doc["intent"].as<String>();
    String lang = doc["lang"].as<String>();
    Serial.println("[VOICE] ◀ intent=" + intent + " lang=" + lang + " reply=" + reply);

    // activity_report 這類事件 server 回 200 但沒有 reply,不用發聲
    if (reply.length() > 0 && reply != "null") {
        speak(reply, lang.length() > 0 && lang != "null" ? lang : "mandarin");
    }
    // action.command 有值才執行裝置動作
    String command = doc["action"]["command"].as<String>();
    if (command.length() > 0 && command != "null") {
        doDeviceCommand(command);
    }
    return true;
}

// 一般語音(ASR 後的文字)
void sendText(const String &text)
{
    JsonDocument doc;
    doc["device_serial"] = device_serial;
    doc["text"] = text;
    String body;
    serializeJson(doc, body);
    postVoice(body);
}

// 事件上報:sos / fall_suspected / inactivity_suspected
// SOS 上行失敗一定要有本地退路——不能靜默(契約 §3 要點)。
void sendEvent(const String &event)
{
    JsonDocument doc;
    doc["device_serial"] = device_serial;
    doc["event"] = event;
    String body;
    serializeJson(doc, body);

    if (postVoice(body)) {
        return;
    }
    if (event == "sos" || event == "inactivity_suspected") {
        Serial.println("[VOICE] 上行失敗,重試一次");
        if (postVoice(body)) {
            return;
        }
    }
    if (event == "sos") {
        // 連不上雲端也必須讓長輩知道「有人在處理」,不能安靜。
        // TTS 也要網路,所以先響本地警示音再試著發聲。
        playChime(false);
        speak("我聯絡不上網路,正在重試,請您先待在原地不要動。");
    }
}

String sendAudioTpWhisper() {
    memset(buf, 0, sizeof(buf));
    fs.readDir(fs.getRootPath(), buf, sizeof(buf));
    filepath = String(fs.getRootPath()) + FILENAME_EXT;
    p = buf;
    while (strlen(p) > 0) {
        /* list out file name image will be saved as FILENAME */
        if (strstr(p, FILENAME_EXT.c_str()) != NULL) {
            Serial.println("[INFO] Found '"+FILENAME_EXT+"' in the string.");
            Serial.println("[INFO] Processing file...");
        } else {
            // Serial.println("Substring 'image.jpg' not found in the
            // string.");
        }
        p += strlen(p) + 1;
    }
    uint8_t *fileinput;
    file = fs.open(filepath);
    unsigned int fileSize = file.size();
    fileinput = (uint8_t *)malloc(fileSize + 1);
    file.read(fileinput, fileSize);
    fileinput[fileSize] = '\0';
    file.close(); 
     
    WiFiSSLClient client_tcp;
    Serial.println("Connect to " + String(api_server) + " via HTTPS (Port 443)");
    if (client_tcp.connect(api_server, 443)) {
    // WiFiClient client_tcp;
    // Serial.println("Connect to " + String(api_server) + " via HTTP (Port 80)");
    // if (client_tcp.connect(api_server, 80)) {
      Serial.println("Connection successful");
      
      String head = "--Taiwan\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n"+model+"\r\n--Taiwan\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nzh\r\n--Taiwan\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--Taiwan\r\nContent-Disposition: form-data; name=\"file\"; filename=\""+FILENAME_EXT+"\"\r\nContent-Type: video/mp4\r\n\r\n";
      Serial.println(head);
      String tail = "\r\n--Taiwan--\r\n";

      // 用 size_t，uint16_t 在檔案 > 64KB 時會溢位、Content-Length 會算錯
      size_t totalLen = head.length() + fileSize + tail.length();
    
      client_tcp.println("POST "+api_path+" HTTP/1.1");
      client_tcp.println("Connection: close");   // 一次性請求，讓伺服器回完就關，板子讀到關閉為止
      client_tcp.println("Host: " + String(api_server));
      // ⚠️ XCC Gateway 認的是 x-bf-vk 標頭,不是 OpenAI 慣用的 Authorization: Bearer。
      //    送錯標頭時 gateway 不會回 401,而是**整個掛住不回應**(Cloudflare 前端最後
      //    回 524 origin timeout),從板子這端看起來就像「ASR 沒反應」。
      //    參考 cloud/prototype/src/llm/bedrock.js —— 與 ASR 同一把金鑰、同一個標頭。
      client_tcp.println("x-bf-vk: " + api_key);
      client_tcp.println("Content-Length: " + String(totalLen));
      client_tcp.println("Content-Type: multipart/form-data; boundary=Taiwan");
      client_tcp.println();
      client_tcp.print(head);

      // 用 offset 送檔，不去動 malloc 回來的原始指標（才能正確 free），
      // 且檔案大小剛好是 1024 倍數時，最後一塊也不會漏送
      for (size_t sent = 0; sent < fileSize; ) {
        size_t chunk = (fileSize - sent > 1024) ? 1024 : (fileSize - sent);
        client_tcp.write(fileinput + sent, chunk);
        sent += chunk;
      }

      client_tcp.print(tail);
      client_tcp.flush();      // 確保整個請求（含尾端 boundary）真的送出去，伺服器才會回應
      free(fileinput);
  
      String getResponse="",Feedback="";
      unsigned long waitTime = 20000;   // 從送出算起，最長等 20 秒
      unsigned long startTime = millis();
      unsigned long lastData  = millis();
      boolean state = false;

      // 不靠 connected() 判斷開始（AmebaPro2 在伺服器回應前就可能回 false），
      // 也不要一收到第一個 byte 就 break（JSON 分封包會被截斷）。
      // 作法：把 header 後的 body 全部收進 Feedback。結束條件（先到先贏）：
      //   1. 已收到 body 且伺服器關閉連線（我們送 Connection: close，
      //      伺服器回完 JSON 就會關）→ 立刻結束,不用乾等
      //   2. 已收到 body 且連續 150ms 沒有新資料
      while ((millis() - startTime) < waitTime) {
        while (client_tcp.available())  {
            char c = client_tcp.read();
            if (state==true) {
              Feedback += String(c);   // 空行之後全部是 body
            } else {
              if (c == '\n') {
                if (getResponse.length()==0) state=true;   // 遇到空行 = header 結束
                getResponse = "";
              } else if (c != '\r') {
                getResponse += String(c);
              }
            }
            lastData = millis();
         }
         // 注意:connected() 在傳輸空檔會短暫回 false,不能立刻採信,
         // 要搭配「連續一小段時間沒新資料」才算真的收完(否則 body 被截斷)
         if (Feedback.length() > 0) {
            bool closed = !client_tcp.available() && !client_tcp.connected();
            if (closed && (millis() - lastData) > 100) break;   // 已關線且安靜 100ms
            if ((millis() - lastData) > 300) break;             // 備援:安靜 300ms
         }
         // ⚠️ 這裡曾經呼叫 mqttPump() 想維持下行連線,結果反而弄壞 ASR:
         //    MQTT 斷線時 mqttPump() 會做一次 TLS 握手,在這塊板子上可能阻塞數秒,
         //    期間沒有讀取 ASR 資料 → 回到迴圈時 millis()-lastData 已 > 300ms →
         //    誤判「安靜夠久＝收完了」而提早 break,body 被截斷。
         //    正確做法是讓 MQTT 在這段期間自然斷線:connect 時 cleanSession=false、
         //    訂閱 QoS 1,broker 會保留 session,重連後把這段期間的指令補投回來
         //    (已實測 mqttgo.io 的 sessionPresent 與補投行為)。所以這裡什麼都不做。
         Serial.print(".");
         delay(20);
      }
      Serial.println("\n=== RAW RESPONSE FROM SERVER ===");
      Serial.println(Feedback);
      Serial.println("================================");
      
      client_tcp.stop();
      JsonObject obj;
      JsonDocument doc;
      deserializeJson(doc, Feedback);
      obj = doc.as<JsonObject>();
      String getText = obj["text"].as<String>();
      if (getText == "null")
        getText = obj["error"]["message"].as<String>();    
      return getText;
    }
    else {
      free(fileinput);
      return "Connected to "+String(api_server)+" failed.";
    }
}

// ================= TTS(文字轉語音)+ 播放 =================

// 讀掉 HTTP 回應標頭,讀到空行(標頭結束)回傳 true
bool skipHttpHeaders(WiFiSSLClient &c, uint32_t timeoutMs = 10000)
{
    String line = "";
    uint32_t t0 = millis();
    while (millis() - t0 < timeoutMs) {
        while (c.available()) {
            char ch = c.read();
            if (ch == '\n') {
                if (line.length() == 0) {
                    return true;
                }
                line = "";
            } else if (ch != '\r') {
                line += ch;
            }
        }
        if (!c.connected() && !c.available()) {
            break;
        }
        delay(1);
    }
    return false;
}

// 收 JSON 回應 body:即時追蹤大括號深度(忽略字串內的括號與跳脫字元),
// 最外層 JSON 一閉合就立刻結束。不依賴 connected() 或時間窗猜測,
// 對 chunked/TLS 分段傳輸免疫,而且收完當下就返回(最快)。
String collectJsonBody(WiFiSSLClient &client, uint32_t timeoutMs)
{
    String feedback = "";
    uint32_t start = millis(), lastData = millis();
    int depth = 0;
    bool started = false, inStr = false, esc = false;
    uint8_t chunk[256];

    while ((millis() - start) < timeoutMs) {
        // 重要:不能用 available() 把關!AmebaPro2 的 WiFiSSLClient 在
        // TLS 紀錄解密進內部緩衝後 available() 會回 0,但 read() 仍讀得到,
        // 用 available() 把關會讓 body 尾段永遠收不到(實測卡在 ~320 bytes)。
        int n = client.read(chunk, sizeof(chunk));
        if (n <= 0) {
            if (!client.connected() && (millis() - lastData) > 1000) {
                break;    // 關線且持續沒資料,放棄
            }
            if (feedback.length() > 0 && (millis() - lastData) > 3000) {
                break;    // 備援逃生口:資料流死了
            }
            delay(5);
            continue;
        }
        lastData = millis();
        for (int i = 0; i < n; i++) {
            char c = (char)chunk[i];
            feedback += c;
            if (esc) {
                esc = false;
            } else if (inStr) {
                if (c == '\\') {
                    esc = true;
                } else if (c == '"') {
                    inStr = false;
                }
            } else if (c == '"') {
                inStr = true;
            } else if (c == '{') {
                depth++;
                started = true;
            } else if (c == '}') {
                depth--;
                if (started && depth == 0) {
                    return feedback;    // 最外層 JSON 閉合 = 收完,立刻返回
                }
            }
        }
    }
    return feedback;
}

// 解析一行十六進位的 chunk 長度(可能帶 ";ext" 擴充欄位)。不是合法十六進位就回 false。
bool parseChunkLen(const String &s, int start, int end, long &out)
{
    if (end <= start) {
        return false;
    }
    long v = 0;
    bool any = false;
    for (int i = start; i < end; i++) {
        char c = s[i];
        int d;
        if (c >= '0' && c <= '9') {
            d = c - '0';
        } else if (c >= 'a' && c <= 'f') {
            d = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            d = c - 'A' + 10;
        } else if (c == ';' && any) {
            break;    // chunk extension,長度到此為止
        } else {
            return false;
        }
        v = v * 16 + d;
        any = true;
        if (v > 100000) {
            return false;    // 明顯不合理,當作不是 chunked
        }
    }
    if (!any) {
        return false;
    }
    out = v;
    return true;
}

// 還原 chunked transfer encoding 的 body。不是 chunked 就原樣回傳。
//
// 為什麼需要:Render/Cloudflare 一律回 chunked(而且無視我們送的 Connection: close),
// body 長成 `<hexlen>CRLF<資料>CRLF<hexlen>CRLF<資料>…`。
// ⚠️ 不能只是「把看起來像框架的行跳掉」——chunk 邊界會落在 JSON 字串「內部」
//    (長中文回覆幾乎必然如此,實測就是切在 reply 的中文字中間),那時靠 JSON
//    結構判斷根本分不出框架與資料。唯一可靠的做法是照長度欄位切,如下。
String dechunk(const String &raw)
{
    String out = "";
    int pos = 0;
    bool decoded = false;    // 有沒有真的解出至少一段 chunk
    while (pos < (int)raw.length()) {
        int crlf = raw.indexOf("\r\n", pos);
        if (crlf < 0) {
            break;    // 沒有框架行了(非 chunked,或已到尾端)
        }
        long len = 0;
        if (!parseChunkLen(raw, pos, crlf, len)) {
            break;    // 這行不是長度 → 不是 chunked
        }
        if (len == 0) {
            decoded = true;    // 結束 chunk
            break;
        }
        int dataStart = crlf + 2;
        int dataEnd = dataStart + (int)len;
        if (dataEnd > (int)raw.length()) {
            dataEnd = raw.length();    // collectJsonBody 可能在收完 JSON 就提前收手
        }
        out += raw.substring(dataStart, dataEnd);
        pos = dataEnd + 2;    // 跳過資料尾端的 CRLF
        decoded = true;
    }
    // 一段都沒解出來就代表根本不是 chunked(例如整包就是裸 JSON、沒有任何 CRLF),
    // 這時要原樣送回;回傳空的累積值會讓呼叫端誤判成「沒有 JSON」。
    return decoded ? out : raw;
}

// 從 HTTP body 取出最外層的 JSON 物件(先還原 chunked,再依大括號深度擷取)。
// 找不到 JSON 回傳空字串。
String extractJson(const String &raw)
{
    String body = dechunk(raw);
    String out = "";
    int depth = 0;
    bool started = false, inStr = false, esc = false;

    for (unsigned int i = 0; i < body.length(); i++) {
        char c = body[i];
        if (!started) {
            if (c == '{') {
                started = true;
                depth = 1;
                out += c;
            }
            continue;
        }
        out += c;
        if (inStr) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                inStr = false;
            }
            continue;
        }
        if (c == '"') {
            inStr = true;
        } else if (c == '{') {
            depth++;
        } else if (c == '}') {
            depth--;
            if (depth == 0) {
                return out;    // 最外層閉合
            }
        }
    }
    return started ? out : String("");
}

// POST 文字給 TTS API,回傳音檔 URL 的路徑部分(失敗回傳空字串)
String requestTTS(const String &text)
{
    WiFiSSLClient client;

    Serial.println("[TTS] Connecting...");
    if (!client.connect(tts_server, 443)) {
        Serial.println("[TTS] connection failed");
        return "";
    }

    String boundary = "HUB8735TTS";
    String body = "--" + boundary + "\r\n"
                  "Content-Disposition: form-data; name=\"text\"\r\n\r\n"
                  + text + "\r\n"
                  "--" + boundary + "--\r\n";

    client.println("POST " + tts_path + " HTTP/1.1");
    client.println("Host: " + String(tts_server));
    client.println("Accept: application/json");
    client.println("Connection: close");
    client.println("Content-Type: multipart/form-data; boundary=" + boundary);
    client.println("Content-Length: " + String(body.length()));
    client.println();
    client.print(body);
    client.flush();

    if (!skipHttpHeaders(client)) {
        Serial.println("[TTS] no HTTP response");
        client.stop();
        return "";
    }

    // 收 JSON body:用大括號深度判斷結束,見 collectJsonBody 說明
    String feedback = collectJsonBody(client, 20000);
    client.stop();

    // 伺服器用 chunked transfer encoding,body 夾雜十六進位長度框架行
    // (例如 "a6"、"0")— 用 extractJson 取最外層 JSON 並剝掉框架行。
    feedback = extractJson(feedback);
    if (feedback.length() == 0) {
        Serial.println("[TTS] no JSON in response");
        return "";
    }

    JsonDocument ttsDoc;
    if (deserializeJson(ttsDoc, feedback) != DeserializationError::Ok) {
        Serial.println("[TTS] bad JSON: " + feedback);
        return "";
    }
    String ttsStatus = ttsDoc["status"].as<String>();
    String url = ttsDoc["url"].as<String>();
    if (ttsStatus != "Success" || url.length() == 0) {
        Serial.println("[TTS] API error: " + feedback);
        return "";
    }
    Serial.println("[TTS] " + url);

    // 取出路徑部分:去掉 https://host
    int pathStart = url.indexOf('/', 8);    // 跳過 "https://"
    return (pathStart > 0) ? url.substring(pathStart) : "";
}

// 抓音檔 URL 並邊下載邊播放
void playFromPath(const String &audioPath)
{
    if (audioPath.length() == 0) {
        return;
    }
    WiFiSSLClient client;

    if (!client.connect(tts_server, 443)) {
        Serial.println("[Play] connection failed");
        return;
    }
    client.println("GET " + audioPath + " HTTP/1.1");
    client.println("Host: " + String(tts_server));
    client.println("Connection: close");
    client.println();

    if (!skipHttpHeaders(client)) {
        Serial.println("[Play] no HTTP response");
        client.stop();
        return;
    }

    Serial.println("[Play] streaming...");
    if (amp.playWavStream(client)) {
        Serial.println("[Play] done.");
    } else {
        Serial.print("[Play] failed: ");
        Serial.println(amp.lastError());
    }
    client.stop();
}

// 播一句話。lang 是「選語音」的旗標(mandarin/taigi),text 一律是正常中文——
// 雲端不做台語翻譯,台語是由裝置端 TTS 把同一份中文念成台語(契約 §3②)。
//
// ⚠️ 現況:目前接的 ATEN TTS 只有一種語音,lang=taigi 會被念成國語。
// 這是「台語播報能否落地」的關鍵未決項(見 hardware-integration.md 交接清單),
// 所以這裡不靜默忽略、而是明確 log 出來,換到支援台語的 TTS 時只要改 requestTTS。
void speak(const String &text, const String &lang)
{
    lastSpokenText = text;    // 供 repeat 指令重播
    lastSpokenLang = lang;
    if (lang == "taigi") {
        Serial.println("[TTS] ⚠️ 要求台語,但目前 TTS 服務只有國語語音 → 先用國語念");
    }
    String audioPath = requestTTS(text);
    if (audioPath.length() > 0) {
        playFromPath(audioPath);
    }
}

// ================= 合成提示音(不需要音檔) =================

// 產生一段正弦波推給揚聲器;freq = 0 代表靜音。
// 頭尾各 4ms 線性淡入淡出,避免爆音。
void writeTone(uint32_t freq, uint32_t ms, float gain)
{
    const uint32_t sr = 16000;
    static int16_t tbuf[160];
    uint32_t total = sr * ms / 1000;
    uint32_t produced = 0;
    float phase = 0.0f;
    float step = 2.0f * PI * freq / sr;
    const uint32_t fade = 64;    // 4ms @ 16kHz

    while (produced < total) {
        uint32_t n = (total - produced > 160) ? 160 : (total - produced);
        for (uint32_t i = 0; i < n; i++) {
            uint32_t pos = produced + i;
            float env = 1.0f;
            if (pos < fade) {
                env = (float)pos / fade;
            } else if (total - pos <= fade) {
                env = (float)(total - pos) / fade;
            }
            tbuf[i] = (freq == 0) ? 0 : (int16_t)(sinf(phase) * 32767.0f * gain * env);
            phase += step;
        }
        amp.writePCM(tbuf, n);
        produced += n;
    }
}

// 開機提示音:ok = 上揚雙音(登登~),否則三聲低音警告
void playChime(bool ok)
{
    if (!amp.beginPCM(16000, 1)) {
        return;
    }
    if (ok) {
        writeTone(880, 120, 0.5f);
        writeTone(0, 40, 0.0f);
        writeTone(1320, 200, 0.5f);
    } else {
        for (int i = 0; i < 3; i++) {
            writeTone(392, 120, 0.5f);
            writeTone(0, 100, 0.0f);
        }
    }
    amp.endPCM();
}
