#!/usr/bin/env bash
# 改了 src/ 之後滾動更新：只重傳 code/，S3 上的權重原封不動，再 update-endpoint 換新 instance。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

require_role

VER="${1:?用法：scripts/redeploy.sh <版本後綴，例如 v2>}"
NAME="$ENDPOINT_NAME-$VER"
S3URI="s3://$BUCKET/$PREFIX/"

echo "==> 只同步 code/（權重不動）"
aws s3 sync "$ROOT/src/" "$S3URI""code/" --only-show-errors

aws sagemaker create-model --model-name "$NAME" \
  --execution-role-arn "$SAGEMAKER_ROLE_ARN" \
  --primary-container "$(container_json "$S3URI")" \
  --output text --query ModelArn

aws sagemaker create-endpoint-config --endpoint-config-name "$NAME-cfg" \
  --production-variants "$(variant_json "$NAME")" --output text --query EndpointConfigArn

echo "==> update-endpoint → $NAME-cfg"
aws sagemaker update-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --endpoint-config-name "$NAME-cfg" --output text --query EndpointArn

aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME" || true
aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --query '{Status:EndpointStatus,Reason:FailureReason}' --output json
