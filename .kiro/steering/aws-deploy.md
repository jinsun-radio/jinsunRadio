---
inclusion: auto
---

# AWS 部署指引

本專案的雲端部署已從 Render 遷移至 AWS。以下是 Kiro 在協助部署相關工作時的必要知識。

## 架構概覽

| 元件 | AWS 服務 | 說明 |
|------|----------|------|
| 語音 Agent server | **ECS Fargate** (ECR image + ALB) | 常駐 Node.js 程序，不可用 Lambda（20秒計時器、長輪詢、Realtime 訂閱） |
| 三端 Flutter Web | **S3 + CloudFront** | 靜態檔案，CloudFront 做 HTTPS + CDN + SPA fallback |
| 資料庫/即時同步 | **Supabase**（外部） | Postgres + Realtime，不在 AWS 上 |
| MQTT 下行 | **mqttgo.io**（外部 broker） | server 當 client 連公共 broker，與裝置會合 |
| LLM | **XCC Gateway**（預設）/ **Bedrock**（可切換） | 社工後台可即時切換 provider |

## 部署腳本位置

```
deploy/aws/
├── deploy-server.sh      # 語音 server → ECR + App Runner
├── deploy-web.sh         # 三端 Flutter → S3 + CloudFront
├── apprunner.yaml        # App Runner 宣告式設定參考
└── cloudfront-spa.json   # CloudFront SPA fallback 設定
```

## 部署流程

### 語音 Server

```bash
bash deploy/aws/deploy-server.sh
```

腳本自動：建 ECR repo → Docker build (linux/amd64) → push → 建 ECS Cluster → IAM role → Security Groups → ALB + Target Group → Task Definition → ECS Service。
部署完成後會得到 ALB DNS（如 `http://jinsun-alb-xxx.us-west-2.elb.amazonaws.com`）。

### 三端 Flutter Web

```bash
export SERVER_URL=https://xxxxx.awsapprunner.com
bash deploy/aws/deploy-web.sh
```

腳本自動：建 S3 bucket → flutter build web → sync → CloudFront invalidation。

## 重要環境變數

| 變數 | 用途 | 機密 |
|------|------|------|
| `AWS_REGION` | 預設 us-west-2 | ✗ |
| `LLM_API_KEY` | XCC Gateway 金鑰 | ✓ |
| `SUPABASE_SECRET_KEY` | Supabase service key | ✓ |
| `MQTT_URL` | 外部 MQTT broker | ✗ |
| `SERVER_URL` | 語音 server 公開網址（admin build 用） | ✗ |

## 注意事項

1. **ECS Fargate 需要 public subnet**：Task 設 `assignPublicIp=ENABLED` 才能拉 ECR image（除非有 NAT Gateway）。
2. **ALB 只開 HTTP:80**：demo 用足夠。正式環境加 HTTPS listener + ACM 憑證。
3. **CloudFront SPA fallback**：403/404 → /index.html (200)，讓 Flutter router 處理。
4. **機密目前放 Task Definition env**：demo 可接受；正式環境改用 Secrets Manager + secretsReferencedBy。
5. **Bedrock 權限**：若要切換到 Bedrock，Task role 需加 bedrock:InvokeModel 權限，或用環境變數帶入 AWS_BEARER_TOKEN_BEDROCK。

## Kiro 工作流程建議

- 修改 server 程式碼後，跑 `bash deploy/aws/deploy-server.sh` 即可更新。
- 修改 Flutter UI 後，跑 `bash deploy/aws/deploy-web.sh` 即可更新。
- 新增環境變數時，同步更新 `deploy/aws/apprunner.yaml` 和 `cloud/prototype/.env.example`。
- 架構有變動時，同步更新 `docs/architecture.md`。
