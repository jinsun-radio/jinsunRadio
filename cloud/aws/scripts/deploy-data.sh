#!/usr/bin/env bash
# 部署三端 App 的資料 API：jinsun-data Lambda + API Gateway 路由 + Cognito JWT authorizer。
#
# 掛在既有的 `jinsun-voice-api` 上而不是另開一支 API：兩者共用同一個網域，
# App 只要記一個 API_BASE；而且 /voice（裝置，無認證）與 /data（三端，要 JWT）
# 路由分開設 authorizer，權限邊界一樣清楚。
#
# 前提：先跑 setup-cognito.sh 取得 POOL_ID / CLIENT_ID。
# 用法：
#   export COGNITO_POOL_ID=us-west-2_xxxx COGNITO_CLIENT_ID=xxxx
#   export AURORA_CLUSTER_ARN=... AURORA_SECRET_ARN=...
#   bash cloud/aws/scripts/deploy-data.sh
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
API_NAME="${API_NAME:-jinsun-voice-api}"
FN="${FN:-jinsun-data}"
ROLE_NAME="${ROLE_NAME:-JinsunDataLambdaRole}"
PROOFS_BUCKET="${PROOFS_BUCKET:-jinsun-proofs}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

: "${COGNITO_POOL_ID:?需要 COGNITO_POOL_ID（跑 setup-cognito.sh 取得）}"
: "${COGNITO_CLIENT_ID:?需要 COGNITO_CLIENT_ID}"
: "${AURORA_CLUSTER_ARN:?需要 AURORA_CLUSTER_ARN}"
: "${AURORA_SECRET_ARN:?需要 AURORA_SECRET_ARN}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ─── ① IAM role ─────────────────────────────────────────────────────
say "① IAM role $ROLE_NAME"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  echo "   建立"
  sleep 10   # IAM 傳播
else
  echo "   已存在"
fi

# 只給這支 Lambda 需要的四件事：Data API、讀那一把 secret、寫證明照片、
# 觸發進度播報（接單／抵達／座標變化 → jinsun-progress，見 lambda/data/ops.mjs）。
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name jinsun-data-inline \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["rds-data:ExecuteStatement","rds-data:BatchExecuteStatement"],
     "Resource":"${AURORA_CLUSTER_ARN}"},
    {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"${AURORA_SECRET_ARN}"},
    {"Effect":"Allow","Action":["s3:PutObject"],"Resource":"arn:aws:s3:::${PROOFS_BUCKET}/*"},
    {"Effect":"Allow","Action":["lambda:InvokeFunction"],
     "Resource":"arn:aws:lambda:${REGION}:${ACCOUNT}:function:jinsun-progress"}
  ]
}
JSON
)" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# ─── ② 結案證明照片的 bucket ────────────────────────────────────────
say "② S3 bucket $PROOFS_BUCKET"
if ! aws s3api head-bucket --bucket "$PROOFS_BUCKET" 2>/dev/null; then
  aws s3 mb "s3://${PROOFS_BUCKET}" --region "$REGION" >/dev/null
  # 家屬要看得到照片 → 物件層級公開讀；上傳一律走 presigned URL，寫入權沒放開。
  aws s3api put-public-access-block --bucket "$PROOFS_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" >/dev/null
  aws s3api put-bucket-policy --bucket "$PROOFS_BUCKET" --policy "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::${PROOFS_BUCKET}/*"}]}
JSON
)" >/dev/null
  aws s3api put-bucket-cors --bucket "$PROOFS_BUCKET" --cors-configuration \
    '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["PUT","GET"],"AllowedHeaders":["*"],"MaxAgeSeconds":3000}]}' >/dev/null
  echo "   建立"
else
  echo "   已存在"
fi

# ─── ③ 打包並部署 Lambda ────────────────────────────────────────────
say "③ Lambda $FN"
bash "$ROOT/cloud/aws/scripts/build.sh" data
ZIP="$ROOT/cloud/aws/.build/data.zip"
ENVVARS="Variables={AURORA_CLUSTER_ARN=${AURORA_CLUSTER_ARN},AURORA_SECRET_ARN=${AURORA_SECRET_ARN},AURORA_DB_NAME=${AURORA_DB_NAME:-jinsun},PROOFS_BUCKET=${PROOFS_BUCKET},PROOFS_PUBLIC_BASE=${PROOFS_PUBLIC_BASE:-https://${PROOFS_BUCKET}.s3.${REGION}.amazonaws.com}}"

