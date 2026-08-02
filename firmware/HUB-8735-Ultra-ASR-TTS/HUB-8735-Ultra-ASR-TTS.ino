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
#include <errno.h>
#include "NNAudioClassification.h"
// 521 類 YAMNet 標籤表(從 SDK 的 AudioClassification 範例複製過來,索引由訓練時固定)。
// 只拿來把 class id 轉成人看得懂的名字寫進 log——實際要不要反應由下面自己的白名單決定,
// 不用它的 filter 欄位(那是範例的做法,改 521 行的表比讀一份白名單難維護太多)。
#include "AudioClassList.h"

// ===== 機密設定（不進版控）=====
// 把 secrets.h.example 複製成 secrets.h（同資料夾，已在 .gitignore）並填入實際值。
// 沒有這個檔也編得過，但用的是下面的佔位符 → 連不上網、AWS IoT 也不會連。
#if defined(__has_include)
#  if __has_include("secrets.h")
#    include "secrets.h"
#  endif
#endif
#ifndef SECRET_WIFI_SSID
#define SECRET_WIFI_SSID "xxx"
#endif
#ifndef SECRET_WIFI_PASS
#define SECRET_WIFI_PASS "xxx"
#endif
#ifndef SECRET_ASR_API_KEY
#define SECRET_ASR_API_KEY "sk-jinsun-"    // 佔位符;實際值放 secrets.h(見下方 ASR 區塊)
#endif

// ===== 後端環境切換（改這一行就好）=====
// 0 = 正式環境：Render voice server + mqttgo.io + Supabase
// 1 = AWS 平行環境：API Gateway + Lambda + Step Functions + IoT Core + Aurora
//
// ⚠️ 兩套環境**不共用資料庫**：切過去之後這台裝置的事件只會出現在 AWS 那三端網址上，
//    正式環境的家屬 App 看不到（反之亦然）。交接說明見 docs/requirements/aws-handoff.md。
// 契約（topic、payload、QoS、LWT、/voice 的請求與回應）兩邊完全相同，只有端點與憑證不同。
#define BACKEND_AWS 1

char ssid[] = SECRET_WIFI_SSID;    // your network SSID (name)
char pass[] = SECRET_WIFI_PASS;    // your network password
int status = WL_IDLE_STATUS;

// ===== ASR(語音轉文字)=====
// 現用:自家的 SageMaker endpoint `breeze-asr-26`(faster-whisper Breeze-ASR-26 fp16),
// 由 jinsun-asr-openai Lambda 開成 OpenAI 相容的 /v1/audio/transcriptions。
// 部署:bash cloud/aws/scripts/deploy-asr-openai.sh
//
// 換過來的好處:不再依賴外部 gateway(XCC 那顆是別人的服務、金鑰也是別人發的),
// 模型權重與 endpoint 都在自己帳號裡。
//
// 刻意**不用 #if BACKEND_AWS 包起來**,理由與下方國語 TTS 完全相同:
// 這是無狀態的服務呼叫、沒有資料落地,不違反「兩套環境不共用資料庫」。
//
// ⚠️ 認證標頭不用改:那支 Lambda 同時吃 `x-bf-vk` 與 `Authorization: Bearer`,
//    刻意與 XCC Gateway 對齊,所以下面組請求的程式碼一行都不用動。
// ⚠️ 金鑰換人發了:AWS 這條是 `sk-jinsun-…`(deploy-asr-openai.sh 產生並印出),
//    不是 XCC 的 `sk-bf-…`。secrets.h 的 SECRET_ASR_API_KEY 要一起換。
// ⚠️ 音檔上限 4.5MB、單次請求上限 30 秒(API Gateway 整合逾時硬上限)。
//    板子最長錄 30 秒 ≈ 1MB,在範圍內。
String api_key = SECRET_ASR_API_KEY;
char api_server[] = "yr0ep335el.execute-api.us-west-2.amazonaws.com";
String api_path = "/v1/audio/transcriptions";
String model = "breeze-asr-26";

// —— 舊的 XCC Gateway(保留備援)——
// SageMaker endpoint 是 GPU 機型、會被 teardown 收掉;真的收掉時把上面四行註解、
// 改用下面四行即可切回去(路徑與標頭都相同,只有 host / model / 金鑰不同)。
// String api_key = SECRET_ASR_API_KEY;               // Groq - > https://console.groq.com/keys
// char api_server[] = "llm-gateway.xcc.tw";             // Groq - > api.groq.com
// String api_path = "/v1/audio/transcriptions";     // Groq - > /openai/v1/audio/transcriptions
// String model = "paulpengtw/faster-whisper-Breeze-ASR-26";                       // Groq - > whisper-large-v3-turbo or whisper-large-v3

#define FILENAME "test"
String FILENAME_EXT = String(FILENAME)+".mp4";
int recordSeconds = 30;         // 最長錄音上限(秒);可按鈕/序列輸入提前結束

// ===== TTS(文字轉語音):兩顆服務,依下行的 lang 分流 =====
// 台語:ATEN。⚠️ 這顆是**台語模型**,而且端點不吃 voice/lang 參數,
//       所以它只會講台語 —— 沒辦法拿它來念國語。
char tts_server[] = "kws.oaselab.org";
String tts_path = "/nutntweng/tts/aten/";

// 國語:Amazon Polly(Zhiyu),經 API Gateway 的 jinsun-tts Lambda。
// 回應直接是 WAV bytes(不是 ATEN 那種 JSON URL),POST 完就能邊收邊播,
// 少一次 TLS 握手(板子上一次握手就要幾百毫秒)。
// 部署:bash cloud/aws/scripts/deploy-tts.sh
//
// 刻意**不用 #if BACKEND_AWS 包起來**:TTS 是無狀態的服務呼叫、沒有資料落地,
// 不違反「兩套環境不共用資料庫」——上面的 ASR 也是同一個判斷。
// 這樣 Render 環境同樣念得出國語。
char tts_mandarin_server[] = "yr0ep335el.execute-api.us-west-2.amazonaws.com";
String tts_mandarin_path = "/tts";

