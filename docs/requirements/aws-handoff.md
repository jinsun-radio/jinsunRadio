# AWS 平行環境 · 交接文件

> 撰寫於 2026-08-01，同日更新（補上三端 App 那半邊）。
> 接手前請先讀完「§1 立刻要處理」——有三件事有時效性。
>
> 設計理由與完整實測數據見 [`aws-architecture.md`](aws-architecture.md)；
> 目錄結構與部署指令見 [`../../cloud/aws/README.md`](../../cloud/aws/README.md)。

## 0. 一句話現況

**伺服器端的平行環境已完整可跑**（語音 → 意圖分類 → 20 秒升級 → 派遣 → 收音機播報 → 進度回報），
資料庫是自己的 Aurora、**與正式環境 Supabase 完全斷開**。

**三端 App 那半邊也已完成並部署**（Cognito 認證、`jinsun-data` 資料 API、`aws_backend.dart`、
建置切換旗標、S3 + CloudFront 三端站台），且已在真 AWS 上跑過完整黃金鏈路：

```
疑似跌倒 → 家屬端 3 秒內看到「確認中」→ 20 秒升級（實測 T0+24s，含 2s 輪詢誤差）
→ 開派遣單並就近派給志工 → 志工接單（重複接單回 409）→ 家屬↔志工聊天
→ 到場 → presigned S3 上傳結案照片 → 結案 → 時間銀行 +21 分 → 長輩燈號回綠、事件 closed
```

解除路徑（長輩回「我沒事」）亦已驗：Step Functions execution 轉 `ABORTED`，不會誤升級。

程式碼在本 repo 分支 `feat/aws-parallel-environment`，**尚未 push 到遠端**。

### 四端網址（CloudFront，HTTPS）

| 端 | 網址 | S3 bucket | CloudFront ID |
|---|---|---|---|
| 家屬 | https://d22h4jxlikk4jo.cloudfront.net | `jinsun-family-web` | `E2A1BW0EZXSZWA` |
| 志工 | https://d3inbvxprhol1.cloudfront.net | `jinsun-volunteer-web` | `E1SO2GTWWKONH8` |
| 社工 | https://d2o5h7ul68enq.cloudfront.net | `jinsun-admin-web` | `E4QI5MMFZRZ5A` |
| 長輩 | https://d13n8orqgy8yez.cloudfront.net | `jinsun-elder-web` | `E1QH4VWLX0WN30` |

> **一定要用 CloudFront 網址，不要用 S3 網站端點。** S3 靜態網站只有 HTTP，
> 瀏覽器在非 HTTPS 下不給定位權限 —— 志工端的 GPS 上報與家屬地圖的志工位置會整條失效。
> **長輩端更嚴重**：麥克風同樣要 HTTPS，走 S3 端點的話「按住說話」大按鈕整個是啞的。

Demo 帳號（密碼一律 `demo1234`，已建在 Cognito）：
`0912-345-678`（家屬 陳怡君，已綁 elder-1）、`0921-000-111`（志工 阿明）、`0933-222-333`（社工 王淑芬）。

長輩端是**裝置帳號**，不是人的帳號 —— 長輩端沒有 UI（架構約束 2），不可能叫長輩登入，
所以帳密在 build 時用 `--dart-define` 注入、開網頁就自動登入：

| 項目 | 值 |
|---|---|
| 帳號 | `device-js-0001@jinsun.local`（Cognito group `family`，sub `d8213380-20c1-70aa-7f9f-fd0e4b8ae842`） |
| 密碼 | `Radio!2026jinsun` |
| 綁定 | `family_bindings` → `elder-1`（林阿春／`JS-0001`） |

因為只綁 elder-1，這台收音機在 `/data/snapshot` 只看得到林阿春一位 —— 這是刻意的：
一台收音機就是一位長輩的，看得到別人反而是授權破口。要再開一台就照同一組指令
另建 `device-js-000N@jinsun.local` 並綁對應 elder，重 build 一份帶不同 `ELDER_DEVICE_USER` 的站台。

---

## 1. 立刻要處理（有時效性）

### 1.1 韌體憑證即將遺失

IoT 裝置憑證（含私鑰）產生在前一個 session 的暫存目錄，**該目錄已經或即將被清除**。
私鑰無法從 AWS 取回——只能重簽。重簽只要三個指令，且比搬移私鑰更安全：

```bash
THING=JS-0001   # 或 JS-REAL-0001
aws iot create-keys-and-certificate --set-as-active \
  --certificate-pem-outfile device.cert.pem \
  --private-key-outfile device.key.pem \
  --public-key-outfile device.public.pem \
  --query certificateArn --output text > cert.arn
aws iot attach-policy --policy-name JinsunDevicePolicy --target "$(cat cert.arn)"
aws iot attach-thing-principal --thing-name "$THING" --principal "$(cat cert.arn)"
curl -fsSL https://www.amazontrust.com/repository/AmazonRootCA1.pem -o AmazonRootCA1.pem
```

舊憑證（下列兩張）已成孤兒，可停用刪除：

