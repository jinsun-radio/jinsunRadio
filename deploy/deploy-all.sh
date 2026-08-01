#!/usr/bin/env bash
# 一鍵把三個 Flutter web App 部署到 Vercel（family / volunteer / admin）。
#
# 用法（二選一）：
#   1) export VERCEL_TOKEN=你的token; bash deploy/deploy-all.sh
#   2) vercel login   （互動登入一次）後直接 bash deploy/deploy-all.sh
#
# token 取得：vercel.com → 右上角頭像 → Settings → Tokens → Create
#
# 前提：三個 Vercel 專案（jinsun-family / jinsun-volunteer / jinsun-admin）
#       需已存在於 VERCEL_SCOPE 指定的 team 底下（第一次可先在 vercel.com 建、
#       或在各自 build/web 目錄手動跑一次 `vercel link`）。
#
# 部署後三個正式網址會被更新：
#   https://jinsun-family.vercel.app / -volunteer / -admin

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Vercel team scope（專案所在的團隊）。不同帳號改這裡或用 VERCEL_SCOPE 覆蓋。
SCOPE="${VERCEL_SCOPE:-auramakes-projects}"

TOKEN_ARG=""
[ -n "${VERCEL_TOKEN:-}" ] && TOKEN_ARG="--token=${VERCEL_TOKEN}"

# 社工後台的「硬體模擬」頁要打語音 server。部署後 admin 在別的網域，
# 必須在 build 時把 server 的公開網址帶進去（否則沒填就叫不到 server）。
# 預設用 AWS ECS Fargate ALB；換 server 時用 SERVER_URL=... 覆蓋。
SERVER_URL="${SERVER_URL:-http://jinsun-alb-1316925531.us-west-2.elb.amazonaws.com}"

deploy () {
  local dir="$1" name="$2" extra="${3:-}"
  echo ""
  echo "▶ [$name] flutter build web ${extra}..."
  ( cd "$dir" && flutter build web --release ${extra} )
  # SPA rewrite：所有路徑回 index.html（Flutter 前端路由）。
  cp "$ROOT/deploy/vercel.json" "$dir/build/web/vercel.json"
  echo "▶ [$name] 連結既有專案並部署到正式站 ..."
  (
    cd "$dir/build/web"
    # 注意：新版 vercel CLI（v55+）的 `--name` 已失效，直接 `vercel deploy <dir>`
    # 會建出以資料夾命名（web）的「新」專案、不會更新現有網址。
    # 正確作法：先 link 到「既有」專案，再 deploy --prod。
    vercel link --yes --project "$name" --scope "$SCOPE" ${TOKEN_ARG}
    vercel deploy --prod --yes --scope "$SCOPE" ${TOKEN_ARG}
  )
}

deploy "$ROOT/apps/family_app"    "jinsun-family"
deploy "$ROOT/apps/volunteer_app" "jinsun-volunteer"
deploy "$ROOT/admin"              "jinsun-admin" \
  "--dart-define=SIM_BASE=$SERVER_URL"
# 長輩端收音機網頁版：大錄音按鈕打 /voice、志工進度靠 Realtime → 需要 SIM_BASE。
deploy "$ROOT/apps/elder_app"     "jinsun-elder" \
  "--dart-define=SIM_BASE=$SERVER_URL"

echo ""
echo "✓ 四個 App 都部署完成："
echo "   家屬  https://jinsun-family.vercel.app"
echo "   志工  https://jinsun-volunteer.vercel.app"
echo "   社工  https://jinsun-admin.vercel.app"
echo "   長輩  https://jinsun-elder.vercel.app"