if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://${ZIP}" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "$ENVVARS" --timeout 20 --memory-size 512 >/dev/null
  echo "   更新"
else
  aws lambda create-function --function-name "$FN" --region "$REGION" \
    --runtime nodejs22.x --handler index.handler --role "$ROLE_ARN" \
    --zip-file "fileb://${ZIP}" --environment "$ENVVARS" \
    --timeout 20 --memory-size 512 >/dev/null
  echo "   建立"
fi
FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"

# ─── ④ API Gateway：authorizer + 路由 ───────────────────────────────
say "④ API Gateway"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
[ "$API_ID" = "None" ] && { echo "找不到 API $API_NAME"; exit 1; }

ISSUER="https://cognito-idp.${REGION}.amazonaws.com/${COGNITO_POOL_ID}"
AUTH_ID="$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$REGION" \
  --query "Items[?Name=='jinsun-cognito'].AuthorizerId | [0]" --output text)"
if [ "$AUTH_ID" = "None" ] || [ -z "$AUTH_ID" ]; then
  AUTH_ID="$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --region "$REGION" \
    --name jinsun-cognito --authorizer-type JWT \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Audience=${COGNITO_CLIENT_ID},Issuer=${ISSUER}" \
    --query AuthorizerId --output text)"
  echo "   建立 authorizer $AUTH_ID"
else
  aws apigatewayv2 update-authorizer --api-id "$API_ID" --authorizer-id "$AUTH_ID" \
    --region "$REGION" --jwt-configuration "Audience=${COGNITO_CLIENT_ID},Issuer=${ISSUER}" >/dev/null
  echo "   更新 authorizer $AUTH_ID"
fi

# 重跑不要每次都長出一個新的 integration（會留下一堆孤兒）→ 先找同一個 URI 的。
INT_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='${FN_ARN}'].IntegrationId | [0]" --output text)"
if [ "$INT_ID" = "None" ] || [ -z "$INT_ID" ]; then
  INT_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" --region "$REGION" \
    --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
    --payload-format-version 2.0 --query IntegrationId --output text)"
  echo "   建立 integration $INT_ID"
fi

for RK in 'GET /data/snapshot' 'GET /data/version' 'GET /data/timebank' 'POST /data/mutate'; do
  EXIST="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${RK}'].RouteId | [0]" --output text)"
  if [ "$EXIST" = "None" ] || [ -z "$EXIST" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
      --route-key "$RK" --target "integrations/${INT_ID}" \
      --authorization-type JWT --authorizer-id "$AUTH_ID" >/dev/null
    echo "   建立路由 $RK"
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$EXIST" --region "$REGION" \
      --target "integrations/${INT_ID}" \
      --authorization-type JWT --authorizer-id "$AUTH_ID" >/dev/null
    echo "   更新路由 $RK"
  fi
done

# 三端是瀏覽器（CloudFront）→ 跨源。CORS 標頭由 API Gateway 自己補，
# 而且會在 authorizer 之前，OPTIONS 不會因為沒帶 token 被擋掉。
#
# ⚠️ 但 API Gateway 的「自動回應 preflight」只在**沒有任何路由 match** 時才啟動。
#    本 API 有一條 $default 路由（給 POST /voice），它會 match 掉所有請求，包含
#    OPTIONS /data/*——preflight 因此被轉進 jinsun-voice。所以光設 CORS 不夠，
#    jinsun-voice 的 handler 還要把 OPTIONS 回成 204（見 lambda/voice/index.mjs）。
#    症狀：curl 測 API 全過，瀏覽器卻連不上（preflight 收到非 2xx 就不送真正的請求）。
#    驗證：bash cloud/aws/scripts/smoke-test.sh 的第 3 項。
aws apigatewayv2 update-api --api-id "$API_ID" --region "$REGION" --cors-configuration '{
  "AllowOrigins": ["*"],
  "AllowMethods": ["GET", "POST", "OPTIONS"],
  "AllowHeaders": ["authorization", "content-type"],
  "MaxAge": 3600
}' >/dev/null || \
  echo "   ⚠️  CORS 設定失敗，請手動於 console 設定（Allow origins *、headers authorization/content-type）"

aws lambda add-permission --function-name "$FN" --region "$REGION" \
  --statement-id apigw-data --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*/data/*" >/dev/null 2>&1 || true

say "完成"
echo "API_BASE=https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "自我檢查（需帶 Cognito idToken）："
echo "  curl -s -H \"Authorization: Bearer \$ID_TOKEN\" \"https://${API_ID}.execute-api.${REGION}.amazonaws.com/data/version\""