```
a4358418f284ed719c591f2eee075a654c2a9f824e1c0994d8b1a8772fc465e4   （JS-0001）
9360515f2ebf4876e8f6bf5d33ee6779574ecabdf02216d31a986c1ba2e15bf2   （JS-REAL-0001）
```

**憑證檔絕對不要進 git。**

### 1.2 AWS 憑證是臨時的

先前使用的是 workshop `WSParticipantRole` 的臨時憑證（`ASIA…` + session token），**數小時後過期**。
過期後所有 `aws` 指令會回 `ExpiredToken`，需要重新取得一組。

### 1.3 ⚠️ 韌體檔內有真實密鑰 —— 結構已處理，key 仍要撤換

`firmware/HUB-8735-Ultra-ASR-TTS.ino` 在**另一個 repo（`jinsun-radio`）的工作目錄**裡被填入了
真實的 WiFi 密碼與 `sk-bf-` 開頭的 XCC Gateway API key，**尚未提交**（我刻意排除了它）。

**已做**：.ino 改成從 `firmware/secrets.h`（`.gitignore` 已擋，範本 `secrets.h.example`）帶入
WiFi／ASR key／AWS IoT 裝置憑證與私鑰，沒有該檔就用佔位符；`*.cert.pem`／`*.key.pem` 也一併加進
`.gitignore`。進版控的 .ino 本身不再含任何實際值。

**仍要做**：那把 API key 曾出現在開發對話紀錄中，**去 XCC Gateway 撤換**。

---

### 1.4 兩套 AWS 方案已收斂（僅供了解，不用再決定）

`main` 上另有一套容器 + S3/CloudFront 的部署（commit `2eac758` 起）。已按 §6.3 的理由收斂：
**伺服器端用 `cloud/aws/`**（Lambda；容器那條原本走 App Runner，在此帳號被 SCP 擋死），
**前端用 `deploy/aws/deploy-web.sh`**，並已改成可用 `BACKEND=aws` 指向 Cognito/API Gateway。

`deploy/aws/` 的容器部署已由另一位開發者改寫成 **ECS Fargate + ALB**（`deploy-server.sh`；
`apprunner.yaml` **檔名沒改、內容已經是 ECS**，別被檔名騙了）。它保留為參考，
檔頭警告已同步更新：**⚠️ 它連的是正式 Supabase**，跑起來會與 Render 那台搶播報。
**ECS 這條路尚未實跑過**（不確定此帳號 SCP 放不放行 `ecs:*`／`elasticloadbalancing:*`）。

---

## 2. 環境識別碼

```bash
export AWS_DEFAULT_REGION=us-west-2
export AWS_REGION=us-west-2
# 帳號 012804034919（workshop / WSParticipantRole）

export API_BASE=https://yr0ep335el.execute-api.us-west-2.amazonaws.com
export API_ID=yr0ep335el
export IOT_ENDPOINT=a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com

export AURORA_CLUSTER_ARN=arn:aws:rds:us-west-2:012804034919:cluster:jinsun-aurora
export AURORA_SECRET_ARN='arn:aws:secretsmanager:us-west-2:012804034919:secret:rds!cluster-b4211a31-4ff8-46d1-a287-c6da313bdd5c-7JZLFS'
export AURORA_DB_NAME=jinsun
# 直連 endpoint（一般用不到，Lambda 走 Data API）
# jinsun-aurora.cluster-c18mk2i0cjuq.us-west-2.rds.amazonaws.com

export LADDER_ARN=arn:aws:states:us-west-2:012804034919:stateMachine:JinsunEmergencyLadder
export ENROUTE_ARN=arn:aws:states:us-west-2:012804034919:stateMachine:JinsunEnrouteBroadcast

# 四端 App（Cognito + 資料 API + 靜態站台）
export COGNITO_POOL_ID=us-west-2_f34wIqjEd
export COGNITO_CLIENT_ID=42rpj4dsabhqcq6gi0jrgc2l37
export PROOFS_BUCKET=jinsun-proofs
export CF_DIST_FAMILY=E2A1BW0EZXSZWA
export CF_DIST_VOLUNTEER=E1SO2GTWWKONH8
export CF_DIST_ADMIN=E4QI5MMFZRZ5A
export CF_DIST_ELDER=E1QH4VWLX0WN30

# 長輩端收音機的裝置帳號（deploy-web.sh 在 BACKEND=aws 時必填）
export ELDER_DEVICE_USER=device-js-0001@jinsun.local
export ELDER_DEVICE_PASS='Radio!2026jinsun'
```

