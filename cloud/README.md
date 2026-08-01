# cloud（雲端後端）

事件分級、決策派遣、資料層與角色權限，串起裝置端與三個使用者端。

## 服務

| 服務 | 用途 | 原型對應（規劃中，尚未動工） |
|---|---|---|
| AWS IoT Core | 接收裝置端 MQTT 事件 | aedes MQTT broker |
| Step Functions + Lambda | 事件分級、逾時升級、派遣狀態機 | core.js 狀態機 |
| Bedrock / Transcribe / Polly | ASR／LLM／TTS | ai.js（介面設計為可直接切換成真的 Bedrock） |
| DynamoDB + Cognito | 資料層、角色權限（家屬／志工／社工） | db.js 資料層 |

即時推播給使用者端透過 WebSocket / AppSync。

詳見 [`../docs/architecture.md`](../docs/architecture.md)。

## 狀態

尚未開始實作，先以本地原型（aedes / core.js / ai.js / db.js）驗證狀態機邏輯，之後再換成對應的 AWS 服務。
