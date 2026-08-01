# AWS 平行環境

本目錄是**與現有 Render + Vercel + Supabase 環境功能等價、但完全跑在 AWS 上**的另一套部署。
兩套環境**互相獨立、不共用資料庫**；切換方式是改韌體的 `BASE_URL` 與 MQTT endpoint。

**接手請先讀 [`../../docs/requirements/aws-handoff.md`](../../docs/requirements/aws-handoff.md)**（環境識別碼、未完成項目、已知的坑、賽後清理）。

設計說明、實測數據與踩雷紀錄見 [`../../docs/requirements/aws-architecture.md`](../../docs/requirements/aws-architecture.md)。

## 為什麼要「不共用資料庫」

兩套環境若指向同一個 Supabase，會有三個問題：

1. **播報打架**——兩邊的進度 worker 都會反應同一筆 `dispatch_tasks` 變化，各自往自己的 broker 發，
   且各自維護去重狀態、互不知情。
2. **測試污染正式資料**——在 AWS 這側跑一次升級測試，就會在正式環境開出真的派遣單、推播到真實手機。
3. **不是真的「兩套環境」**——資料層是單點，任何一邊改壞 schema 兩邊一起死。

所以 AWS 這側要有自己的 **Aurora Serverless v2**（見下方待辦）。

## 目錄

```
cloud/aws/
├── lambda/
│   ├── voice/      POST /voice —— 沿用 cloud/prototype/src 的六個 agent，
│   │               只把 Emergency 的行程內 setTimeout 換成 Step Functions
│   ├── speak/      下發一句話到 IoT Core（Step Functions 的「說話」步驟）
│   ├── progress/   進度播報 —— progress.js 的 AWS 版
│   ├── data/       三端 App 的資料 API（取代 Supabase PostgREST + Realtime）
│   │   ├── index.mjs   /data/version（變更指紋）、/data/snapshot、/data/mutate
│   │   ├── authz.mjs   角色授權 —— 取代 RLS 的那一層（純函式，有測試）
│   │   └── ops.mjs     具名寫入操作，可寫欄位寫死
│   └── auth/       Cognito 觸發器：PreSignUp 自動確認、PostConfirmation 加 group＋寫 profiles
├── stepfunctions/
│   ├── emergency-ladder.asl.json     20 秒逾時階梯（絕對時間戳）
│   └── enroute-broadcast.asl.json    路上每 10 分鐘（取代 setInterval）
├── iot/device-policy.json            裝置只能碰自己的 topic
└── scripts/
    ├── build.sh                      打包五支 Lambda
    ├── set-lambda-env.mjs            把 .env 裡的機密併進 Lambda 環境變數
    ├── setup-cognito.sh              User Pool + 三個 Group + App Client + 觸發器
    └── deploy-data.sh                jinsun-data + API 路由 + JWT authorizer + 照片 bucket
```

**Lambda handler 不重複實作商業邏輯**——直接 import `cloud/prototype/src` 的
agents / dispatch / triggers / progress。`build.sh` 會在打包時把用到的模組複製進 bundle。
改播報文案或狀態機邏輯，只要改 `cloud/prototype/src` 一處，兩套環境同時生效。

## 打包與部署

```bash
bash cloud/aws/scripts/build.sh              # → cloud/aws/.build/*.zip
aws lambda update-function-code --function-name jinsun-voice \
  --zip-file fileb://cloud/aws/.build/voice.zip
```

機密（Supabase／Bedrock 金鑰等）不進版控，用腳本從 `cloud/prototype/.env` 併進去：

```bash
LAMBDA_FN=jinsun-voice node --env-file=cloud/prototype/.env \
  cloud/aws/scripts/set-lambda-env.mjs SUPABASE_URL SUPABASE_SECRET_KEY
```

## 已部署（us-west-2 / account 012804034919）

| 元件 | 資源 |
|---|---|
| `POST /voice` | API Gateway `jinsun-voice-api` → Lambda `jinsun-voice` |
| `POST /asr` | 同上（`$default` 路由）→ 代理 XCC Gateway 的 Breeze ASR，PAT 存 `XCC_GATEWAY_PAT` |
| 逾時階梯 | Step Functions `JinsunEmergencyLadder` + Lambda `jinsun-speak` |
| 進度播報 | Lambda `jinsun-progress` + Step Functions `JinsunEnrouteBroadcast` |
| 下行 MQTT | IoT Core（Thing `JS-0001`、`JS-REAL-0001`，policy `JinsunDevicePolicy`） |
| LLM | Bedrock（Sonnet 4.6 / Haiku 4.5） |
| 狀態 | DynamoDB `jinsun_emergency_sessions`、`jinsun_progress_announced` |
| **資料庫** | **Aurora Serverless v2 `jinsun-aurora`（PostgreSQL 16.14，Data API）** |

### 資料庫

```
cluster : jinsun-aurora        database: jinsun
engine  : aurora-postgresql 16.14（Serverless v2，0.5–4 ACU）
Data API: 已啟用 —— Lambda 不必進 VPC，也不必自己管連線池
密碼    : RDS 託管於 Secrets Manager（--manage-master-user-password），無人經手
```

