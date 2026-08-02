#!/usr/bin/env bash
# 把 SageMaker 的 breeze-asr-26 endpoint 開成可以 curl 的 OpenAI REST API：
#   POST /v1/audio/transcriptions   （OpenAI 相容，multipart/form-data）
#   GET  /v1/models                 （OpenAI 相容工具啟動時常會先打這支）
#
# 背景：SageMaker 傳輸層強制 SigV4 簽章，所以 endpoint 本身不能直接 curl，
# 也不能讓 HUB8735 直連。這支腳本部署 jinsun-asr-openai Lambda 當「重新簽章、
# 原封轉發」的門面，掛在既有的 jinsun-voice-api 上（跟 /voice、/tts 同一個網域）。
#
# endpoint 內部已經是 OpenAI 形狀（cloud/asr-sagemaker/src/inference.py），
# 所以 Lambda 不解析 body，這裡也就不需要任何 payload 對映設定。
#
# 用法：
#   bash cloud/aws/scripts/deploy-asr-openai.sh
#   ASR_API_KEY=sk-xxx bash cloud/aws/scripts/deploy-asr-openai.sh   # 指定金鑰
#
# 金鑰處理：沒指定就沿用 Lambda 上已存在的那把；還沒有的話自動產一把並印出來。
# 因此重複執行不會把既有金鑰換掉（換掉的話韌體與 server 會同時斷線）。
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
API_NAME="${API_NAME:-jinsun-voice-api}"
FN="${FN:-jinsun-asr-openai}"
ROLE_NAME="${ROLE_NAME:-JinsunAsrOpenaiLambdaRole}"
ENDPOINT_NAME="${ASR_ENDPOINT_NAME:-breeze-asr-26}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ─── ⓪ 先確認 endpoint 真的在 ────────────────────────────────────────
# 這層代理沒有 endpoint 就只是個會回 503 的殼。先講清楚比部署完才發現好。
say "⓪ SageMaker endpoint $ENDPOINT_NAME"
EP_STATUS="$(aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --region "$REGION" --query EndpointStatus --output text 2>/dev/null || echo MISSING)"
echo "   狀態：$EP_STATUS"
if [ "$EP_STATUS" != "InService" ]; then
  echo "   ⚠️  endpoint 不在 InService —— 代理仍會部署，但呼叫會回 503。"
  echo "      重建：cd cloud/asr-sagemaker && scripts/deploy.sh"
fi

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

# 只給這一顆 endpoint 的 InvokeEndpoint。別放寬成 "*"：這支是對外開放的路由，
# 萬一金鑰外流，權限範圍就是唯一的第二道防線。
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name jinsun-asr-openai-inline \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"sagemaker:InvokeEndpoint\"],
      \"Resource\":\"arn:aws:sagemaker:${REGION}:${ACCOUNT}:endpoint/${ENDPOINT_NAME}\"
    }]
  }" >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# ─── ② 金鑰 ─────────────────────────────────────────────────────────
say "② API 金鑰"
EXISTING_KEY="$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
  --query 'Environment.Variables.ASR_API_KEY' --output text 2>/dev/null || echo None)"
if [ -n "${ASR_API_KEY:-}" ]; then
  KEY="$ASR_API_KEY"; echo "   用指定的金鑰"
elif [ "$EXISTING_KEY" != "None" ] && [ -n "$EXISTING_KEY" ]; then
  KEY="$EXISTING_KEY"; echo "   沿用 Lambda 上既有的金鑰（未變更）"
else
  # 用 openssl 而不是 `tr -dc … </dev/urandom | head -c 32`：head 讀滿就關管線，
  # tr 收到 SIGPIPE 回非零 → 在 set -o pipefail 下會把整個腳本中止。
  KEY="sk-jinsun-$(openssl rand -hex 16)"
  echo "   產生新金鑰"
fi

