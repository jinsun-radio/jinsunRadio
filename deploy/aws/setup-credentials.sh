#!/usr/bin/env bash
# 設定 AWS credentials 給部署腳本用。
#
# ═══ 使用方式 ═══
#
# 方式 1：Workshop 一時憑證（有 session token，會過期）
#   從 Workshop Event Dashboard 複製「Credentials」區塊的三行 export，
#   貼進 terminal 跑完後，再跑部署腳本：
#
#   export AWS_ACCESS_KEY_ID="ASIA..."
#   export AWS_SECRET_ACCESS_KEY="..."
#   export AWS_SESSION_TOKEN="..."
#   export AWS_DEFAULT_REGION="us-west-2"
#   bash deploy/aws/deploy-server.sh
#
# 方式 2：IAM 長期憑證（不會過期，正式環境）
#   aws configure
#   bash deploy/aws/deploy-server.sh
#
# 方式 3：用本腳本互動式設定（把你的 credentials 寫到 ~/.aws/credentials）
#   bash deploy/aws/setup-credentials.sh
#   bash deploy/aws/deploy-server.sh
#
# ═════════════════

set -euo pipefail

echo "═══════════════════════════════════════════════════"
echo "  AWS Credentials 設定（給金孫 ECS 部署用）"
echo "═══════════════════════════════════════════════════"
echo ""

# 先檢查是否已有有效 credentials
if aws sts get-caller-identity > /dev/null 2>&1; then
  IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null)
  ACCOUNT=$(echo "${IDENTITY}" | grep -o '"Account": *"[^"]*"' | cut -d'"' -f4)
  ARN=$(echo "${IDENTITY}" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
  echo "✅ 已有有效的 AWS credentials！"
  echo "   Account: ${ACCOUNT}"
  echo "   Identity: ${ARN}"
  echo ""
  echo "直接跑部署即可："
  echo "   bash deploy/aws/deploy-server.sh"
  exit 0
fi

echo "目前沒有有效的 AWS credentials。"
echo ""
echo "請選擇設定方式："
echo "  [1] Workshop 一時憑證（貼 3 行 export）"
echo "  [2] IAM 長期憑證（跑 aws configure）"
echo ""
read -rp "選擇 (1/2): " choice

case "${choice}" in
  1)
    echo ""
    echo "請從 Workshop Dashboard 複製 Credentials 區塊，"
    echo "貼到 terminal 執行（3~4 行 export AWS_...），"
    echo "然後重新跑本腳本或直接跑："
    echo ""
    echo "   bash deploy/aws/deploy-server.sh"
    echo ""
    echo "範例："
    echo '   export AWS_ACCESS_KEY_ID="ASIA..."'
    echo '   export AWS_SECRET_ACCESS_KEY="..."'
    echo '   export AWS_SESSION_TOKEN="..."'
    echo '   export AWS_DEFAULT_REGION="us-west-2"'
    ;;
  2)
    echo ""
    aws configure
    echo ""
    echo "設定完成！現在可以跑："
    echo "   bash deploy/aws/deploy-server.sh"
    ;;
  *)
    echo "無效選擇，結束。"
    exit 1
    ;;
esac
