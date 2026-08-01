#!/usr/bin/env bash
# 金孫收音機 · 一鍵起 demo（雲端 server + 硬體模擬後台 + 三端 App）
# 用法：./run-demo.sh        （Ctrl-C 停全部）
# 前置：cloud/prototype/.env 要有 AWS + Supabase 憑證（Bedrock 已接）。
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "① 雲端語音 server + 進度 worker（:8787，含硬體模擬後台）"
( cd "$ROOT/cloud/prototype" && node --env-file=.env src/server.js ) &
SV=$!

echo "② 家屬 App（:5011）  ③ 志工 App（:5012）  ④ 社工後台（:5013）"
( cd "$ROOT/apps/family_app"   && flutter run -d web-server --web-port 5011 --web-hostname 0.0.0.0 ) &
( cd "$ROOT/apps/volunteer_app" && flutter run -d web-server --web-port 5012 --web-hostname 0.0.0.0 ) &
( cd "$ROOT/admin"             && flutter run -d web-server --web-port 5013 --web-hostname 0.0.0.0 ) &

trap 'echo "停止…"; kill $(jobs -p) 2>/dev/null; exit 0' INT TERM

cat <<'URLS'

────────────────────────────────────────────────────────
  🔧 硬體模擬後台   http://localhost:8787/__sim-4f9a2c
  👪 家屬 App        http://localhost:5011
  🙋 志工 App        http://localhost:5012/?demo   （?demo 自動登入）
  🗂️  社工後台        http://localhost:5013
────────────────────────────────────────────────────────
  三端共用同一個真 Supabase；後台觸發事件 → 三端即時亮。
  首次開 App 需等 Flutter web 編譯（約 30–60 秒）。
────────────────────────────────────────────────────────
URLS

wait $SV