| 資源 | 名稱 |
|---|---|
| Lambda | `jinsun-voice`、`jinsun-speak`、`jinsun-progress`、`jinsun-data`＊、`jinsun-auth`＊、`jinsun-tts`、`jinsun-asr-openai`＊ |
| API Gateway | `jinsun-voice-api`（`$default`、`POST /hooks/progress`、`/data/*`＊、`POST /tts`、`/v1/audio/transcriptions`＊、`GET /v1/models`＊） |
| TTS（國語） | `jinsun-tts` + `POST /tts`（Amazon Polly Zhiyu neural）。**兩套環境都打它**——無狀態服務、無資料落地，同 ASR gateway 的處理。台語不在這裡（走外部 ATEN，見 `hardware-integration.md` §1） |
| ASR | 兩條並存：①`POST /asr`（走 `$default` → `jinsun-voice`）代理 XCC Gateway 的 Breeze ASR，PAT 在 `jinsun-voice` 的 `XCC_GATEWAY_PAT`；②`POST /v1/audio/transcriptions`＊（`jinsun-asr-openai` → SageMaker `breeze-asr-26`），**自帶 endpoint、不依賴外部 gateway**，見下列 SageMaker |
| SageMaker＊ | endpoint `breeze-asr-26`（`ml.g4dn.xlarge`，faster-whisper Breeze-ASR-26 fp16）。**GPU 持續計費**，不用時 `cloud/asr-sagemaker/scripts/teardown.sh`。OpenAI 相容門面由 `jinsun-asr-openai` 提供（SigV4 不能直接 curl） |
| Cognito＊ | User Pool `jinsun-users`、Client `jinsun-apps`、Group `family`/`volunteer`/`worker` |
| S3＊ | `jinsun-proofs`（結案照片）、`jinsun-{family,volunteer,admin}-web`（三端靜態站） |
| Step Functions | `JinsunEmergencyLadder`、`JinsunEnrouteBroadcast` |
| DynamoDB | `jinsun_emergency_sessions`、`jinsun_progress_announced`、`jinsun_downlink`＊（皆有 TTL） |
| IoT | Thing `JS-0001`／`JS-REAL-0001`，Policy `JinsunDevicePolicy` |
| Aurora | `jinsun-aurora`（Serverless v2、PG 16.14、0.5–4 ACU、Data API 已開） |
| IAM Role | `JinsunVoiceLambdaRole`、`JinsunProgressLambdaRole`、`JinsunSpeakLambdaRole`、`JinsunEmergencyLadderRole`、`JinsunDataLambdaRole`＊、`JinsunAuthLambdaRole`＊、`JinsunAsrOpenaiLambdaRole`＊（只允許 `sagemaker:InvokeEndpoint` 於 `breeze-asr-26` 單一資源） |
| CloudFront＊ | 三端各一個 distribution（ID 見 §0） |

> 標＊者是本次新增並已部署的資源。

### 環境健康檢查

```bash
bash cloud/aws/scripts/smoke-test.sh          # 唯讀，不需 AWS 憑證，隨時可跑
bash cloud/aws/scripts/smoke-test.sh --voice  # 追加真實升級鏈路（會開派遣單、留測試資料）
```

七項檢查：`/health`、無 token → 401、爛 token → 401、**CORS preflight → 2xx**、
三個 demo 帳號的角色與可見長輩數（family 1／volunteer 0／worker 22）。
它打的路徑跟三端 App 完全一樣（Cognito `USER_PASSWORD_AUTH` → Bearer token → `/data/*`），
所以能測到 curl 手打測不到的東西——特別是 preflight。

單看健康狀態：

```bash
curl -s $API_BASE/health
# 預期：{"ok":true,"llm":"bedrock","dispatch":"live","ladder":true}
```

`dispatch` 若不是 `live`，多半是 Aurora 睡著或 IAM 過期，看 CloudWatch `/aws/lambda/jinsun-voice`。

---

## 3. 完成度

### 3.1 伺服器端（已在真 AWS 上實測通過）

| 元件 | 對應原環境 | 備註 |
|---|---|---|
| `POST /voice` + 六個 agent | Render voice server | 契約 7 項驗收全過 |
| 20 秒逾時階梯 | `emergency.js` 的 `setTimeout` | 實測升級落在 T0+20.11s |
| 解除（「我沒事」） | `clearTimeout` | `StopExecution` → `ABORTED`，25 秒零指令 |
| 進度播報（出發／GPS 預告／開門） | `progress.js` Realtime worker | ⚠️ 當初「四條路徑全驗」是**在還連著 Supabase 時、用 curl 手打 `/hooks/progress` 驗的**。切到 Aurora 後這支 Lambda 一度載入即死、且沒有任何自動觸發來源（見 §5 兩列新增的坑）。2026-08-01 已修：改走 `db.js`＋由 `jinsun-data` 在寫入點非同步 invoke。**尚未由真實志工走完一次接單→抵達**，demo 前建議實跑 |
| 路上每 10 分鐘 | `setInterval` | Step Functions 迴圈 |
| 下行 MQTT | mqttgo.io（無認證） | IoT Core + X.509，投遞 14ms |
| LLM | XCC Gateway | Bedrock，對話延遲 2.7–3.2s |
| 資料庫 | Supabase | Aurora，**已驗證與 Supabase 完全斷開** |
| `travel.js` | 直接用 `supabase-js` | 已改走 `db.js`；Aurora 無 Realtime → 改輪詢已接單的派遣單 |

### 3.2 三端 App 那半邊（已部署並實測）

