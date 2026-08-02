# asr-sagemaker（中文 ASR endpoint）

把 [Breeze-ASR-26](https://huggingface.co/paulpengtw/faster-whisper-Breeze-ASR-26)（CTranslate2 fp16，
底為 whisper-large-v2 針對台灣國語微調）部署成 SageMaker 即時 endpoint，供語音 Agent server 做 ASR。

只服務「長輩主動求助／代辦」那段上雲的語音，符合架構約束 1 的隱私邊界——跌倒推論與關鍵字偵測仍在裝置端。

評估結論、實測數字與選型理由見
[`../../docs/requirements/asr-breeze-sagemaker.md`](../../docs/requirements/asr-breeze-sagemaker.md)。

## 啟動

```bash
cp .env.example .env        # 填 SAGEMAKER_ROLE_ARN
scripts/fetch-model.sh      # 抓 3.1GB 權重到 model/（gitignore，可重複執行續傳）
scripts/deploy.sh           # 上傳 + 建 endpoint，約 15 分鐘
scripts/test.sh samples/*.wav
scripts/teardown.sh         # 用完務必執行，GPU 機型持續計費
```

改了 `src/inference.py` 之後用 `scripts/redeploy.sh v2` 滾動更新——只重傳 code，
S3 上的 2.9GB 權重不動。

## 介面（OpenAI 相容）

主要契約與 OpenAI `/v1/audio/transcriptions` 一致——吃 `multipart/form-data`，
欄位 `file` / `model` / `language` / `prompt` / `temperature` / `response_format`
（`json` | `verbose_json` | `text`），回 OpenAI 形狀的 `{"text": …}`。

這樣設計是為了讓前面那層代理只需要「重新簽章、原封轉發」，不用解析或改寫 payload；
韌體現有打 XCC Gateway 的 multipart 也就能原樣流過去。

另外保留兩種原生用法：

- `audio/wav`（或任何 `audio/*`）：直接送音檔 bytes
- `application/json`：`{"audio_base64": "…", "initial_prompt": "…", "beam_size": 5, "vad_filter": true}`

`json` 格式除了 `text` 還會多回 `segments[] / language / duration / processing_ms`
（OpenAI 只保證 `text`，其餘是擴充欄位）。即時 endpoint payload 上限 6MB，
約等於 3 分鐘 16kHz mono 語音。

### prompt 與時間戳的取捨

`prompt`（= faster-whisper 的 `initial_prompt`）餵照護領域詞彙可修正同音字錯誤
（實測「血壓要」→「血壓藥」）。未指定時會套用 `ASR_INITIAL_PROMPT` 環境變數的預設詞彙，
所以呼叫端不傳也有基本保護。

⚠️ **代價是 `segments` 的時間戳會失準**——實測同一段 4.2 秒語音，不帶 prompt 時
`end` 是 4.56，帶 prompt 時塌成 0.02。這是 whisper 對 prompt 條件化的已知副作用，
**`text` 完全不受影響**。

對本專案來說這個交換划算：狀態機只吃 `text`，而同音字錯誤是安全風險。
若你的用途真的需要可信的時間戳，明確傳 `prompt=""` 關掉預設詞彙即可
（空字串是「明確關閉」，不會被預設值蓋回去）。

```bash
scripts/test.sh samples/*.wav                    # 原生 JSON 介面 + 延遲拆解
scripts/test-openai.sh samples/sos.wav verbose_json   # OpenAI multipart 形狀
```

### endpoint 本身不是公開 REST API

SageMaker 的傳輸層強制 AWS SigV4 簽章，所以 endpoint **不能直接 curl**，也不能讓 HUB8735
直連（簽章鏈太重，且韌體不該持有 IAM 憑證）。要拿到真正可以 curl 的
`https://…/v1/audio/transcriptions`，前面得有一層「重新簽章、原封轉發」的代理。

三種做法，擇一：

| 做法 | 位置 | 適用 |
|---|---|---|
| **API Gateway + Lambda**（✅ 已部署） | `cloud/aws/lambda/asr-openai/` | AWS 平行環境；跟 `/voice`、`/tts` 同一個網域 |
| Render 語音 server 加路由 | `examples/asr-proxy-route.mjs` | 正式環境；零新增 AWS 資源 |
| 純 SDK 呼叫 | `examples/invoke.mjs` | 後端對後端，不需要 HTTP 門面 |

三者驗證方式一致：自訂金鑰走 `x-bf-vk` 或 `Authorization: Bearer`。

AWS 那條已經上線，部署與網址見
[`../aws/scripts/deploy-asr-openai.sh`](../aws/scripts/deploy-asr-openai.sh)：

```bash
bash cloud/aws/scripts/deploy-asr-openai.sh     # 冪等，重跑不會換掉既有金鑰
```

它掛的是既有的 `jinsun-voice-api`，開三條路由：`POST /v1/audio/transcriptions`、
`OPTIONS /v1/audio/transcriptions`、`GET /v1/models`。實測可直接餵給官方 OpenAI SDK：

```python
from openai import OpenAI
c = OpenAI(base_url="https://<api-id>.execute-api.us-west-2.amazonaws.com/v1", api_key="sk-jinsun-…")
c.audio.transcriptions.create(model="breeze-asr-26", file=open("samples/sos.wav", "rb")).text
# → '我跌倒了 站不起來 快來幫我'
```

⚠️ **音檔上限 4.5MB**（約 2 分鐘 16kHz mono）。這條路比 endpoint 本身的 6MB 更緊：
Lambda 同步呼叫的 payload 上限是 6MB，而 API Gateway 會把 binary body 做 base64（膨脹 4/3）。
⚠️ **單次請求上限 30 秒**（API Gateway HTTP API 的整合逾時硬上限，不可調）。

細節見 [`../../docs/requirements/asr-breeze-sagemaker.md`](../../docs/requirements/asr-breeze-sagemaker.md)。

## 目錄

| 路徑 | 說明 |
|---|---|
| `src/inference.py` | SageMaker handler：`model_fn` / `input_fn` / `predict_fn` / `output_fn` |
| `src/requirements.txt` | 容器啟動時安裝，版本與 DLC 的 cuDNN 綁定 |
| `scripts/` | fetch-model / deploy / redeploy / test / teardown / make-samples |
| `samples/` | 四段台灣國語長輩測試語音（跌倒求救／代購／沒事／領藥） |
| `model/` | 權重，gitignore，由 `fetch-model.sh` 重建 |
