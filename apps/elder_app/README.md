# elder_app — 長輩端收音機（網頁版）

實體收音機的網頁替身：一顆佔滿下半螢幕的「按住說話」大按鈕、一張大字卡片，
沒有選單、沒有設定頁、沒有登入畫面（架構約束 2：長輩端沒有 UI）。
給沒有硬體在手上時做 demo 與對測用；真機的行為契約見
[`docs/requirements/hardware-integration.md`](../../docs/requirements/hardware-integration.md)。

一次互動的流程：

```
按住大按鈕錄音（WAV 16k 單聲道）
  → 放開 → BackendClient.transcribeAudio() 拿逐字稿
  → POST /voice（多 Agent 決定求助／代辦／閒聊）
  → 念出回覆（雲端 TTS，打不通退回瀏覽器語音）
```

另外會即時播報進行中的派遣：志工接單念「正在過來，大約 N 分鐘到」、到場念「到您家門口了」。

## 啟動

```bash
flutter pub get
flutter run -d chrome        # 麥克風要 HTTPS 或 localhost，其他網域拿不到權限
```

網址參數：`?elder=elder-1` 或 `?serial=JS-0001` 指定這台是誰的收音機；都沒帶就用清單第一位。

## 兩套環境

後端由 `--dart-define=BACKEND` 決定，切換點只有 `apps/packages/core` 的 `backend_factory.dart`
（見 [`docs/requirements/aws-handoff.md`](../../docs/requirements/aws-handoff.md)）。

| | Supabase（正式） | AWS（平行環境） |
|---|---|---|
| 資料層 | Supabase Realtime | API Gateway `/data/*`（3 秒輪詢） |
| 登入 | 不需要 | **需要**——Cognito 裝置帳號，開機自動登入 |
| ASR | `whisper` Edge Function | `POST /asr`（`jinsun-voice` Lambda 代理） |
| TTS | `/tts` 代理 ATEN | 未接，自動退回瀏覽器語音 |

AWS 版要多帶裝置帳密（長輩不可能自己登入，所以在 build 時注入）：

```bash
flutter build web --release \
  --dart-define=BACKEND=aws \
  --dart-define=AWS_API_BASE=https://xxxx.execute-api.us-west-2.amazonaws.com \
  --dart-define=COGNITO_CLIENT_ID=xxxx \
  --dart-define=ELDER_DEVICE_USER=device-js-0001@jinsun.local \
  --dart-define=ELDER_DEVICE_PASS=...
```

平常不用手打，`bash deploy/aws/deploy-web.sh` 會帶好（AWS 站台）、
`bash deploy/deploy-all.sh` 會部署 Vercel 那套。

一個裝置帳號只綁一位長輩，所以這台在後端只看得到那一位——一台收音機就是一位長輩的，
看得到別人是授權破口。要再開一台就另建帳號並重 build 一份站台。