| 元件 | 資源／檔案 | 實測結果 |
|---|---|---|
| Cognito | User Pool `us-west-2_f34wIqjEd`、Client `42rpj4dsabhqcq6gi0jrgc2l37` | 三個 group 建立；自助註冊 → 自動確認 → 自動加 group → 寫 `profiles` 全通 |
| 越權防線 | `lambda/auth/index.mjs` | **實測：自助註冊申請 `worker` 被降級成 `family`** |
| 資料 API | Lambda `jinsun-data` + 4 條路由 + JWT authorizer | `/version`、`/snapshot`、`/mutate`、`/timebank` 全通；無 token 回 401 |
| 讀取授權 | `lambda/data/authz.mjs` | 社工看 22 位長輩；家屬綁定前看 0 位、綁 elder-1 後看 1 位；志工只看得到有單的長輩 |
| 寫入授權 | 同上 | **實測擋下**：家屬改注記（社工限定）、志工改別人位置、家屬碰未綁定長輩、未知 op |
| 結案照片 | S3 `jinsun-proofs` + presigned PUT | 上傳 200、家屬讀取 200、寫回 `proof_photo_url` |
| 時間銀行 | 伺服器端算點 | 緊急單 ETA 8 分 → `(8+6)×1.5 = 21` 分，與 Dart `models.dart` 一致 |
| 三端站台 | S3 + CloudFront ×3 | HTTPS 200；已確認產出的 `main.dart.js` 內含 Cognito Client ID 與 API base（不是靜默退回 Supabase） |
| `AwsBackend` | `apps/packages/core/lib/src/aws_backend.dart` | 6 項行為測試（假 http client）＋三端實際 build web 成功 |

> ⚠️ 仍未由「真人在瀏覽器上點過」——上述驗證都是用 curl 直接打 API 與檢查產出檔。
> UI 層（登入畫面、綁定流程、地圖）建議 demo 前自己走一遍。

**這個缺口已經咬過一次（2026-08-01 補記）**：三端在瀏覽器打 `/data/*` 全部失敗，
`OPTIONS /data/version` 回 404。curl 不發 preflight，所以上表全綠、網頁卻連不上。
根因與修法見 §5 的「CORS preflight 被 `$default` 吃掉」。已修並加進 `smoke-test.sh` 第 3 項。

### 3.3 仍未做

| 項目 | 說明 |
|---|---|
| `send-push` Edge Function | → Lambda + SNS Mobile Push。`device_tokens` 已經會寫進 Aurora，發送端還沒接 |
| `whisper` Edge Function | → Lambda + Transcribe。`AwsBackend.transcribeAudio` 目前明確丟 501，不會靜默回空字串 |
| 台語 ASR | → SageMaker endpoint（Transcribe 無台語；`ml.g4dn.xlarge` 配額為 2）。**TTS 不在此列**——台語 TTS 續用 ATEN（本來就是台語模型），國語 TTS 已由 `jinsun-tts`（Polly Zhiyu）接上，見 `deploy-tts.sh` |
| AppSync 真訂閱 | 目前用變更指紋輪詢（3 秒）。**這是刻意的取捨，理由見 `aws-architecture.md` §4.4**；要升級時 `AwsBackend` 對外介面不必動 |

---

## 4. 重建／重跑的順序

環境已經建好（識別碼見 §0、§2）。憑證過期換一組之後要**重跑或重建**時照這個順序：

```bash
export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2
export AURORA_CLUSTER_ARN=... AURORA_SECRET_ARN=...

# ① schema（idempotent，重跑不掉資料；--dry-run 可先看那 72 句）
CLUSTER_ARN=$AURORA_CLUSTER_ARN SECRET_ARN=$AURORA_SECRET_ARN \
  node cloud/aws/db/apply-schema.mjs

# ② Cognito 觸發器 → User Pool
#    順序不能反：setup-cognito 要 jinsun-auth 已經存在才掛得上，
#    否則它只會印一行提示然後跳過，而且不會有錯誤碼。
bash cloud/aws/scripts/deploy-auth.sh
bash cloud/aws/scripts/setup-cognito.sh            # 印出 POOL_ID / CLIENT_ID

# ③ 資料 API
export COGNITO_POOL_ID=... COGNITO_CLIENT_ID=...
bash cloud/aws/scripts/deploy-data.sh

# ④ 三端 Web（CloudFront 首次建立後約 5–10 分鐘才 Deployed）
export BACKEND=aws AWS_API_BASE=$API_BASE
bash deploy/aws/deploy-web.sh
bash deploy/aws/setup-cloudfront.sh

# ⑤ 改過 cloud/prototype/src 就要重打包語音那三支 —— 它們不會自己跟著 repo 走
bash cloud/aws/scripts/build.sh
for f in voice speak progress; do
  aws lambda update-function-code --function-name jinsun-$f \
    --zip-file fileb://cloud/aws/.build/$f.zip
done
```

### 端到端驗收（已跑過，可重跑）

```bash
API=https://yr0ep335el.execute-api.us-west-2.amazonaws.com
curl -s -X POST "$API/voice" -H 'content-type: application/json' \
  -d '{"device_serial":"JS-0001","event":"fall_suspected"}'
# 20 秒後：家屬端應看到 escalated 事件 + pending 派遣單，長輩燈號 emergency
curl -s -H "authorization: Bearer $ID_TOKEN" "$API/data/snapshot"
```

