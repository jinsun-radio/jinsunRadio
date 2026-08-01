# 部署與展示

系統有兩塊，部署位置不同：

| 元件 | 位置 | 為什麼 |
|---|---|---|
| 家屬／志工／社工 三端（Flutter Web） | **AWS S3 + CloudFront**（靜態）或 Vercel | 純靜態檔，給網址即可用 |
| 語音 Agent server（`cloud/prototype`） | **AWS ECS Fargate + ALB**（常駐）或 Render | 20 秒升級計時器、`/commands` 長輪詢＋下行佇列、進度播報 Realtime 訂閱都要常駐程序，serverless 會全壞 |

> ⭐ **推薦方案：AWS（ECS Fargate + S3/CloudFront）**——見下方「方案 A」。
> Render + Vercel 方案仍保留作為備選（見「方案 B」）。

> 三端的資料連動走 Supabase（已在雲端），所以就算不部署 server，三端上 Vercel 後也能靠 Supabase 即時同步。
> 只有**社工後台的「硬體模擬」頁**與**語音大腦（Bedrock／急救鏈路／進度播報）**需要 server。

---

## 方案 A：AWS ECS Fargate + S3/CloudFront（推薦）

以 Kiro 為主要開發工具，全程用 CLI 完成，不需要進 AWS Console。

### 前提

- 已安裝 `aws` CLI（[安裝](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)）
- 已安裝 `docker`（Docker Desktop）
- AWS credentials 設好（見下方「設定 credentials」）

### 設定 AWS credentials

```bash
# 互動式引導
bash deploy/aws/setup-credentials.sh

# 或者——Workshop 一時憑證：從 Dashboard 複製 export 貼進 terminal
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
export AWS_DEFAULT_REGION="us-west-2"

# 或者——IAM 長期憑證：
aws configure
```

### ① 部署語音 server（ECS Fargate，常駐）

```bash
bash deploy/aws/deploy-server.sh
```

腳本自動完成：
1. 建立 ECR repository（若不存在）
2. Docker build（ARM64，Apple Silicon 原生、快速）
3. Push image 到 ECR
4. 建立 ECS Cluster、IAM role、Security Groups
5. 建立 ALB + Target Group + Listener
6. 註冊 Task Definition（Fargate ARM64 / Graviton）
7. 建立 / 更新 ECS Service

部署完成後會得到 ALB URL（如 `http://jinsun-alb-xxx.us-west-2.elb.amazonaws.com`），記下來。

**目前正式 ALB URL：**
```
http://jinsun-alb-1316925531.us-west-2.elb.amazonaws.com
```

### ② 部署三端 Flutter Web（S3 + CloudFront）

```bash
export SERVER_URL=http://jinsun-alb-1316925531.us-west-2.elb.amazonaws.com
bash deploy/aws/deploy-web.sh
```

腳本自動完成：
1. 建立 3 個 S3 bucket（靜態網站託管）
2. Flutter build web（admin 帶 `--dart-define=SIM_BASE=$SERVER_URL`）
3. Sync 到 S3（含 cache-control 策略）
4. CloudFront cache invalidation（如有設定 distribution ID）

### 可調環境變數

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `AWS_REGION` | us-west-2 | 部署 region |
| `ECR_REPO` | jinsun-voice-server | ECR repo 名 |
| `CLUSTER_NAME` | jinsun-cluster | ECS cluster 名 |
| `SERVICE_NAME` | jinsun-voice-server | ECS service 名 |
| `BUCKET_FAMILY` | jinsun-family-web | 家屬 S3 bucket |
| `BUCKET_VOLUNTEER` | jinsun-volunteer-web | 志工 S3 bucket |
| `BUCKET_ADMIN` | jinsun-admin-web | 社工 S3 bucket |
| `CF_DIST_FAMILY` | (空) | CloudFront Distribution ID |

### 設定檔參考

- `deploy/aws/apprunner.yaml`：ECS Fargate 宣告式設定（人讀用，非 CLI 直接吃）
- `deploy/aws/cloudfront-spa.json`：CloudFront 自訂錯誤頁（SPA fallback）
- `deploy/aws/setup-credentials.sh`：AWS credentials 設定引導

---

## 方案 B：Render + Vercel（備選）

### ① 先部署語音 server（Render，常駐）

`deploy/render.yaml` 已備好。Render Dashboard → New → **Blueprint** → 指到本 repo →
在 Dashboard 補三個機密環境變數：`AWS_ACCESS_KEY_ID`／`AWS_SECRET_ACCESS_KEY`（**用不會過期的 IAM 憑證**，非 workshop 一時憑證）、`SUPABASE_SECRET_KEY`。
部署好會得到一組網址，如 `https://jinsun-voice-server-mg1f.onrender.com`（記下來，下一步要用）。

> 只想先在本機 demo 又要公開網址：`brew install cloudflared && cloudflared tunnel --url http://localhost:8787`，
> 會得到一組臨時 https 網址（每次重開會變）。

### ② 再部署三端 Vercel（把 server 網址帶進去）

需要一組 Vercel token（vercel.com → Settings → Tokens → Create）：

```bash
export VERCEL_TOKEN=你的token
export SERVER_URL=https://jinsun-voice-server-mg1f.onrender.com   # ← 上一步的 server 網址
bash deploy/deploy-all.sh
```
`SERVER_URL` 會在 build 時透過 `--dart-define=SIM_BASE=` 注入 admin，讓「硬體模擬」頁打得到 server。
（家屬／志工不需要，它們只走 Supabase。）

會依序 build 並部署三個 App，各印出一組正式網址：

| App | 建議 project 名 | 給誰用 |
|---|---|---|
| 家屬 App | jinsun-family | 家屬（手機瀏覽器，可加到主畫面像 App） |
| 志工 App | jinsun-volunteer | 社區志工 |
| 社工後台 | jinsun-admin | 社工／管理者（電腦） |

Demo 參數：家屬 `?demo=1`（自動登入綁定）、`?demo=fall`（自動演跌倒）；
志工 `?demo=sos`；後台開 `#admin`。

## 「不是網站」的部分怎麼給別人看

| 交付物 | 形式 | 給別人看的方式 |
|---|---|---|
| 家屬／志工／社工三端 | Flutter Web | ← 部署 Vercel，給網址即可（本頁上方） |
| 家屬／志工手機 App（原生） | Flutter Android／iOS | Android：`flutter build apk` 給 .apk 安裝；iOS：TestFlight。展示用 Web 版即可，不必先上架 |
| 收音機（長輩端硬體） | 韌體＋裝置 | 拍 30 秒實機 demo 影片＋現場實機；規格見 `docs/HARDWARE_SPEC.md` |

> 對比賽 demo 而言，Web 版部署後給一條網址是最省事的方式：評審在自己的
> 手機上就能同時開三端操作，家屬 App 加到主畫面後全螢幕、與原生 App 幾乎
> 無異。原生 APK／iOS 上架留到真正落地推廣階段再做。

## 備註

- `deploy/vercel.json` 設定 SPA fallback（找不到實體檔的路徑回 index.html），
  部署時腳本會自動複製進各自的 `build/web`。
- Vercel 免費方案足夠 demo；三個 App 是三個獨立 project。
- 若偏好 Netlify：把 `build/web` 目錄拖進 Netlify Drop（app.netlify.com/drop）
  也能立刻得到網址，完全不用 CLI 或帳號設定。
