# whisper — 聊天語音輸入轉文字（ASR 代理）

家屬↔志工聊天的「按住說話」語音輸入用的 ASR。前端（`jinsun_ui_kit` 的 `ChatScreen`）
錄好音檔後 base64 送到這支 Edge Function，這支代理呼叫上游 ASR，回傳純文字。

**上游預設走 XCC Gateway 的 Breeze ASR**（`paulpengtw/faster-whisper-Breeze-ASR-26`，
台灣中文／台語優化），可用環境變數改成其他相容 `/audio/transcriptions` 的上游。

**為什麼要代理**：上游金鑰是機密，只能存後端 secret，不能進 Flutter 前端封包。
前端只認得 Supabase anon key，透過 `supabase.functions.invoke('whisper', ...)` 呼叫。

> 這條線與「長輩端裝置影音永不上雲」的隱私邊界無關——那條邊界管的是長輩端裝置，
> 這裡是 App 使用者主動對自己手機錄音。詳見 `docs/architecture.md` §1。

## 介面

`POST`（JSON body）：

```jsonc
{
  "audio_base64": "<音檔位元組 base64>",  // 必填
  "filename": "audio.webm",              // 需帶正確副檔名，靠它判斷格式
  "mime": "audio/webm",                  // 選填
  "language": "zh",                       // 選填，預設 zh
  "prompt": "常用詞提示"                   // 選填，提高專有名詞辨識率
}
```

回傳：`{ "text": "辨識出的文字" }`；失敗回 `{ "error": "...", "detail": "..." }`。

## 上游環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `XCC_GATEWAY_PAT` | （必填） | Gateway 存取權杖，送 `x-bf-vk` 標頭 |
| `ASR_ENDPOINT` | `https://llm-gateway.xcc.tw/v1/audio/transcriptions` | 上游端點 |
| `ASR_MODEL` | `paulpengtw/faster-whisper-Breeze-ASR-26` | 模型 |

上游對應原始 curl：

```bash
curl -X POST "https://llm-gateway.xcc.tw/v1/audio/transcriptions" \
  -H "x-bf-vk: $XCC_GATEWAY_PAT" \
  -F "file=@audio.wav" \
  -F "model=paulpengtw/faster-whisper-Breeze-ASR-26" \
  -F "language=zh" -F "response_format=json"
```

## 部署

```bash
# 1. 設定 Gateway 權杖（存後端 secret，不進前端）
supabase secrets set XCC_GATEWAY_PAT=... --project-ref <project-ref>
# （選填）覆寫端點／模型
supabase secrets set ASR_MODEL=paulpengtw/faster-whisper-Breeze-ASR-26 --project-ref <project-ref>

# 2. 部署
supabase functions deploy whisper --project-ref <project-ref>
```

`<project-ref>` 見 `cloud/supabase/.env` 的 `SUPABASE_PROJECT_REF`（目前 `ykfxmoubynnbhnburawl`）。
