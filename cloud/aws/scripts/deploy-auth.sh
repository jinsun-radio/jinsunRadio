#!/usr/bin/env bash
# 部署 jinsun-auth（Cognito 的 PreSignUp / PostConfirmation 觸發器）。
#
# 必須先於 setup-cognito.sh 執行 —— 那支腳本會把這個 function 掛上 User Pool，
# function 不存在就只會印一行提示然後跳過。
#
# 用法：
#   export AURORA_CLUSTER_ARN=... AURORA_SECRET_ARN=...
#   bash cloud/aws/scripts/deploy-auth.sh
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
FN="${FN:-jinsun-auth}"
ROLE_NAME="${ROLE_NAME:-JinsunAuthLambdaRole}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

: "${AURORA_CLUSTER_ARN:?需要 AURORA_CLUSTER_ARN}"
: "${AURORA_SECRET_ARN:?需要 AURORA_SECRET_ARN}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

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

# 只給三件事：把使用者加進 group、寫 profiles、讀那一把 secret。
# 刻意不給 AdminCreateUser／AdminSetUserPassword ——這支 Lambda 沒有理由能憑空造帳號。
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name jinsun-auth-inline \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["cognito-idp:AdminAddUserToGroup"],"Resource":"*"},
    {"Effect":"Allow","Action":["rds-data:ExecuteStatement"],"Resource":"${AURORA_CLUSTER_ARN}"},
    {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"${AURORA_SECRET_ARN}"}
  ]
}
JSON
)" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

say "② Lambda $FN"
bash "$ROOT/cloud/aws/scripts/build.sh" auth
ZIP="$ROOT/cloud/aws/.build/auth.zip"
ENVVARS="Variables={AURORA_CLUSTER_ARN=${AURORA_CLUSTER_ARN},AURORA_SECRET_ARN=${AURORA_SECRET_ARN},AURORA_DB_NAME=${AURORA_DB_NAME:-jinsun}}"

if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://${ZIP}" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "$ENVVARS" --timeout 15 --memory-size 256 >/dev/null
  echo "   更新"
else
  aws lambda create-function --function-name "$FN" --region "$REGION" \
    --runtime nodejs22.x --handler index.handler --role "$ROLE_ARN" \
    --zip-file "fileb://${ZIP}" --environment "$ENVVARS" \
    --timeout 15 --memory-size 256 >/dev/null
  echo "   建立"
fi

say "完成 —— 接著跑 cloud/aws/scripts/setup-cognito.sh"