// ===== 雲端語音 Agent server(上行 POST /voice) =====
// 契約見 docs/requirements/hardware-integration.md §3①:
//   請求 {device_serial, text} 或 {device_serial, event:"sos"|"fall_suspected"|…}
//   回應 {reply, intent, action:{command}, lang}
// 「大腦」在雲端(意圖分類、問診、20 秒升級計時、派遣志工),裝置只負責
// 收音、上報事件、發聲。原本直連 Gemini 的做法已換成這條,長輩的話才進得了
// 急救狀態機——直連 LLM 時雲端根本不知道有人在求救。
#if BACKEND_AWS
// AWS:API Gateway($default 路由 → jinsun-voice Lambda)。契約與 Render 那台逐欄位相同。
char voice_server[] = "yr0ep335el.execute-api.us-west-2.amazonaws.com";
// Lambda 冷啟動約 2–5 秒;API Gateway 的整合逾時上限本來就是 30 秒,等更久沒有意義。
const unsigned long voice_timeout_ms = 30000;
#else
char voice_server[] = "jinsun-voice-server-mg1f.onrender.com";
// Render 免費方案閒置會休眠,冷啟動可能 30–60 秒才回應
const unsigned long voice_timeout_ms = 60000;
#endif
String voice_path = "/voice";
// device_serial 全程固定,同時是 MQTT client id 與 topic 的一部分。
// 正式版由 BLE 配網寫入;現在先硬編碼(JS-0001 是資料庫既有種子,可直接對測)。
//
// ⚠️ 走 AWS 時這個字串有第三個身分:IoT **Thing 名稱**。IoT Policy 用
//    ${iot:Connection.Thing.ThingName} 限縮 client id 與 topic(cloud/aws/iot/device-policy.json),
//    所以 device_serial ≠ Thing 名稱 → 連線直接被切斷,而且不會有任何錯誤訊息。
//    AWS 上已建好的 Thing 是 JS-0001 與 JS-REAL-0001,燒進去的憑證要 attach 到同一個。
String device_serial = "JS-0002";

// ===== MQTT 下行(server publish → 裝置) =====
// 契約見 §3②:訂閱 jinsun/{serial}/cmd(QoS 1)、keep-alive 30s、
// 斷線指數退避重連(1s→2s→…→30s)、LWT jinsun/{serial}/status = "offline"。
// 為什麼要外部 broker:Render 這類 PaaS 只對外開 443,server 內嵌的 aedes(1883)
// 從公網進不來 → server 與裝置各自連上同一顆公共 broker 會合(契約完全不變)。
// AWS 這邊則是 IoT Core 當 broker,jinsun-speak Lambda 負責 publish;順帶補掉
// 「公共 broker 無認證、任何人都能對 jinsun/# 發指令」這個資安洞。
#if BACKEND_AWS
// AWS IoT Core 的 ATS endpoint(`aws iot describe-endpoint --endpoint-type iot:Data-ATS`)。
// 8883 = X.509 雙向 TLS。不要改成 443——443 要求 ALPN `x-amzn-mqtt-ca`,這個核心送不出去。
char mqtt_server[] = "a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com";
#else
char mqtt_server[] = "mqttgo.io";
#endif
const int mqtt_port = 8883;    // 一律走 TLS:實測此核心純 TCP(WiFiClient)收不到任何資料
// AWS IoT 允許的 keep-alive 是 30–1200 秒,30 剛好是下限(送 1–29 會被拉到 30)。
const int mqtt_keepalive = 30;
// topic 兩套環境完全相同,jinsun-speak Lambda publish 的也是這一條。
String cmd_topic = "jinsun/" + device_serial + "/cmd";
String status_topic = "jinsun/" + device_serial + "/status";

// ===== 裝置憑證(只有 AWS IoT 需要:X.509 雙向 TLS)=====
// 用下列指令重簽一組並掛上 policy 與 thing(私鑰無法從 AWS 取回,遺失就重簽)。
// 指令刻意包在 block 註解裡:shell 的行尾 \ 在 // 註解中會把下一行一起接進註解
// (-Wcomment),改回 // 會警告,而且哪天最後一行下面擺了程式碼就會被吃掉。
/*
  aws iot create-keys-and-certificate --set-as-active \
    --certificate-pem-outfile device.cert.pem --private-key-outfile device.key.pem \
    --public-key-outfile device.public.pem --query certificateArn --output text > cert.arn
  aws iot attach-policy --policy-name JinsunDevicePolicy --target "$(cat cert.arn)"
  aws iot attach-thing-principal --thing-name JS-0001 --principal "$(cat cert.arn)"
*/
// 兩個檔案的內容貼進 secrets.h(見 secrets.h.example)。**憑證與私鑰絕對不要進 git。**
#ifndef SECRET_AWS_DEVICE_CERT
#define SECRET_AWS_DEVICE_CERT "PASTE device.cert.pem HERE (see secrets.h.example)\n"
#endif
#ifndef SECRET_AWS_DEVICE_KEY
#define SECRET_AWS_DEVICE_KEY "PASTE device.key.pem HERE (see secrets.h.example)\n"
#endif
char* device_cert_pem = (char*)SECRET_AWS_DEVICE_CERT;
char* device_key_pem = (char*)SECRET_AWS_DEVICE_KEY;

// 憑證還是佔位符時要**在連線前就擋下來並講清楚**:AWS IoT 對認證/授權失敗的反應是
// 直接切斷 TCP,不會回 CONNACK 錯誤碼,PubSubClient 只會回 rc=-2,症狀長得跟
// 「網路不穩」一模一樣(aws-handoff.md §5),照著查會查錯方向。
bool deviceCertReady()
{
    return strncmp(device_cert_pem, "-----BEGIN ", 11) == 0
           && strstr(device_key_pem, "-----BEGIN ") != NULL;
}

// mqttgo.io 憑證由 Let's Encrypt 簽發,鏈根為 ISRG Root X1(下面這張)。
// ⚠️ Let's Encrypt 是 90 天短效憑證,而本板無 RTC/NTP、開機硬設時鐘(見 setup()):
//    重燒韌體時務必把 tv.tv_sec 更新到接近當天,否則會被判「憑證尚未生效」而連不上。
char* isrg_root_x1 =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n"
    "TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n"
    "cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\n"
    "WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\n"
    "ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\n"
    "MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\n"
    "h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\n"
    "0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\n"
    "A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\n"
    "T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\n"
    "B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\n"
    "B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\n"
    "KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\n"
    "OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\n"
    "jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\n"
    "qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\n"
    "rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\n"
    "HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\n"
    "hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\n"
    "ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\n"
    "3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\n"
    "NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\n"
    "ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\n"
    "TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\n"
    "jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\n"
    "oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n"
    "4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\n"
    "mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\n"
    "emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\n"
    "-----END CERTIFICATE-----\n";