> ⚠️ **最小容量刻意設 0.5 ACU 而非 0**。Serverless v2 從零擴容約需 15 秒，
> 那會直接吃掉 20 秒黃金窗——升級那一刻若資料庫正在冷啟動，派遣單會晚寫入。
> 每月約 $43 換取確定性，對這個系統值得。

Schema 由 `cloud/supabase/schema.sql` **自動轉換**產生，兩套環境共用同一份定義：

```bash
node cloud/aws/db/transform-schema.mjs > cloud/aws/db/schema.sql   # 產生（已 commit）
CLUSTER_ARN=... SECRET_ARN=... node cloud/aws/db/apply-schema.mjs  # 套用（--dry-run 可先看）
```

移除的四塊 Supabase 專屬語法：`auth.users` 外鍵、`fn_handle_new_user` 觸發器、
`supabase_realtime` publication、RLS policies。**資料表、型別、業務觸發器
（`fn_on_radio_event` / `fn_after_radio_event`）與種子資料完全保留**——
已驗證：22 位長輩、6 位志工、3 位社工、18 張證照、2 個業務觸發器都在。

## 待辦（達成「完全獨立」還缺的）

- [x] ~~Aurora Serverless v2~~ ✅ 已建並套用 schema + 種子資料
- [x] ~~Lambda 資料存取換成 Aurora Data API~~ ✅ **兩套環境已完全斷開**
      （`jinsun-voice` / `jinsun-progress` 的 `SUPABASE_*` 環境變數已移除，想碰也碰不到）
- [x] ~~`travel.js` 走 `db.js`~~ ✅ Aurora 沒有 Realtime → 改輪詢已接單的派遣單
- [x] ~~**Cognito**~~ ✅ User Pool `us-west-2_f34wIqjEd` + 三個 Group + `jinsun-auth` 觸發器已部署
- [x] ~~**三端資料層**~~ ✅ `jinsun-data`（REST + 變更指紋輪詢）已部署，四條路由掛 JWT authorizer。
      不用 AppSync 的理由見 [`aws-architecture.md` §4.4](../../docs/requirements/aws-architecture.md)
- [x] ~~`aws_backend.dart`~~ ✅ 已實作同一個 `BackendClient`；完整黃金鏈路已在真 AWS 上跑通
- [x] ~~三端 Flutter Web → S3 + CloudFront~~ ✅ 四端 HTTPS 站台已上線（含長輩端；網址見 handoff §0）
- [ ] `send-push` Edge Function → Lambda + SNS Mobile Push（`device_tokens` 已會寫進 Aurora）
- [x] ~~`whisper` Edge Function~~ ✅ 改成 `jinsun-voice` 的 `POST /asr` 代理，上游沿用同一個
      XCC Gateway（Breeze ASR）。刻意**不**用 Transcribe：Transcribe 沒有台語，換過去等於
      在台語長輩身上把辨識率換掉，而這條路徑正是長輩唯一的輸入方式
- [ ] 台語 ASR/TTS → SageMaker endpoint（Transcribe 無台語）

> 實測結果與踩雷紀錄見 [`aws-handoff.md` §3.2 / §6.7](../../docs/requirements/aws-handoff.md)。

## 三端 App 怎麼切到這一套

同一份 Flutter 原始碼，靠建置參數切換（見 `apps/packages/core/lib/src/backend_factory.dart`）：

```bash
export BACKEND=aws
export AWS_API_BASE=https://xxxx.execute-api.us-west-2.amazonaws.com
export COGNITO_CLIENT_ID=xxxx
bash deploy/aws/deploy-web.sh
```

App 內只有 `JinsunBackends` 這一個地方知道現在跑在哪一套；UI 一行都不用改。
參數缺一會退回 Supabase 並在 console 印警告——所以 `deploy-web.sh` 在 `BACKEND=aws`
時會**先檢查參數齊全才開始 build**，避免 build 出一個「看起來正常、資料卻連到正式環境」的站台。

## 資料層如何共用同一份程式碼

`cloud/prototype/src/db.js` 依 `DB_BACKEND` 回傳兩種 client：

| `DB_BACKEND` | 行為 |
|---|---|
| `supabase`（預設） | 直接回傳真正的 Supabase client —— Render 環境行為零改變 |
| `aurora` | 介面相容的薄殼，底層走 Aurora Data API |

**`dispatch.js` 等業務程式一行都沒改。** 兩套環境跑同一段查詢邏輯，才不會修好一邊、另一邊悄悄壞掉。

Data API 有兩個 PostgREST 會自動處理、它不處理的坑，`db.js` 已解決：

1. **enum 欄位**——Data API 參數一律是 `text`，Postgres 不會隱式轉成 `event_type_t`。
   轉接層查一次 `information_schema` 取得欄位型別並快取，每個參數自動加 `::型別`。
2. **`text[]` 陣列**——Postgres 陣列字面值是 `{"a","b"}` 而非 JSON `["a","b"]`。

> ✅ **已驗證斷開**：打一次 `/voice` 走完整升級鏈路後，
> Aurora `radio_events`/`dispatch_tasks` 各 +1，**Supabase 兩張表筆數完全未變**。
