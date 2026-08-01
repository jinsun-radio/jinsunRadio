#!/usr/bin/env bash
# 為「語音 Agent server（ALB，HTTP:80）」建一個 CloudFront distribution，
# 讓 https 網頁（家屬／長輩／後台）能跨到 server —— 否則 https 頁呼叫 http ALB
# 會被瀏覽器擋成 mixed content（家屬「立即提醒」按鈕、長輩收音機 /commands、
# /voice、/tts 全部會失敗）。
#
# 為什麼要 CloudFront：ALB 的原生網址是 *.elb.amazonaws.com，拿不到公有 TLS 憑證，
# 無法直接開 https listener。CloudFront 提供免費的 *.cloudfront.net https 網域，
# 觀眾端走 https、回源到 ALB 走 http（API 不快取、轉發全部 method/header/query/body）。
#
# 用法：
#   bash deploy/aws/setup-server-cloudfront.sh
# 產出：印出 https://xxxx.cloudfront.net —— 這就是網頁要用的 SERVER_URL（SIM_BASE）。
#
# 前提：deploy/aws/deploy-server.sh 已跑過（ALB 存在、/remind 已在 ECS 上）。
set -euo pipefail

# ALB 對外網址（deploy-server.sh 印出的 ALB URL 的 host 部分）。換 server 用 ALB_DNS 覆蓋。
ALB_DNS="${ALB_DNS:-jinsun-alb-1316925531.us-west-2.elb.amazonaws.com}"
LABEL="${LABEL:-jinsun-voice-server}"

# CloudFront 受管政策（全 region 共用固定 ID）：
#   CachingDisabled            —— API 不快取
#   AllViewer（origin request）—— 轉發所有 header/query/cookie/body 給回源
CACHE_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
ALL_VIEWER="216adef6-5c7f-47e4-b989-5492eafa07d3"

existing="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${LABEL}'].Id | [0]" \
  --output text 2>/dev/null || echo None)"
if [ "$existing" != "None" ] && [ -n "$existing" ]; then
  domain="$(aws cloudfront get-distribution --id "$existing" \
    --query 'Distribution.DomainName' --output text)"
  echo "已存在 ${LABEL}: ${existing}"
  echo "SERVER_URL=https://${domain}"
  exit 0
fi

config="$(cat <<JSON
{
  "CallerReference": "${LABEL}-$(date +%s)",
  "Comment": "${LABEL}",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "alb",
      "DomainName": "${ALB_DNS}",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
        "OriginReadTimeout": 60,
        "OriginKeepaliveTimeout": 60
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}
    },
    "Compress": false,
    "CachePolicyId": "${CACHE_DISABLED}",
    "OriginRequestPolicyId": "${ALL_VIEWER}"
  }
}
JSON
)"

out="$(aws cloudfront create-distribution --distribution-config "$config" \
  --query '[Distribution.Id, Distribution.DomainName]' --output text)"
id="$(echo "$out" | cut -f1)"
domain="$(echo "$out" | cut -f2)"
echo "建立 ${LABEL}: ${id}"
echo ""
echo "⏳ CloudFront 約 5–10 分鐘才會 Deployed。之後這就是網頁要打的 server 網址："
echo ""
echo "   SERVER_URL=https://${domain}"
echo ""
echo "把它交給 web 端重新部署（家屬／長輩／後台的 SIM_BASE）即可，"
echo "「立即提醒」按鈕、/commands、/voice、/tts 就會通。"