// AWS IoT 的 ATS endpoint 由 Amazon Root CA 1 簽發(有效期到 2038,不像 Let's Encrypt 會
// 每 90 天換一次;但下面設系統時間那段還是不能省——時鐘落在**裝置憑證**的
// notBefore 之前一樣會驗不過,而裝置憑證是「重簽當天」才生效的)。
// 來源:https://www.amazontrust.com/repository/AmazonRootCA1.pem
char* amazon_root_ca1 =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF\n"
    "ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6\n"
    "b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL\n"
    "MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv\n"
    "b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj\n"
    "ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM\n"
    "9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw\n"
    "IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6\n"
    "VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L\n"
    "93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm\n"
    "jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC\n"
    "AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA\n"
    "A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI\n"
    "U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs\n"
    "N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv\n"
    "o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU\n"
    "5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy\n"
    "rqXRfboQnoZsG4q5WTP468SQvvG5\n"
    "-----END CERTIFICATE-----\n";

#if BACKEND_AWS
char* mqtt_root_ca = amazon_root_ca1;
#else
char* mqtt_root_ca = isrg_root_x1;
#endif

// D12 被 I2S 的 LRC 佔用、D13 是閃光燈 PWM(恆為 LOW),按鈕用 D9。
// 按鈕接 D9 與 GND,用 INPUT_PULLUP(按下 = LOW)。
const int buttonPin = 9;          // the number of the pushbutton pin
const int buttonPressInterval = 1000;          // 按住 1 秒觸發

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
// volume_up/volume_down 指令會調整這個值。
// ⚠️ 這是**兩顆 TTS 共用**的總音量，不要拿它補單一服務的音量差——Polly 那條路曾經
// 上板聽起來偏小聲(Polly 原始輸出峰值只到 −10 dBFS)，那是在 jinsun-tts Lambda 端做
// 峰值正規化解決的;從這裡調會連 ATEN(台語)一起變大聲，而且只剩 0.2 可加。
float ampVolume = 0.8;
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
// 順帶一提:preset 3 展開後就是 AudioSetting(16000, 1, USE_AUDIO_LEFT_DMIC),
// 與 SDK 的 AudioClassification 範例逐欄位相同——YAMNet 只吃 16kHz,所以錄音與
// 聲音偵測可以共用同一份設定、同一顆麥克風,不用開第二條音訊管線。
AudioSetting configA(3);
Audio audio;
AAC aac;
MP4Recording mp4;
StreamIO audioStreamer2(1, 1);    // 1 Input AAC -> 1 Output MP4

// ================= 本地聲音事件偵測(NPU / YAMNet) =================
//
// 【隱私】整段推論都在 RTL8735B 的 NPU 上跑,音訊**從來不離開這塊板子**——
// 上行的只有「聽到什麼類別」導出的事件(CLAUDE.md 約束 1)。這條線不能被打破:
// 不要為了「雲端判得比較準」把音訊 buffer 傳出去。
//
// 【行為】契約見 docs/requirements/hardware-integration.md §觸發方式:
//   ① distress(呼救/尖叫/呻吟/哭) → 觸發**與長按按鈕完全相同**的喚醒錄音流程,
//      長輩喊得出聲但按不到按鈕時也能求救(按鈕仍是不依賴任何模型的最終退路)。
//   ② impact(撞擊/摔落/玻璃破裂) → **絕不單獨上報**。誤報成本太高:關門、放鍋子、
//      掉遙控器都會觸發,而每一次誤報都是一張志工派遣單。撞擊只開一扇「佐證窗」,
//      窗內若再聽到 distress,才視為高信心跌倒直接送 fall_suspected(跳過問診,
//      因為此時已經有兩個獨立訊號)。未來 Himax 視覺跌倒推論接上來之後,
//      recentImpact() 就是它的第二個佐證來源。
//
// 設 0 可整段關掉(模型載不進去、或想單獨驗證按鈕流程時)。
#define ENABLE_SOUND_DETECTION 1

#if ENABLE_SOUND_DETECTION
NNAudioClassification audioNN;
// audio 一份輸入分流給兩個消費者:AAC(錄音上雲用)與 NPU 音訊分類(永遠在本地)。
// SIMO(1 進 2 出)是 StreamIO 內建的,不需要開第二個 Audio 實例——板上只有一顆
// PDM 麥克風,開兩個 Audio 會搶同一個週邊。
StreamIO audioStreamer1(1, 2);    // 1 Input Audio -> AAC + Audio Classification
#else
StreamIO audioStreamer1(1, 1);    // 1 Input Audio -> 1 Output AAC
#endif

#if ENABLE_SOUND_DETECTION
// distress:長輩發得出來的求救聲。刻意不收 8 Whoop(歡呼)與 20 Baby cry(嬰兒哭),
// 那兩類在獨居長輩家出現時幾乎都是電視聲。
const int distressClasses[] = {
    6,     // Shout
    7,     // Bellow
    9,     // Yell
    11,    // Screaming
    19,    // Crying, sobbing
    21,    // Whimper
    22,    // Wail, moan
    33,    // Groan
    39,    // Gasp
};

// impact:人或物體重摔的聲音。刻意不收 348 Door / 353 Knock / 358 Dishes——
// 那是日常家事的聲音,收進來會讓佐證窗幾乎整天開著,等於沒有佐證。
const int impactClasses[] = {
    352,    // Slam
    430,    // Boom
    435,    // Glass
    437,    // Shatter
    454,    // Thump, thud
    455,    // Thunk
    460,    // Bang
    463,    // Smash, crash
    464,    // Breaking
};

// score() 回傳的是 prob*100(0–100)。門檻是靠實機在場域調的,不是理論值:
// distress 訂得低一點(寧可多錄幾秒也不要漏掉求救——誤觸發的代價只是白錄一段),
// impact 訂得高一點(它會餵給跌倒判斷,誤報的代價是派出志工)。
const int distressScoreThreshold = 45;
const int impactScoreThreshold = 60;

// 撞擊之後多久內聽到求救聲,才算「同一起跌倒」。3 秒是人摔倒後喊出第一聲的
// 典型延遲;拉太長會把「剛剛關了門」跟「現在在講電話」也串成跌倒。
const unsigned long impactCorroborationMs = 3000;
// 兩次聲音喚醒的最短間隔:一次喚醒後面接的是錄音→ASR→/voice,幾十秒跑不完,
// 沒有冷卻的話電視劇裡一段爭吵就能連開十幾張單。
const unsigned long soundWakeCooldownMs = 60000;

