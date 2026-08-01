#!/usr/bin/env bash
# 部署國語 TTS：jinsun-tts Lambda（Amazon Polly）+ API Gateway 的 POST /tts 路由。
#
# 背景：裝置端原本只接 ATEN TTS，而**那是台語模型**、端點又不吃 voice/lang 參數，
# 所以 `lang=mandarin` 一直被念成台語。這支補上國語，讓 speak 的 lang 旗標真的分流。
#
# 掛在既有的 `jinsun-voice-api` 上（跟 /voice、/data 同一個網域），韌體只要記一個 host。
# 路由**不設 authorizer**——呼叫方是收音機，跟 /voice 同一個信任邊界。
#
# 用法：bash cloud/aws/scripts/deploy-tts.sh
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
API_NAME="${API_NAME:-jinsun-voice-api}"
FN="${FN:-jinsun-tts}"
ROLE_NAME="${ROLE_NAME:-JinsunTtsLambdaRole}"
POLLY_VOICE="${POLLY_VOICE:-Zhiyu}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

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

# 只要合成語音這一件事。SynthesizeSpeech 沒有資源層級權限，只能給 "*"。
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name jinsun-tts-inline \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["polly:SynthesizeSpeech"],"Resource":"*"}]
  }' >/dev/null
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# ─── ② 打包並部署 Lambda ────────────────────────────────────────────
say "② Lambda $FN"
bash "$ROOT/cloud/aws/scripts/build.sh" tts
ZIP="$ROOT/cloud/aws/.build/tts.zip"
ENVVARS="Variables={POLLY_VOICE=${POLLY_VOICE}}"

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

# ─── ③ API Gateway 路由 ─────────────────────────────────────────────
say "③ API Gateway POST /tts"
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
fi

# 明確路由優先於 $default（$default 是 jinsun-voice），所以 /tts 不會被吃掉。
for RK in 'POST /tts' 'OPTIONS /tts'; do
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
  --statement-id apigw-tts --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*/tts" >/dev/null 2>&1 || true

URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/tts"
say "完成"
echo "TTS_URL=${URL}"
echo
echo "自我檢查 ① 韌體形式（Accept: audio/wav → 直接回 WAV bytes；macOS 用 afplay 聽）："
echo "  curl -s -X POST ${URL} -H 'content-type: application/json' -H 'accept: audio/wav' \\"
echo "    -d '{\"text\":\"阿嬤，志工大約八分鐘就到，您再等一下喔。\"}' -o /tmp/tts.wav \\"
echo "    && file /tmp/tts.wav && afplay /tmp/tts.wav"
echo
echo "自我檢查 ② 網頁版形式（沒有 Accept → 回 {status,url}，url 是 data:audio/mpeg）："
echo "  curl -s -X POST ${URL} -H 'content-type: application/json' \\"
echo "    -d '{\"text\":\"測試\"}' | head -c 120"
echo
echo "⚠️ ① 若回的是 JSON 而不是二進位，代表 Accept 標頭沒送到 —— 韌體那條路會退回 ATEN（講台語）。"
