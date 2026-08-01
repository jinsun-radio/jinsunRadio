#!/usr/bin/env bash
# 首次部署：上傳模型 + code → create-model → create-endpoint-config → create-endpoint。
# 已存在的 endpoint 請改用 redeploy.sh（只重傳 code，不動 2.9GB 權重）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

require_role

VER="${1:-v1}"
NAME="$ENDPOINT_NAME-$VER"
S3URI="s3://$BUCKET/$PREFIX/"

sz=$(stat -f%z "$ROOT/model/model.bin" 2>/dev/null || stat -c%s "$ROOT/model/model.bin" 2>/dev/null || echo 0)
[ "$sz" -eq "$MODEL_BIN_BYTES" ] || { echo "model/ 尚未備妥，先跑 scripts/fetch-model.sh" >&2; exit 1; }

echo "==> 上傳到 $S3URI（3GB，首次約 5-6 分鐘）"
aws s3 sync "$ROOT/model/" "$S3URI""model/" --only-show-errors
aws s3 sync "$ROOT/src/"   "$S3URI""code/"  --only-show-errors

echo "==> create-model $NAME"
aws sagemaker create-model --model-name "$NAME" \
  --execution-role-arn "$SAGEMAKER_ROLE_ARN" \
  --primary-container "$(container_json "$S3URI")" \
  --output text --query ModelArn

echo "==> create-endpoint-config"
aws sagemaker create-endpoint-config --endpoint-config-name "$NAME-cfg" \
  --production-variants "$(variant_json "$NAME")" --output text --query EndpointConfigArn

echo "==> create-endpoint $ENDPOINT_NAME（$INSTANCE_TYPE，開始計費）"
aws sagemaker create-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --endpoint-config-name "$NAME-cfg" --output text --query EndpointArn

echo "==> 等 InService（image pull + pip install + 3GB 載入，約 8-15 分鐘）"
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME" || true
aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --query '{Status:EndpointStatus,Reason:FailureReason}' --output json

echo
echo "測試：scripts/test.sh samples/*.wav"
echo "用完務必砍掉：scripts/teardown.sh（$INSTANCE_TYPE 是持續計費）"