// NN 執行緒 → 主迴圈的單向交接。callback 只寫這幾個變數就返回,
// 真正會阻塞的事(播提示音、開錄音、HTTPS 上報)一律留到主迴圈做——
// 理由和 MQTT callback 那邊一樣,在別人的執行緒裡阻塞會拖垮整條管線。
volatile bool distressPending = false;
volatile bool impactPending = false;
volatile int pendingDistressClass = -1;
volatile int pendingDistressScore = 0;
volatile int pendingImpactClass = -1;
volatile int pendingImpactScore = 0;
volatile unsigned long lastImpactAt = 0;         // 佐證窗的起點(0 = 還沒聽過撞擊)
volatile unsigned long soundGateUntil = 0;       // 在此時間點之前收到的偵測一律丟棄
volatile bool speakerActive = false;             // 自己的喇叭正在出聲 → 偵測結果不可信
unsigned long lastSoundWakeAt = 0;               // 只有主迴圈碰,不用 volatile

// 診斷模式(序列埠 snddebug 開關):把**每一次**推論的前幾名原樣印出來,不管有沒有
// 進白名單、也不管有沒有過門檻。
// 沒有這個模式就沒辦法調門檻——平常的 [SND] log 本身就被門檻擋著,
// 「喊了沒反應」到底是模型沒載進去、麥克風沒聲音、還是分數差一點,從 log 上分不出來。
#define SND_DEBUG_SLOTS 3
volatile bool soundDebug = false;
volatile int debugClass[SND_DEBUG_SLOTS];
volatile int debugScore[SND_DEBUG_SLOTS];
volatile int debugCount = 0;
volatile bool debugPending = false;
#endif    // ENABLE_SOUND_DETECTION

// 喚醒錄音的長度(秒)。按鈕觸發時長輩會自己再按一下結束,聲音喚醒沒有人按,
// 只能靠 mp4 自己到點收工——30 秒太久(求救的人要乾等半分鐘才聽到回應),
// 所以聲音喚醒改用較短的上限。
const int wakeRecordSeconds = 8;

// 初值設 HIGH(＝沒被按,因為是 INPUT_PULLUP)。若留預設 0(LOW),開機第一輪會
// 誤判成「剛剛放開按鈕」而印出一筆假的邊緣 log,診斷時會被誤導。
int buttonState = HIGH;                   // variable for reading the pushbutton status
bool longPressLogged = false;             // 長按門檻只印一次(每次按下重置),避免洗版
unsigned long buttonPressTime = 0;        // variable to store the time when button was pressed
bool buttonPressedLongEnough = false;     // flag to indicate if button is held for at least buttonPressInterval
int recordingstate = -1;
int previousRecordingState = -1;
bool stopArmed = false;                   // 錄音中且按鈕已放開,可接受「再按一下」提前結束
int prevButtonLevel = HIGH;               // 上一輪的按鈕電平,用於邊緣偵測
String serialLine = "";                   // 序列輸入緩衝(stop/sos/fall)

// MQTT 重連退避:1s→2s→…→30s(契約 §3②),用 millis 排程、不阻塞主迴圈
unsigned long mqttNextAttempt = 0;
unsigned long mqttBackoff = 1000;
const unsigned long mqttBackoffMax = 30000;

// 斷線診斷:記住「這次連線是什麼時候建立的」,斷掉時才能印出它撐了多久。
// 每秒重連一次跟每小時重連一次成因完全不同,但沒有這個數字兩者的 log 長得一樣。
bool mqttWasConnected = false;
unsigned long mqttConnectedAt = 0;

// 📌 2026-08-01 實測結論(別再往韌體這邊查了):
//    斷線 log 穩定印出 `state=-3 errno=128`,而且每次連線都恰好撐 ~500ms。
//      state=-3 = MQTT_CONNECTION_LOST → 底層 TLS 說「沒連線」
//      errno=128 = **ENOTCONN**(newlib 的值,見 toolchain 的 sys/errno.h)
//                  ——這是真的「對端把連線關了」,不是殘值、不是誤判。
//    也就是說:AWS IoT **接受了 CONNECT,然後半秒後主動切斷**。這正是它對
//    「授權失敗」的標準反應(不回 CONNACK 錯誤碼,直接斷 TCP,見本檔 deviceCertReady()
//    上方的說明)。最常見成因是憑證沒 attach 到 Thing → policy 裡的
//    ${iot:Connection.Thing.ThingName} 解不出值 → subscribe/publish 全被拒 → 斷線。
//    排查步驟寫在 firmware/README.md 的「MQTT 一直重連」那節。
//
// (曾經懷疑是 WiFiSSLClient::available() 讀到別人留下的全域 errno 而誤殺連線——
//  get_ssl_sock_errno() 確實只是 `return errno;` 且沒人清。但實測 errno 就是
//  ENOTCONN 本身,不是殘值,所以那條路是死的,對應的 workaround 已移除。)

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
void startRecording(int seconds, const String &why);
bool playPrompt(const char *file);
void speakerOutputBegin();
void speakerOutputEnd();
#if ENABLE_SOUND_DETECTION
void onAudioClassified(std::vector<AudioClassificationResult> results);
void pumpSoundDetection();
bool recentImpact();
String soundClassName(int classId);
#endif


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
    //    走 AWS 更要注意:根憑證雖然到 2038,但**裝置憑證是重簽的那一刻才生效**——
    //    這個值只要早於憑證的 notBefore,握手就會失敗,而 IoT Core 的反應是直接斷線、
    //    不給任何理由。**重簽 IoT 憑證之後一定要連這行一起更新**(否則新憑證反而連不上)。
    //    1785573600 = 2026-08-01 16:40 (台北)。重燒韌體時請更新成當天的 epoch:
    //    macOS/Linux 用 `date +%s` 取得。
    struct timeval tv;
    tv.tv_sec = 1785573600;
    tv.tv_usec = 0;
    settimeofday(&tv, NULL);
    Serial.println("System time forcibly set to 2026-08-01 to pass SSL verification!");

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

    // 開機先把「這台現在講的是哪一套雲」印出來。兩套環境資料庫不共通,
    // 事件沒出現在家屬 App 時第一個要確認的就是這行(而不是去查網路)。