# ─── ③ 打包並部署 Lambda ────────────────────────────────────────────
say "③ Lambda $FN"
bash "$ROOT/cloud/aws/scripts/build.sh" asr-openai
ZIP="$ROOT/cloud/aws/.build/asr-openai.zip"
ENVVARS="Variables={ASR_ENDPOINT_NAME=${ENDPOINT_NAME},ASR_API_KEY=${KEY},ASR_MODEL_ID=${ENDPOINT_NAME}}"

# timeout 29 秒：API Gateway HTTP API 的整合逾時上限是 30 秒，設更長沒有意義
# （閘道會先斷，Lambda 還在跑就變成付錢買一個沒人收的結果）。
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file "fileb://${ZIP}" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "$ENVVARS" --timeout 29 --memory-size 1024 >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  echo "   更新"
else
  aws lambda create-function --function-name "$FN" --region "$REGION" \
    --runtime nodejs22.x --handler index.handler --role "$ROLE_ARN" \
    --zip-file "fileb://${ZIP}" --environment "$ENVVARS" \
    --timeout 29 --memory-size 1024 >/dev/null
  aws lambda wait function-active-v2 --function-name "$FN" --region "$REGION"
  echo "   建立"
fi
FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"

# ─── ④ API Gateway 路由 ─────────────────────────────────────────────
say "④ API Gateway 路由"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
[ "$API_ID" = "None" ] && { echo "找不到 API $API_NAME"; exit 1; }

INT_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='${FN_ARN}'].IntegrationId | [0]" --output text)"
if [ "$INT_ID" = "None" ] || [ -z "$INT_ID" ]; then
  INT_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" --region "$REGION" \
    --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
    --payload-format-version 2.0 --query IntegrationId --output text)"
  echo "   建立 integration $INT_ID"
else
  echo "   沿用 integration $INT_ID"
fi

# 明確路由優先於 $default（$default 是 jinsun-voice），所以這幾條不會被吃掉。
# authorizer 一律 NONE：驗證在 Lambda 裡用 Bearer 金鑰做，跟 OpenAI 的慣例一致，
# 而不是 Cognito —— 呼叫方是韌體與 server，不是登入中的人。
for RK in 'POST /v1/audio/transcriptions' 'OPTIONS /v1/audio/transcriptions' 'GET /v1/models'; do
  EXIST="$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${RK}'].RouteId | [0]" --output text)"
  if [ "$EXIST" = "None" ] || [ -z "$EXIST" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --region "$REGION" \
      --route-key "$RK" --target "integrations/${INT_ID}" \
      --authorization-type NONE >/dev/null
    echo "   建立路由 $RK"
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$EXIST" --region "$REGION" \
      --target "integrations/${INT_ID}" --authorization-type NONE >/dev/null
    echo "   更新路由 $RK"
  fi
done

aws lambda add-permission --function-name "$FN" --region "$REGION" \
  --statement-id apigw-asr-openai --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*" >/dev/null 2>&1 || true

BASE="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
say "完成"
echo "OPENAI_BASE_URL=${BASE}/v1"
echo "OPENAI_API_KEY=${KEY}"
echo
echo "自我檢查（用 repo 內附的測試語音）："
echo "  curl -s -X POST ${BASE}/v1/audio/transcriptions \\"
echo "    -H 'Authorization: Bearer ${KEY}' \\"
echo "    -F 'file=@cloud/asr-sagemaker/samples/sos.wav' \\"
echo "    -F 'model=${ENDPOINT_NAME}'"
echo
echo "OpenAI Python SDK："
echo "  client = OpenAI(base_url='${BASE}/v1', api_key='${KEY}')"
echo "  client.audio.transcriptions.create(model='${ENDPOINT_NAME}', file=open('sos.wav','rb'))"
echo
echo "⚠️ 音檔上限 4.5MB（約 2 分鐘 16kHz mono）—— Lambda 同步 payload 6MB 扣掉 base64 膨脹。"
echo "⚠️ endpoint 是 GPU 機型（ml.g4dn.xlarge）持續計費，不用時記得 cloud/asr-sagemaker/scripts/teardown.sh。"
