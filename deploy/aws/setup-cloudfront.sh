#!/usr/bin/env bash
# 為四端各建一個 CloudFront distribution（S3 靜態網站 → HTTPS）。
#
# 為什麼一定要 CloudFront 而不是直接用 S3 網址：
#   1. S3 靜態網站端點只有 HTTP。**Flutter Web 在非 HTTPS 下拿不到定位權限**
#      （志工端的 GPS 上報、家屬地圖的志工位置全部會失效），麥克風也一樣
#      —— 長輩端的「按住說話」大按鈕就是麥克風，沒有 HTTPS 等於整台收音機是啞的。
#   2. SPA fallback：Flutter 的前端路由需要 403/404 都回 index.html。
#
# 用法：bash deploy/aws/setup-cloudfront.sh
# 產出：印出四個 distribution id 與網域，填進 deploy-web.sh 的 CF_DIST_* 環境變數。
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
BUCKET_FAMILY="${BUCKET_FAMILY:-jinsun-family-web}"
BUCKET_VOLUNTEER="${BUCKET_VOLUNTEER:-jinsun-volunteer-web}"
BUCKET_ADMIN="${BUCKET_ADMIN:-jinsun-admin-web}"
BUCKET_ELDER="${BUCKET_ELDER:-jinsun-elder-web}"

# 用 S3 的「網站端點」當 custom origin（不是 REST 端點）——網站端點才會處理
# 目錄索引（/ → index.html）。因此 origin protocol 只能是 http-only，這是 S3 的限制；
# 使用者到 CloudFront 那一段仍是 HTTPS。
origin_domain() { echo "$1.s3-website-${REGION}.amazonaws.com"; }

make_dist() {
  local bucket="$1" label="$2"
  # macOS 內建 bash 是 3.2，沒有 ${var^^}，只能用 tr
  local upper; upper="$(echo "$label" | tr '[:lower:]' '[:upper:]')"
  local existing
  existing="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='jinsun-${label}'].Id | [0]" \
    --output text 2>/dev/null || echo None)"
  if [ "$existing" != "None" ] && [ -n "$existing" ]; then
    local domain
    domain="$(aws cloudfront get-distribution --id "$existing" \
      --query 'Distribution.DomainName' --output text)"
    echo "   已存在 ${label}: ${existing}  https://${domain}"
    eval "CF_${upper}=${existing}"
    return
  fi

  local config
  config="$(cat <<JSON
{
  "CallerReference": "jinsun-${label}-$(date +%s)",
  "Comment": "jinsun-${label}",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "s3-website",
      "DomainName": "$(origin_domain "$bucket")",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-website",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {"ErrorCode": 403, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 0},
      {"ErrorCode": 404, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 0}
    ]
  }
}
JSON
)"
  local out id domain
  out="$(aws cloudfront create-distribution --distribution-config "$config" \
    --query '[Distribution.Id, Distribution.DomainName]' --output text)"
  id="$(echo "$out" | cut -f1)"
  domain="$(echo "$out" | cut -f2)"
  echo "   建立 ${label}: ${id}  https://${domain}"
  eval "CF_${upper}=${id}"
}

echo "① 確認 S3 buckets 已存在（deploy-web.sh 會建）..."
for b in "$BUCKET_FAMILY" "$BUCKET_VOLUNTEER" "$BUCKET_ADMIN" "$BUCKET_ELDER"; do
  aws s3api head-bucket --bucket "$b" 2>/dev/null || {
    echo "   ⚠️  找不到 bucket $b —— 請先跑一次 deploy/aws/deploy-web.sh"; exit 1; }
done

echo "② CloudFront distributions（建立後約 5–10 分鐘才會 Deployed）..."
make_dist "$BUCKET_FAMILY"    "family"
make_dist "$BUCKET_VOLUNTEER" "volunteer"
make_dist "$BUCKET_ADMIN"     "admin"
make_dist "$BUCKET_ELDER"     "elder"

cat <<EOF

把這幾行加進部署環境，之後 deploy-web.sh 就會自動做 cache invalidation：

export CF_DIST_FAMILY=${CF_FAMILY:-}
export CF_DIST_VOLUNTEER=${CF_VOLUNTEER:-}
export CF_DIST_ADMIN=${CF_ADMIN:-}
export CF_DIST_ELDER=${CF_ELDER:-}
EOF