#if BACKEND_AWS
    Serial.println("[ENV] AWS 平行環境 | " + String(voice_server) + voice_path
                   + " | MQTT " + String(mqtt_server) + ":" + String(mqtt_port) + " (X.509)");
#else
    Serial.println("[ENV] 正式環境(Render/Supabase) | " + String(voice_server) + voice_path
                   + " | MQTT " + String(mqtt_server) + ":" + String(mqtt_port));
#endif

    // 喚醒模式也要印:誤以為聲音喚醒是開著的、實際上模型沒載進去,
    // 現場只會看到「喊了沒反應」,而那跟麥克風壞掉長得一模一樣。
#if ENABLE_SOUND_DETECTION
    Serial.println(String("[SND] 喚醒模式：按鈕長按 + 本地 NPU 聲音偵測（YAMNet，音訊不上雲）")
                   + " | 求救聲門檻 " + String(distressScoreThreshold)
                   + " / 撞擊聲門檻 " + String(impactScoreThreshold)
                   + " | 撞擊佐證窗 " + String(impactCorroborationMs / 1000) + " 秒");
#else
    Serial.println("[SND] 喚醒模式：僅按鈕長按（聲音偵測已於編譯期關閉）");
#endif

    // MQTT 下行:設定好參數,實際連線交給 loop() 的 mqttPump()(帶退避重連),
    // 這樣即使開機時 broker 連不上也不會卡住開機流程。
    mqttNet.setRootCA((unsigned char*)mqtt_root_ca);
#if BACKEND_AWS
    // AWS IoT 是雙向 TLS:除了驗伺服器,還要拿裝置自己的憑證/私鑰去證明身分。
    mqttNet.setClientCertificate((unsigned char*)device_cert_pem, (unsigned char*)device_key_pem);
#endif
    mqtt.setServer(mqtt_server, mqtt_port);
    mqtt.setKeepAlive(mqtt_keepalive);
    mqtt.setCallback(onMqttMessage);
    // 預設 buffer 只有 512 bytes,而中文 speak 指令一個字就 3 bytes,
    // 進度播報那種長句加上 JSON 外殼很容易超過 → 封包會被整個丟掉。
    mqtt.setBufferSize(1024);
    // ⚠️ 這裡**刻意不呼叫 setPublishQos()**(2026-08-01 實測,別再加回來)。
    //
    // 原本寫的是 `mqtt.setPublishQos(1)`,想讓上下線狀態走 QoS 1,但那是錯的:
    // 這支 API 收的是**已經位移過的常數**(`#define MQTTQOS1 (1 << 1)` = 2),
    // 而實作是 `header |= pub_qos;`。MQTT 固定標頭的位元是
    //     [type:4][DUP:1][QoS:2][RETAIN:1]   ← bit 0 是 RETAIN
    // 所以傳 1 進去根本不是 QoS 1,而是**把 RETAIN 旗標打開**。
    // 於是 publish("jinsun/{serial}/status","online") 變成一則保留訊息,
    // 而 AWS IoT 對保留訊息要求**另一個權限 `iot:RetainPublish`**
    // (cloud/aws/iot/device-policy.json 只給了 iot:Publish)→ 被拒 → IoT Core
    // 直接關閉連線。症狀:CONNECT 成功、SUBSCRIBE 成功,約 500ms 後斷線,無限重連,
    // 而且完全查不出原因(不回錯誤碼,log 只有 state=-3 errno=128/ENOTCONN)。
    //
    // 那改成 setPublishQos(MQTTQOS1) 不就對了?**不行**,SDK 的 QoS≥1 分支還有一個
    // packet id 寫入 bug(PubSubClient.cpp):
    //     buffer[id_pos]   = (nextMsgId >> 8);
    //     buffer[id_pos++] = (nextMsgId & 0xFF);   ← 後置遞增,兩行寫到同一格
    // MSB 被 LSB 蓋掉,第二個位元組從沒被寫入(留著上一個封包的殘值)→ 送出去的
    // packet identifier 是壞的。所以這條路現在不能走。
    //
    // 用預設的 QoS 0 送 status 完全夠用:它只是個「我在線」的標記,離線那半由 LWT
    // 負責;真正需要可靠投遞的是**下行指令**,那條走的是 subscribe QoS 1 +
    // cleanSession=false,跟 setPublishQos 無關,完全不受影響。

    // Configure audio peripheral for audio data output
    audio.configAudio(configA);
    audio.begin();
    // Configure AAC audio encoder
    aac.configAudio(configA);
    aac.begin();

#if ENABLE_SOUND_DETECTION
    // NPU 音訊分類(YAMNet)。modelSelect() 一定要在 begin() 之前呼叫,而且
    // 第一個參數必須是 AUDIO_CLASSIFICATION——填錯的話 SDK 會停在 while(1) 迴圈裡
    // 每 5 秒印一次錯誤,開機看起來就是「卡住」。其餘四個 NA_MODEL 是沒用到的視覺任務。
    //
    // 模型從 flash 讀:Arduino IDE 的 Tools → NN Model Load From 要選 **Flash**
    // (預設值,對應 variants/common_nn_models/yamnet_fp16.nb);選 SD Card 的話
    // 記憶卡根目錄要自己放模型檔,而這張卡同時在存錄音,不值得多這個變數。
    audioNN.configAudio(configA);
    audioNN.setResultCallback(onAudioClassified);
    audioNN.modelSelect(AUDIO_CLASSIFICATION, NA_MODEL, NA_MODEL, NA_MODEL, DEFAULT_YAMNET);
    audioNN.begin();
#endif

    // Configure MP4 recording settings
    mp4.configAudio(configA, CODEC_AAC);
    mp4.setRecordingDuration(recordSeconds);
    mp4.setRecordingFileCount(1);
    mp4.setRecordingFileName(String(FILENAME));
    mp4.setRecordingDataType(STORAGE_AUDIO);    // Set MP4 to record audio only

    // Configure StreamIO object to stream data from audio channel to AAC encoder
    audioStreamer1.registerInput(audio);
#if ENABLE_SOUND_DETECTION
    // SIMO:同一份麥克風資料同時餵給 AAC(只有按下錄音時才會被寫成檔案)
    // 與 NPU 分類器(從開機到關機一直在跑)。
    audioStreamer1.registerOutput1(aac);
    audioStreamer1.registerOutput2(audioNN);
