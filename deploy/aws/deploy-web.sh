#!/usr/bin/env bash
# 一鍵部署三端 Flutter Web 到 AWS S3 + CloudFront。
#
# 前提：
#   1. 已安裝 aws CLI 並設好 credentials
#   2. 已安裝 flutter SDK
#   3. CloudFront distributions 需先建好（首次用 setup-cloudfront.sh 或手動）
#
# 用法：
#   export SERVER_URL=https://xxxxx.awsapprunner.com   # 語音 server 網址
#   bash deploy/aws/deploy-web.sh
#
# 可用環境變數覆蓋：
#   AWS_REGION             預設 us-west-2
#   BUCKET_FAMILY          預設 jinsun-family-web
#   BUCKET_VOLUNTEER       預設 jinsun-volunteer-web
#   BUCKET_ADMIN           預設 jinsun-admin-web
#   CF_DIST_FAMILY         CloudFront Distribution ID（家屬）
#   CF_DIST_VOLUNTEER      CloudFront Distribution ID（志工）
#   CF_DIST_ADMIN          CloudFront Distribution ID（社工）
#   SERVER_URL             語音 server 的公開 HTTPS 網址（admin 需要）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ─── 設定 ───────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-west-2}"
BUCKET_FAMILY="${BUCKET_FAMILY:-jinsun-family-web}"
BUCKET_VOLUNTEER="${BUCKET_VOLUNTEER:-jinsun-volunteer-web}"
BUCKET_ADMIN="${BUCKET_ADMIN:-jinsun-admin-web}"
SERVER_URL="${SERVER_URL:-}"

if [ -z "${SERVER_URL}" ]; then
  echo "⚠️  SERVER_URL 未設定。社工後台的「硬體模擬」頁將無法連到語音 server。"
  echo "   繼續部署？(y/N)"
  read -r confirm
  [ "${confirm}" != "y" ] && exit 1
fi

# ─── 確保 S3 buckets 存在（靜態網站託管）────────────────────────────
ensure_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    echo "   建立 S3 bucket: ${bucket}"
    aws s3 mb "s3://${bucket}" --region "${REGION}"
    # 開啟靜態網站託管
    aws s3 website "s3://${bucket}" --index-document index.html --error-document index.html
  else
    echo "   Bucket ${bucket} 已存在 ✓"
  fi

  # 關閉 Block Public Access（S3 預設會擋公開存取）
  aws s3api put-public-access-block \
    --bucket "${bucket}" \
    --public-access-block-configuration '{
      "BlockPublicAcls": false,
      "IgnorePublicAcls": false,
      "BlockPublicPolicy": false,
      "RestrictPublicBuckets": false
    }' \
    --region "${REGION}" 2>/dev/null

  # 設定 Bucket Policy 允許公開讀取
  aws s3api put-bucket-policy \
    --bucket "${bucket}" \
    --policy "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"PublicReadGetObject\",
        \"Effect\": \"Allow\",
        \"Principal\": \"*\",
        \"Action\": \"s3:GetObject\",
        \"Resource\": \"arn:aws:s3:::${bucket}/*\"
      }]
    }" \
    --region "${REGION}" 2>/dev/null
}

echo "① 確認 S3 buckets..."
ensure_bucket "${BUCKET_FAMILY}"
ensure_bucket "${BUCKET_VOLUNTEER}"
ensure_bucket "${BUCKET_ADMIN}"

# ─── Flutter build ───────────────────────────────────────────────────
build_app() {
  local dir="$1" name="$2" extra="${3:-}"
  echo ""
  echo "▶ [$name] flutter build web ${extra}..."
  (cd "${dir}" && flutter build web --release ${extra})
}

echo ""
echo "② Flutter build..."
build_app "${ROOT}/apps/family_app"    "family"
build_app "${ROOT}/apps/volunteer_app" "volunteer"
build_app "${ROOT}/admin"              "admin" \
  "--dart-define=SIM_BASE=${SERVER_URL}"

# ─── Sync to S3 ─────────────────────────────────────────────────────
sync_app() {
  local dir="$1" bucket="$2" name="$3"
  echo ""
  echo "▶ [$name] 同步到 s3://${bucket}..."
  aws s3 sync "${dir}/build/web" "s3://${bucket}/" \
    --delete \
    --cache-control "public, max-age=3600" \
    --region "${REGION}"
  # index.html 不要快取（每次部署立即生效）
  aws s3 cp "${dir}/build/web/index.html" "s3://${bucket}/index.html" \
    --cache-control "no-cache, no-store, must-revalidate" \
    --content-type "text/html" \
    --region "${REGION}"
}

echo ""
echo "③ Sync to S3..."
sync_app "${ROOT}/apps/family_app"    "${BUCKET_FAMILY}"    "family"
sync_app "${ROOT}/apps/volunteer_app" "${BUCKET_VOLUNTEER}" "volunteer"
sync_app "${ROOT}/admin"              "${BUCKET_ADMIN}"     "admin"

# ─── CloudFront invalidation（如有設定）─────────────────────────────
invalidate() {
  local dist_id="$1" name="$2"
  if [ -n "${dist_id}" ]; then
    echo "   [$name] CloudFront invalidation..."
    aws cloudfront create-invalidation \
      --distribution-id "${dist_id}" \
      --paths "/*" \
      --region "${REGION}" \
      --output text
  fi
}

echo ""
echo "④ CloudFront cache invalidation..."
invalidate "${CF_DIST_FAMILY:-}"    "family"
invalidate "${CF_DIST_VOLUNTEER:-}" "volunteer"
invalidate "${CF_DIST_ADMIN:-}"     "admin"

if [ -z "${CF_DIST_FAMILY:-}" ]; then
  echo "   ⚠️  未設定 CF_DIST_* 環境變數，跳過 CloudFront invalidation。"
  echo "   首次部署請先建立 CloudFront distributions（見 deploy/aws/setup-cloudfront.sh）。"
fi

# ─── 結果 ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "✅ 三端 Flutter Web 部署完成！"
echo ""
echo "S3 靜態網站網址（HTTP，開發用）："
echo "  家屬  http://${BUCKET_FAMILY}.s3-website-${REGION}.amazonaws.com"
echo "  志工  http://${BUCKET_VOLUNTEER}.s3-website-${REGION}.amazonaws.com"
echo "  社工  http://${BUCKET_ADMIN}.s3-website-${REGION}.amazonaws.com"
echo ""
if [ -n "${CF_DIST_FAMILY:-}" ]; then
  echo "CloudFront（HTTPS，正式用）：請到 CloudFront console 查看 domain。"
fi
echo ""
echo "Demo 參數："
echo "  家屬 ?demo=1（自動登入）、?demo=fall（自動演跌倒）"
echo "  志工 ?demo=sos"
echo "  後台 #admin"
echo "═══════════════════════════════════════════════════"