### 這次真的踩到、之後還會踩到的三個地方

1. **`dispatch.js` 對資料庫錯誤只 log 不中斷。** schema 一出問題，外表症狀是
   「派遣單開出來了，但 `elder_id` 是 NULL、而且沒有對應的 `radio_events`」——
   不是一個顯眼的錯誤，志工 App 只會顯示「長輩（0 歲）」。
   看到這個症狀，第一件事就是去 CloudWatch 撈 `/aws/lambda/jinsun-voice`。§6.7 就是這樣抓到的。
2. **Lambda 的 bundle 不會跟著 repo 走。** 部署在 AWS 上的 `jinsun-voice` 曾經比 repo 舊好幾個
   修正，症狀是「程式碼裡明明有修，線上就是沒效果」。改完 `cloud/prototype/src` 一定要跑上面的 ⑤。
3. **`/data/snapshot` 的 SQL 是一整句。** 它用到 `elders` 全部欄位，schema 一漂移整句就 500。
   先單獨打 `GET /data/version`，它比較短、錯誤訊息好讀。

---

## 5. 已知的坑（別重踩）

| 坑 | 說明 |
|---|---|
| **Step Functions 不能直接發 MQTT** | AWS SDK 整合清單沒有 IoT Data Plane，`aws-sdk:iotdata:publish` 會 `SCHEMA_VALIDATION_FAILED`。一律經 `jinsun-speak` Lambda。 |
| **相對 `Wait` 會累積開銷** | 用 `Seconds:8`/`Seconds:12` 實測升級落在 21.55s、超窗。已改絕對時間戳（`TimestampPath`）。 |
| **`JSON.stringify` 丟掉 `undefined`** | 裝置依契約**不送 `elder_id`**，該欄位為 `undefined` → key 消失 → ASL 的 `$.elderId` 找不到路徑 → 整條 execution `States.Runtime` 失敗。**每次真實升級都會炸**。所有進狀態機的欄位一律 `?? null`。 |
| **Data API 參數一律是 `text`** | Postgres 不會隱式轉 enum（`42804`）。`db.js` 會查 `information_schema` 快取欄位型別並自動加 `::型別`。 |
| **`text[]` 不是 JSON** | Postgres 陣列字面值是 `{"a","b"}`，不是 `["a","b"]`。 |
| **IoT 授權失敗＝切斷連線** | 不是回 SUBACK 128。**topic 打錯一個字，症狀會長得像「連線不穩」**。除錯先查 topic 字串與 client id↔憑證是否匹配。 |
| **Bedrock 只授權兩個模型** | 此帳號僅 `us.anthropic.claude-sonnet-4-6` 與 `us.anthropic.claude-haiku-4-5-20251001-v1:0`。Opus 5／Sonnet 5／Opus 4.8 皆 `AccessDenied`（換 API key、換區域都試過，是帳號層級 entitlement）。**裸 model id 一律 `ResourceNotFound`，必須帶 `us.` 前綴**。 |
| **`app_settings.llm_provider` 會覆蓋環境變數** | 且它是每套環境各自一份。Lambda 設 `LLM_PROVIDER_FORCE=bedrock` 跳過後台查詢——否則後台選了這台機器做不到的供應商時，只會**靜默退回 mock**，長輩收到罐頭回覆且不易察覺。 |
| **切換 LLM 供應商後要重跑語氣驗收** | 換 Bedrock 才浮現兩個問題：模型用「阿公／阿嬤」稱呼長輩（專案已定案移除稱謂）、回覆結尾加 emoji（**輸出直接送進 TTS，emoji 念不出來**）。兩者已在 `conversation.js`／`needs.js` 的 system prompt 修正。 |
| **Aurora 最小容量不要設 0** | Serverless v2 從零擴容約 15 秒，會直接吃掉 20 秒黃金窗。目前 min 0.5 ACU（約 $43/月）。 |
| **Data API 對「宣告了卻沒用到的參數」會報錯** | 而 `/data` 的 SQL 述詞是依角色動態組出來的（社工那份完全不含 `:uid`）。`index.mjs` 的 `usedParams()` 會掃 SQL 只送真的出現過的參數；negative lookbehind 是為了跳過 `::uuid` 這種轉型。 |
| **子查詢的 `order by` 不保證 `json_agg` 的輸出順序** | 快照那句要把排序寫在 `json_agg(x order by …)` 上。三端有幾處吃順序（事件由新到舊、`confirmElderOk` 取最近一筆），順序跑掉會解除到錯的事件。 |
| **`family_bindings.family_id` 是 uuid** | Data API 參數一律 text，`where family_id = :uid` 不加 `::uuid` 會直接 42883。所有身分欄位比對都要顯式轉型。 |
| **移除依賴時 import 沒跟著清** | 切到 Aurora 時 `jinsun-progress` 的 `package.json` 拿掉了 `@supabase/supabase-js`，但 `index.mjs` 的 `import` 留著 → **整支 Lambda 載入即死**（`ERR_MODULE_NOT_FOUND`），每一次呼叫（含 Step Functions 的 10 分鐘 tick）都在 init 階段失敗。**症狀是「什麼都沒發生」**：三端畫面正常、資料庫正常，只有長輩那端永遠沒聲音，而且錯誤只進 CloudWatch 的 `INIT_REPORT`，不會回到任何呼叫端。已修（改走 `src/db.js`）。教訓：**Lambda 的依賴變更後一定要真的 invoke 一次**，`update-function-code` 成功不代表跑得起來。 |
| **模擬器會跟你搶指令** | `GET /commands` 是**消耗式**的（讀到就刪，與 `downlink.js` 的 `pull()` 一致）。只要有人開著 `admin/?sim=1`，它就在背景持續輪詢那個序號——這時你用 curl 測同一個序號會**永遠拿到空陣列**，看起來像功能壞了。除錯時改用沒人在看的序號（例如 `JS-SMOKETEST`），或先關掉模擬器分頁。 |
| **Aurora 沒有 Realtime，播報要自己觸發** | Supabase 那套是 worker 訂閱 `dispatch_tasks` 變化。純 AWS 環境若不在寫入點主動觸發，「志工接單 → 收音機說『志工○○大約○分鐘到』」**完全不會發生，而且是靜默的**。現由 `lambda/data/ops.mjs` 的 `acceptTask`／`markArrived`／`setVolunteerLocation` 非同步 invoke `jinsun-progress`（`event.__direct`）。**不要**改用資料庫 trigger／`pg_net`——那會把兩套環境耦合回去（見 §6.1）。 |
| **CORS preflight 會被 `$default` 吃掉** | API Gateway 的自動 preflight 回應**只在沒有任何路由 match 時**才啟動，而 `$default`（給 `POST /voice`）會 match 掉所有請求，包含 `OPTIONS /data/*` → 轉進 `jinsun-voice` → 回 404 → 瀏覽器判定 preflight 失敗（規定必須 2xx），真正的請求根本不送出。**光在 API 上設 CORS 不夠**，`lambda/voice/index.mjs` 還要把 `OPTIONS` 回 204。症狀極難查：**curl 測 API 全過，只有瀏覽器連不上**。用 `smoke-test.sh` 第 3 項驗。 |
| **Cognito group 才是角色，自訂屬性不是** | `custom:role` 使用者自己就能改。`authz.mjs` 與 `cognito_auth.dart` 都只認 `cognito:groups`；`jinsun-auth` 也只接受自助註冊成 family / volunteer。 |
| **`dispatch_kind_t` 少了 `follow_up`** | 三端程式碼一直在插入 `'follow_up'`（督導追蹤單），但 enum 只有 `emergency` / `supply` → 每次觸發都會 `invalid input value for enum`。已在 `schema.sql` 補 `alter type … add value if not exists`，**兩套環境都要重跑 schema 才生效**。 |