#else
    audioStreamer1.registerOutput(aac);
#endif
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
        if (!playPrompt("ready.wav")) {
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

#if ENABLE_SOUND_DETECTION
    // 本地聲音事件:NN 執行緒只放旗標,真正的動作(播提示音、開錄音、上報)在這裡做
    pumpSoundDetection();
#endif

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

    // check if the button has been held for at least buttonPressInterval
    if (buttonState == LOW && millis() - buttonPressTime >= buttonPressInterval) {
        // button has been held past the threshold
        buttonPressedLongEnough = true;
    } else {
        // button was released before the threshold
        buttonPressedLongEnough = false;
    }
    // if button has been held past the threshold
    if (buttonPressedLongEnough) {
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
            startRecording(recordSeconds, "按鈕長按");
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
#if ENABLE_SOUND_DETECTION
            // 聲音偵測的模擬觸發:直接偽造 NN callback 的產物,走完全相同的下游邏輯。
            // 沒有這兩個指令,要驗「撞擊 + 求救 = 跌倒」就得真的在辦公室摔東西再尖叫,
            // 而且門檻沒調好時根本分不出是判斷邏輯錯還是模型沒聽到。
            else if (serialLine == "bang") {
                pendingImpactClass = 454;    // Thump, thud
                pendingImpactScore = 99;
                lastImpactAt = millis();
                impactPending = true;
                Serial.println("[SND] (模擬) 撞擊聲");
            } else if (serialLine == "shout") {
                pendingDistressClass = 6;    // Shout
                pendingDistressScore = 99;
                distressPending = true;
                Serial.println("[SND] (模擬) 求救聲");
            } else if (serialLine == "sndreset") {
                lastSoundWakeAt = 0;
                lastImpactAt = 0;
                Serial.println("[SND] 已清除冷卻與佐證窗");
            } else if (serialLine == "snddebug") {
                soundDebug = !soundDebug;
                Serial.println(String("[SND] 診斷模式 ") + (soundDebug ? "開（每次推論都印前 3 名）" : "關"));
            }
#endif
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
        playPrompt("wait.wav");
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
        if (!mqttWasConnected) {
            mqttWasConnected = true;
            mqttConnectedAt = millis();
        }
        mqtt.loop();
        return;
    }

    // 剛剛還連著、現在斷了 → 把現場證據印出來。
    //   state=-3 (MQTT_CONNECTION_LOST)     底層 TLS 說「沒連線」
    //   state=-4 (MQTT_CONNECTION_TIMEOUT)  keep-alive ping 沒等到回應
    //   errno=128 (ENOTCONN)  對端把連線關了 → 往雲端那側查(IoT policy/憑證),不是韌體問題
    //   errno=11  (EAGAIN)    只是暫時沒資料,不該伴隨斷線;真出現代表另有成因
    if (mqttWasConnected) {
        mqttWasConnected = false;
        Serial.println("[MQTT] ✗ 斷線（這次連線撐了 " + String(millis() - mqttConnectedAt)
                       + " ms）state=" + String(mqtt.state()) + " errno=" + String(errno));
    }

    if (millis() < mqttNextAttempt) {
        return;    // 還沒到下次重試時間
    }

#if BACKEND_AWS
    // 沒憑證就別浪費一次 TLS 握手,直接講清楚原因(否則只會看到 rc=-2 一路重試)。
    if (!deviceCertReady()) {
        static bool warned = false;
        if (!warned) {
            Serial.println("[MQTT] ✗ 缺少 AWS IoT 裝置憑證:請把 device.cert.pem / device.key.pem "
                           "填進 secrets.h(見 secrets.h.example)。下行指令目前完全收不到。");
            warned = true;
        }
        mqttNextAttempt = millis() + mqttBackoffMax;
        return;
    }
#endif

    Serial.println("[MQTT] 連線中 " + String(mqtt_server) + ":" + String(mqtt_port) + " …");
    // LWT:broker 偵測到本機斷線時,自動幫我們發 offline
    // (後台「裝置離線」顯示免費取得,不用另外做心跳)
    //
    // ⚠️ 最後一個參數 cleanSession 必須是 false,而且一定要用這個 8 參數版本:
    //    7 參數的多載把 cleanSession 寫死成 true,broker 會在斷線時丟掉 session,
    //    QoS 1 的「斷線期間補投」就完全不會發生——急救逾時階梯的指令只要遇上
    //    一次短暫斷線就永遠消失。這台是急救裝置,漏一則升級指令的代價是人命。
    //    (AWS IoT 也支援 persistent session,但只保留 1 小時;mqttgo.io 則看 broker 設定。
    //     兩邊都夠涵蓋「ASR 阻塞那幾十秒」這種短暫斷線。)
    //
    // AWS IoT 用 X.509 認身分,username/password 一律忽略,所以這裡兩個 NULL 兩套通用。
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

// 音量夾在 0.0–1.0。這裡刻意不用 Arduino 的 min()/max() 巨集,也不用 std::min/max:
// NNAudioClassification.h 為了安全引入 <vector>,在 include 前會 #undef min / #undef max
// (那兩個巨集會把 STL 的 std::min 展開壞掉),所以巨集在本檔案裡已經不存在;
// 反過來若在它之前 #include <algorithm>,巨集又還在、換成 STL 那邊編不過。
// 自己寫三行就完全不必在意這個先後順序。
static float clampVolume(float v)
{
    if (v > 1.0f) {
        return 1.0f;
    }
    if (v < 0.0f) {
        return 0.0f;
    }
    return v;
}

// 裝置動作指令:volume_up / volume_down / stop_speak / repeat
void doDeviceCommand(const String &command)
{
    Serial.println("[CMD] " + command);
    if (command == "volume_up") {
        ampVolume = clampVolume(ampVolume + 0.2f);
        amp.setVolume(ampVolume);
    } else if (command == "volume_down") {
        ampVolume = clampVolume(ampVolume - 0.2f);
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

// ================= 喇叭輸出與錄音的共用進出口 =================

// 喇叭開始／結束出聲。存在的理由只有一個:麥克風聽得到自己的喇叭。
// 不擋的話,TTS 的人聲會被 YAMNet 判成 Speech/Shout、提示音會被判成 Beep/Bang,
// 於是「播報 → 誤判成求救 → 又開始錄音 → 又播報」無限循環。
// (ENABLE_SOUND_DETECTION 為 0 時整組是空操作,呼叫端不必包 #if。)
void speakerOutputBegin()
{
#if ENABLE_SOUND_DETECTION
    speakerActive = true;
#endif
}

void speakerOutputEnd()
{
#if ENABLE_SOUND_DETECTION
    speakerActive = false;
    // 喇叭剛停還不能馬上採信:室內殘響會拖一下,而且 YAMNet 是以約 1 秒的窗推論,
    // 跨在停播瞬間的那個窗裡有一半是我們自己的聲音 → 再多丟掉 1 秒。
    soundGateUntil = millis() + 1000;
#endif
}

// 播 SD 卡上的提示音(ready/init/wait),播放期間關掉聲音偵測。
bool playPrompt(const char *file)
{
    speakerOutputBegin();
    bool ok = amp.playWav(fs, file);
    speakerOutputEnd();
    return ok;
}

// 開始一次錄音。seconds 是自動收工的上限:
//   按鈕觸發 → recordSeconds(長輩講完會自己再按一下結束,上限只是保險)
//   聲音喚醒 → wakeRecordSeconds(沒有人會來按,只能等它到點,所以要短)
// 提示音先播完才 mp4.begin(),否則 init.wav 會被錄進要送去 ASR 的檔案裡。
void startRecording(int seconds, const String &why)
{
    Serial.println("[REC] ▶ 開始錄音（" + why + "，最長 " + String(seconds) + " 秒）");
    mp4.setRecordingDuration(seconds);
    playPrompt("init.wav");
    mp4.begin();
    stopArmed = false;    // 按鈕若還被按著,放開後才 arm「再按一下停止」
}

// ================= 本地聲音事件偵測(NPU / YAMNet) =================

#if ENABLE_SOUND_DETECTION

#define SND_LIST_LEN(a) (sizeof(a) / sizeof((a)[0]))
#define YAMNET_CLASS_COUNT 521

static bool inClassList(int classId, const int *list, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (list[i] == classId) {
            return true;
        }
    }
    return false;
}

// class id → 「名稱(編號)」,只給 log 用。門檻與白名單都是靠實機看這行調的,
// 所以寧可多印:每一筆進了白名單的偵測都會留下痕跡。
String soundClassName(int classId)
{
    if (classId < 0 || classId >= YAMNET_CLASS_COUNT) {
        return "class#" + String(classId);
    }
    return String(audioNames[classId].audioName) + "(" + String(classId) + ")";
}

// NPU 推論完成的 callback。**跑在 vipnn 的執行緒上,不是主迴圈**——
// 這裡只准做「比對 + 設旗標」,任何會阻塞的事(播音、開錄音、HTTPS)都會拖垮
// 整條音訊管線,連帶讓錄音掉幀。實際動作在 pumpSoundDetection()。
void onAudioClassified(std::vector<AudioClassificationResult> results)
{
    if (speakerActive || millis() < soundGateUntil) {
        return;    // 正在(或剛剛)播自己的聲音,這批結果不可信
    }

    // 診斷模式:原樣抄下前幾名(主迴圈負責印,這裡一樣不做 I/O)
    if (soundDebug && !debugPending) {
        int n = (int)results.size();
        if (n > SND_DEBUG_SLOTS) {
            n = SND_DEBUG_SLOTS;
        }
        for (int i = 0; i < n; i++) {
            debugClass[i] = results[i].classID();
            debugScore[i] = results[i].score();
        }
        debugCount = n;
        debugPending = true;
    }

    for (size_t i = 0; i < results.size(); i++) {
        int classId = results[i].classID();
        int score = results[i].score();    // prob * 100

        if (score >= distressScoreThreshold
            && inClassList(classId, distressClasses, SND_LIST_LEN(distressClasses))) {
            pendingDistressClass = classId;
            pendingDistressScore = score;
            distressPending = true;
        } else if (score >= impactScoreThreshold
                   && inClassList(classId, impactClasses, SND_LIST_LEN(impactClasses))) {
            pendingImpactClass = classId;
            pendingImpactScore = score;
            // 佐證窗從「聲音發生的當下」起算,不是從主迴圈注意到的當下——
            // 主迴圈可能正卡在 ASR 上傳裡好幾十秒。
            lastImpactAt = millis();
            impactPending = true;
        }
    }
}

// 撞擊佐證窗還開著嗎?未來 Himax 視覺跌倒推論接上來時,這就是它的第二個訊號源:
// 「畫面看起來像跌倒」＋「剛剛有重物落地聲」比任一單獨訊號可信得多。
bool recentImpact()
{
    return lastImpactAt != 0 && (millis() - lastImpactAt) <= impactCorroborationMs;
}

// 主迴圈端:消化 callback 留下的旗標。
void pumpSoundDetection()
{
    if (debugPending) {
        String line = "[SND] (raw)";
        // res_cnt 為 0 是正常的:YAMNet 只回報超過它自己內部信心門檻的類別,
        // 安靜的房間常常一個都不回。仍然印一行,因為「有在跑」本身就是要看的資訊。
        if (debugCount == 0) {
            line += "  —（無結果，多半是安靜）";
        }
        for (int i = 0; i < debugCount; i++) {
            line += "  " + soundClassName(debugClass[i]) + "=" + String(debugScore[i]);
        }
        Serial.println(line);
        debugPending = false;    // 印完才放行下一批,避免洗版蓋掉還沒印的
    }

    if (impactPending) {
        impactPending = false;
        Serial.println("[SND] 💥 撞擊聲 " + soundClassName(pendingImpactClass)
                       + " score=" + String(pendingImpactScore) + " → 開啟 "
                       + String(impactCorroborationMs / 1000) + " 秒佐證窗（**不單獨上報**）");
    }

    if (!distressPending) {
        return;
    }
    distressPending = false;
    Serial.println("[SND] 🆘 求救聲 " + soundClassName(pendingDistressClass)
                   + " score=" + String(pendingDistressScore));

    if (recordingstate == 1) {
        Serial.println("[SND] 已在錄音中 → 略過（這段聲音本來就會被錄進去送 ASR）");
        return;
    }
    if (lastSoundWakeAt != 0 && millis() - lastSoundWakeAt < soundWakeCooldownMs) {
        Serial.println("[SND] 冷卻中（距上次聲音喚醒 "
                       + String((millis() - lastSoundWakeAt) / 1000) + " 秒）→ 略過");
        return;
    }
    lastSoundWakeAt = millis();

    if (recentImpact()) {
        // 撞擊 + 求救 = 兩個彼此獨立的訊號指向同一件事,信心足夠直接送跌倒事件,
        // 由雲端接手 20 秒升級階梯(CLAUDE.md 約束 3)。這裡刻意不先錄音問話:
        // 摔在地上的人可能已經講不出完整句子,多花 8 秒錄音只是延後派工。
        Serial.println("[SND] ⚠️ 佐證窗內先有撞擊聲 → 判定疑似跌倒,上報 fall_suspected");
        lastImpactAt = 0;    // 用掉就關窗,同一次撞擊不重複佐證
        sendEvent("fall_suspected");
        return;
    }

    // 只有求救聲(沒有撞擊):可能是跌倒,也可能是「我不舒服」「我想買東西」。
    // 走與長按按鈕完全相同的喚醒錄音流程,讓長輩把話講完,交給雲端分類。
    startRecording(wakeRecordSeconds, "聲音喚醒");
}

#endif    // ENABLE_SOUND_DETECTION

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
      // x-bf-vk 是兩顆 ASR 服務的最大公因數,所以切換 host 時這行不用動:
      //   AWS(jinsun-asr-openai):x-bf-vk 與 Authorization: Bearer 都吃,錯金鑰乾脆回 401。
      //   XCC Gateway:**只**認 x-bf-vk。送錯標頭時它不回 401,而是整個掛住不回應
      //     (Cloudflare 前端最後回 524 origin timeout),從板子這端看起來就像「ASR 沒反應」。
      //   參考 cloud/prototype/src/llm/bedrock.js —— 與 XCC 的 ASR 同一把金鑰、同一個標頭。
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
    speakerOutputBegin();
    if (amp.playWavStream(client)) {
        Serial.println("[Play] done.");
    } else {
        Serial.print("[Play] failed: ");
        Serial.println(amp.lastError());
    }
    speakerOutputEnd();
    client.stop();
}

// 讀 Polly 回應的標頭:回傳 HTTP 狀態碼(-1 = 標頭沒讀完),並把是否為
// chunked 寫回 outChunked。
//
// 為什麼要特地判 chunked:接下來要把同一個 client 直接餵給 amp.playWavStream(),
// 而它不懂 chunked 的十六進位長度框架行,會把框架當成音訊取樣播出去 → 雜音。
// (ATEN 那條路不會踩到,因為它是先收完 JSON、再開第二條連線抓音檔。)
static int readPollyHeaders(WiFiSSLClient &c, bool &outChunked, uint32_t timeoutMs)
{
    String line = "";
    int status = 0;
    bool first = true;
    outChunked = false;
    uint32_t t0 = millis();

    while (millis() - t0 < timeoutMs) {
        while (c.available()) {
            char ch = c.read();
            if (ch == '\n') {
                if (line.length() == 0) {
                    return status;    // 空行 = 標頭結束
                }
                if (first) {
                    int sp = line.indexOf(' ');    // "HTTP/1.1 200 OK"
                    if (sp > 0) {
                        status = line.substring(sp + 1, sp + 4).toInt();
                    }
                    first = false;
                } else {
                    String low = line;
                    low.toLowerCase();
                    if (low.startsWith("transfer-encoding:") && low.indexOf("chunked") > 0) {
                        outChunked = true;
                    }
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
    return -1;
}

// 國語:POST 文字給 jinsun-tts(Polly),回應本身就是 WAV → 收完標頭直接串流播放。
// 回傳 true 表示確實出過聲,false 讓呼叫端決定要不要退回 ATEN。
bool speakViaPolly(const String &text)
{
    WiFiSSLClient client;

    Serial.println("[TTS] 國語 → Polly https://" + String(tts_mandarin_server) + tts_mandarin_path);
    if (!client.connect(tts_mandarin_server, 443)) {
        Serial.println("[TTS] Polly 連線失敗");
        return false;
    }

    JsonDocument doc;
    doc["text"] = text;
    doc["lang"] = "mandarin";
    String body;
    serializeJson(doc, body);

    client.println("POST " + tts_mandarin_path + " HTTP/1.1");
    client.println("Host: " + String(tts_mandarin_server));
    client.println("Content-Type: application/json");
    client.println("Accept: audio/wav");
    client.println("Content-Length: " + String(body.length()));
    client.println("Connection: close");
    client.println();
    client.print(body);
    client.flush();

    bool chunked = false;
    int code = readPollyHeaders(client, chunked, 20000);
    if (code != 200) {
        Serial.println("[TTS] Polly HTTP " + String(code));
        client.stop();
        return false;
    }
    if (chunked) {
        // 2026-08-01 實測正式端點:回 `content-length: 142444`、沒有 transfer-encoding,
        // 所以正常情況走不到這裡。真踩到就得改成「先整段收進記憶體、剝掉框架再播」。
        Serial.println("[TTS] ⚠️ Polly 回 chunked,playWavStream 吃不下");
        client.stop();
        return false;
    }

    Serial.println("[Play] Polly streaming...");
    speakerOutputBegin();
    bool ok = amp.playWavStream(client);
    speakerOutputEnd();
    client.stop();

    if (ok) {
        Serial.println("[Play] done.");
    } else {
        Serial.print("[Play] Polly 播放失敗: ");
        Serial.println(amp.lastError());
    }
    return ok;
}

// 播一句話。lang 是「選語音」的旗標(mandarin/taigi),text 一律是正常中文——
// 雲端不做台語翻譯,兩種語言拿到的是同一份中文,差別只在送去哪顆 TTS(契約 §3②):
//
//   lang=taigi    → ATEN(台語模型,端點不吃 voice 參數,只會講台語)
//   lang=mandarin → Polly Zhiyu(jinsun-tts Lambda)
//
// Polly 掛掉時退回 ATEN 用台語念:這條路上跑的是派遣進度與安撫語句,
// 長輩聽到「語言不對的一句話」遠好過聽到一片安靜。
void speak(const String &text, const String &lang)
{
    lastSpokenText = text;    // 供 repeat 指令重播
    lastSpokenLang = lang;

    if (lang != "taigi") {
        if (speakViaPolly(text)) {
            return;
        }
        Serial.println("[TTS] ⚠️ 國語 TTS 不可用 → 退回 ATEN(這句會變成台語)");
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
    speakerOutputBegin();
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
    speakerOutputEnd();
    amp.endPCM();
}
