#!/usr/bin/env bash
# 砍掉 endpoint 停止計費，並清掉所有版本的 endpoint-config 與 model。
# 預設保留 S3 上的權重（下次 deploy 可省 3GB 上傳）；加 --purge-s3 一併刪除。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

echo "==> delete-endpoint $ENDPOINT_NAME"
aws sagemaker delete-endpoint --endpoint-name "$ENDPOINT_NAME" 2>/dev/null || echo "   （不存在，略過）"

for cfg in $(aws sagemaker list-endpoint-configs --name-contains "$ENDPOINT_NAME" \
             --query 'EndpointConfigs[].EndpointConfigName' --output text); do
  echo "==> delete-endpoint-config $cfg"
  aws sagemaker delete-endpoint-config --endpoint-config-name "$cfg"
done

for m in $(aws sagemaker list-models --name-contains "$ENDPOINT_NAME" \
           --query 'Models[].ModelName' --output text); do
  echo "==> delete-model $m"
  aws sagemaker delete-model --model-name "$m"
done

if [ "${1:-}" = "--purge-s3" ]; then
  echo "==> 刪除 s3://$BUCKET/$PREFIX/"
  aws s3 rm "s3://$BUCKET/$PREFIX/" --recursive --only-show-errors
fi

echo "==> 完成。確認沒有殘留計費資源："
aws sagemaker list-endpoints --query 'Endpoints[].{Name:EndpointName,Status:EndpointStatus}' --output table