---

## 6. 未解決 / 需要你決定

### 6.1 `progress_webhooks.sql` 請不要執行

`cloud/supabase/migrations/20260801000001_progress_webhooks.sql.example` 是早期設計的產物——
當時 AWS 環境還共用 Supabase，需要 `pg_net` trigger 把變化推給 Lambda。
**兩套環境獨立後這是在製造耦合，不要跑。**

AWS 環境不需要資料庫 trigger：所有寫入都經過自己的 Lambda 或（未來的）AppSync resolver，
播報可以直接在寫入時觸發，少一層 trigger、少一個密鑰、少一個失敗點。
這個檔案留著只是記錄，可以刪。

### 6.2 `PROGRESS_WORKER=off` 開關現在用不到

`progress.js` 新增的這個開關，是為了「兩套環境共用資料庫」時避免播報打架。
獨立之後不需要設。開關本身無害，未來多實例部署時仍有用。

### 6.3 兩套 AWS 方案的取捨（已收斂，此節僅記錄理由）

> 結論寫在 §1.4，這裡留的是「為什麼這樣分工」的來龍去脈，之後有人想把伺服器端搬回容器時會用到。

`main` 上的 `2eac758 feat(deploy): add AWS App Runner + S3/CloudFront deployment`
（另一位開發者，13:42）與本分支的做法**目標不同**：

| | `cloud/aws/`（本分支） | `deploy/aws/`（`2eac758` 起） |
|---|---|---|
| 運算 | API Gateway + Lambda + Step Functions | 容器跑 `cloud/prototype`（原 App Runner，現已改 ECS Fargate + ALB） |
| 資料庫 | **Aurora（獨立）** | **Supabase（與正式環境共用）** |
| MQTT | IoT Core（X.509 認證） | mqttgo.io（公共、無認證） |
| LLM | Bedrock | XCC Gateway（`apikey`） |
| 三端前端 | 無（沿用 `deploy/aws/`） | **S3 + CloudFront** |
| 定位 | **獨立的平行環境** | 把現有環境搬到 AWS 運算上 |

**當初讓兩者不能直接疊在一起的三件事，以及現況：**

1. **App Runner 在這個帳號用不了。** 實測 `apprunner:ListServices` 被 **SCP 擋下**
   （`no service control policy allows the apprunner:ListServices action`），
   不是權限設定問題，是帳號層級政策。
   → **已處理**：`deploy-server.sh` 與 `apprunner.yaml`（檔名未改）已改寫成 **ECS Fargate + ALB**。
   ⚠️ 但 **ECS 這條路我沒有實跑過**，不知道此帳號的 SCP 放不放行 `ecs:*` / `elasticloadbalancing:*`。
   伺服器端目前實際在用的是 `cloud/aws/`（Lambda），要動容器那條之前請先自己試一次。
2. **它連的是正式 Supabase。** 跑起來就會變成第三台連正式庫的 server，
   且會啟動 `progress.js` worker → 與現有 Render 那台搶著播報。
   → **仍然成立**，`apprunner.yaml` 的 `SUPABASE_URL` 沒變、檔頭已標警告。
   真要跑，其中一台要設 `PROGRESS_WORKER=off`（見 §6.2）。
3. `deploy/aws/deploy-web.sh`（S3 + CloudFront 部署三端）是本分支沒做、互補的部分。
   → **已完成**：已改成吃 `BACKEND=aws` 指向 Cognito/API Gateway，三端都已部署（網址見 §0）。

`.env.example` 的收斂也做完了：`DB_BACKEND` / `AURORA_*` 都在，
`BEDROCK_MODEL_ID` 已是實測可用的 `us.anthropic.claude-sonnet-4-6`
（`2eac758` 原本寫的 Sonnet 4.5 未經實測；此帳號確認可用的只有 Sonnet 4.6 與 Haiku 4.5，見 §5）。

### 6.4 Render 仍在運行

`https://jinsun-voice-server-mg1f.onrender.com` 是活的、連著正式 Supabase。
兩套環境現在互不干擾，可以並存。切換由韌體端決定：

```
現有環境：BASE_URL=https://jinsun-voice-server-mg1f.onrender.com   MQTT=mqttgo.io:8883
AWS 環境：BASE_URL=https://yr0ep335el.execute-api.us-west-2.amazonaws.com
          MQTT=a2zyk2buv4tih2-ats.iot.us-west-2.amazonaws.com:8883（Amazon Root CA 1）
```

**韌體端已改好**：`firmware/HUB-8735-Ultra-ASR-TTS.ino` 開頭一個 `#define BACKEND_AWS`（`0`／`1`）
同時切換上行端點、MQTT endpoint、根憑證與逾時；`topic、payload、QoS、LWT 全部不變`。
Amazon Root CA 1 已內嵌，開機第一行 `[ENV] …` log 會講明現在連的是哪一套。

**還差燒憑證**：AWS IoT 是 X.509 雙向 TLS，裝置憑證與私鑰要照 §1.1 重簽後貼進
`firmware/secrets.h`。沒填時韌體不會靜默重試，會直接印出缺憑證的原因
——因為 IoT Core 認證失敗是**直接斷線、不回錯誤碼**（見 §5），不講清楚會被當成網路問題查。
另注意 MQTT client id（＝`device_serial`）必須等於 Thing 名稱，憑證也要 attach 到同一個 Thing。

### 6.5 我在正式環境誤刪了 7 筆 `life_events`

清理測試資料時條件下得太寬（`elder_id='elder-1' AND at >= 今天 04:00 UTC`），
把 elder-1 今天中午之後的安心日報條目一併刪了。`schema.sql` 沒有 `life_events` 種子，無法還原。
剩餘 92 筆，最新一筆停在今天上午 10:00。使用者已表示不用重建，此處僅記錄。

### 6.6 既有的產品問題（非遷移造成）

`trg_after_radio_event` 只掛 `AFTER INSERT`，所以升級（UPDATE）不會同步長輩的 `severity`。
**本 repo 的 `dispatch.js` 已用手動 `update elders` 補上**（搬移時已保留該修正）。
若日後要從 schema 根治，改成 `after insert or update`。

---

### 6.7 三個 schema 缺陷（已全部修好，正式環境還差一步）

部署過程中撞到三個缺陷，都不是遷移造成的，是 `cloud/supabase/schema.sql` 與正式環境之間
長期漂移的結果。**AWS（Aurora）三個都已修好並實測；正式 Supabase 還需要套一次 migration。**

先講**實際查證過的正式環境狀態**（用 anon key 唯讀查的，沒有動任何資料）：

| 缺陷 | Aurora | 正式 Supabase | 說明 |
|---|---|---|---|
| ① `fn_after_radio_event` 型別不合 | ✅ 已修 | **沒中**（危險的是反過來） | 見下 |
| ② `dispatch_tasks.proof_photo_url` 未宣告 | ✅ 已補 | **本來就有** | 正式環境早就補過，只是沒回寫 schema.sql |
| ③ `dispatch_kind_t` 缺 `follow_up` | ✅ 已補 | ❌ **確認缺** | 「注意軌 → 督導追蹤」目前在正式環境是壞的 |

**① 危險方向跟我一開始猜的相反。**

```
declare cur text;                          -- ← 應為 severity_t
...  else coalesce(cur, new.severity)      -- coalesce(text, severity_t)
ERROR: COALESCE types text and severity_t cannot be matched (42804)
```

正式環境**沒有**中這個 bug —— 查過 `radio_events` 共 63 筆、最新一筆是今天 13:09（台北），
`elder_id` 也正常填著，代表寫入一切正常，那邊跑的還是舊版（會誤降級但不會炸）的 trigger。

真正的風險是：`cloud/supabase/schema.sql` 與
`cloud/supabase/migrations/20260801130000_after_radio_event_only_raise.sql` **裡面就是壞掉的那一版**。
**誰把它套到正式環境，正式環境的收音機事件當場全部寫不進去。** 那支 migration 是顆地雷，
已經拆掉（兩個檔都改成 `declare cur severity_t` 並顯式轉型）。

症狀之所以難查：`dispatch.js` 對資料庫錯誤只 log 不中斷，外表看起來是
「派遣單開出來了，但沒有對應事件、而且 `dispatch_tasks.elder_id` 是 NULL」，
志工 App 顯示「長輩（0 歲）」。當初就是這樣抓到的。

**③ 這個正式環境真的中了。** 查 `kind=eq.follow_up` 直接回
`22P02 invalid input value for enum dispatch_kind_t`。`supabase_backend.dart` 的
`_recordFallTrend`（7 天內 3 次「疑似跌倒但回應無恙」→ 為督導開追蹤訪視待辦）
每次觸發都會失敗。

### 正式 Supabase 要套的 migration

兩支檔案都已修正並**在 Aurora 上用同一份 SQL 實跑驗證過**
（含行為驗證：attention → 來一筆 normal 事件不降級 → emergency 可升級；`follow_up` 插得進去）：

```
cloud/supabase/migrations/20260801130000_after_radio_event_only_raise.sql
cloud/supabase/migrations/20260801160000_follow_up_kind_and_proof_photo.sql
```

到 Supabase Dashboard → SQL Editor 依序貼上執行即可。
兩支都冪等、都不 drop 任何資料表或欄位，對有資料的正式庫安全。
`alter type ... add value` 那句請單獨執行（不能與「同一交易內使用該新值」並存）。

### 6.8 其它一併修掉／發現的

1. **`dispatch_kind_t` 缺 `follow_up`**（見 §5）。既有缺陷，兩套環境都受影響，已補 enum 值。
2. **部署在 Lambda 上的 `jinsun-voice` bundle 比 repo 舊。** 缺了「升級時手動把長輩轉
   `severity=emergency`」那段修正（§6.6 說的那個），所以家屬首頁的長輩燈號永遠停在
   🟡「注意」、不會轉 🔴。**已重新 build 並更新 `jinsun-voice` 與 `jinsun-progress`。**
   教訓：改 `cloud/prototype/src` 之後一定要重跑 `build.sh` + `update-function-code`，
   Lambda 不會自己跟著 repo 走。
3. **`apps/volunteer_app` 的 widget test 本來就是紅的**
   （「緊急派遣進來 → 出現待接單卡與接單鍵」找不到「緊急派遣」文字）。
   已確認在本次改動之前就會失敗，與後端切換無關，但那是黃金鏈路的志工端出口，值得儘早查。

### 6.9 三端現在真的不直接碰 Supabase 了

之前交接文件寫「三個 App 完全沒有直接碰 Supabase」，實際上還有四處在打：
`family_app/app_local.dart`（`family_bindings`）、`family_app/screens/home_page.dart`
（`app_settings`）、`admin/hardware_sim.dart`（`app_settings`）、`push_service.dart`
（`device_tokens`）。這四處已收進 `BackendClient`
（`familyBindings` / `bindFamily` / `appSetting` / `setAppSetting` /
`registerDeviceToken` / `unregisterDeviceToken`），三套實作各自提供。

`PushService` 多了一個 `backend` 欄位，App 啟動時指定；**沒指定就不落地 token**——
否則 AWS 環境的 App 會把 token 偷偷寫進正式環境的 Supabase。

---

## 7. 賽後清理

Aurora 是唯一持續計費的項目（約 $43/月），記得刪。

```bash
aws rds delete-db-instance --db-instance-identifier jinsun-aurora-1 --skip-final-snapshot
aws rds delete-db-cluster  --db-cluster-identifier jinsun-aurora --skip-final-snapshot
aws rds delete-db-subnet-group --db-subnet-group-name jinsun-db-subnets
aws apigatewayv2 delete-api --api-id yr0ep335el
for f in jinsun-voice jinsun-speak jinsun-progress; do aws lambda delete-function --function-name $f; done
aws stepfunctions delete-state-machine --state-machine-arn "$LADDER_ARN"
aws stepfunctions delete-state-machine --state-machine-arn "$ENROUTE_ARN"
aws dynamodb delete-table --table-name jinsun_emergency_sessions
aws dynamodb delete-table --table-name jinsun_progress_announced
aws dynamodb delete-table --table-name jinsun_downlink
# IoT：先 detach 再刪憑證與 thing；IAM role 先 delete-role-policy 再 delete-role
```

建議先設一道 AWS Budgets 告警，避免忘記。
