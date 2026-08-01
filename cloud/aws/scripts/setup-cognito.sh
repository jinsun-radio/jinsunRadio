#!/usr/bin/env bash
# 建立三端 App 的身分系統：Cognito User Pool + 三個 Group + 兩個觸發器。
#
# 對應原環境的 Supabase Auth。刻意保留兩個「讓 UI 不必改」的行為：
#   1. 使用者名稱沿用 `{手機數字}@jinsun.local` 的映射（見 supabase_auth.dart 的 _emailOf）
#   2. 註冊完直接可登入（PreSignUp 自動確認），三端沒有「輸入驗證碼」畫面
#
# 角色＝Cognito Group。family / volunteer 可自助註冊；worker（社工）只能由管理者手動加：
#   aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL_ID" \
#     --username 0933222333@jinsun.local --group-name worker
#
# 用法：bash cloud/aws/scripts/setup-cognito.sh
# 產出：把印出來的 POOL_ID / CLIENT_ID 填進 deploy/aws/deploy-web.sh 的環境變數。
set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
POOL_NAME="${POOL_NAME:-jinsun-users}"
CLIENT_NAME="${CLIENT_NAME:-jinsun-apps}"
AUTH_FN="${AUTH_FN:-jinsun-auth}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ─── ① User Pool ────────────────────────────────────────────────────
say "① User Pool"
POOL_ID="$(aws cognito-idp list-user-pools --max-results 60 --region "$REGION" \
  --query "UserPools[?Name=='${POOL_NAME}'].Id | [0]" --output text)"

if [ "$POOL_ID" = "None" ] || [ -z "$POOL_ID" ]; then
  POOL_ID="$(aws cognito-idp create-user-pool \
    --pool-name "$POOL_NAME" \
    --region "$REGION" \
    --username-attributes email \
    --auto-verified-attributes email \
    --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":false,"RequireLowercase":false,"RequireNumbers":false,"RequireSymbols":false}}' \
    --schema \
      'Name=name,AttributeDataType=String,Mutable=true,Required=false' \
      'Name=role,AttributeDataType=String,Mutable=true,Required=false,DeveloperOnlyAttribute=false' \
    --query 'UserPool.Id' --output text)"
  echo "   建立 $POOL_ID"
else
  echo "   已存在 $POOL_ID"
fi

# ─── ② 三個 Group（＝角色）─────────────────────────────────────────
say "② Groups"
for g in family volunteer worker; do
  aws cognito-idp create-group --group-name "$g" --user-pool-id "$POOL_ID" \
    --region "$REGION" >/dev/null 2>&1 && echo "   建立 group $g" || echo "   group $g 已存在"
done

# ─── ③ App Client（公開、無 secret；Flutter Web 不能藏 secret）──────
say "③ App Client"
CLIENT_ID="$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --max-results 60 \
  --region "$REGION" --query "UserPoolClients[?ClientName=='${CLIENT_NAME}'].ClientId | [0]" --output text)"

if [ "$CLIENT_ID" = "None" ] || [ -z "$CLIENT_ID" ]; then
  # USER_PASSWORD_AUTH：App 直接用帳密換 token，不必帶 Amplify、不必做 SRP。
  # Flutter Web 是公開客戶端，本來就藏不住 secret，所以 --no-generate-secret。
  CLIENT_ID="$(aws cognito-idp create-user-pool-client \
    --user-pool-id "$POOL_ID" --client-name "$CLIENT_NAME" --region "$REGION" \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --read-attributes email name phone_number custom:role \
    --write-attributes email name phone_number custom:role \
    --access-token-validity 60 --id-token-validity 60 --refresh-token-validity 30 \
    --token-validity-units '{"AccessToken":"minutes","IdToken":"minutes","RefreshToken":"days"}' \
    --query 'UserPoolClient.ClientId' --output text)"
  echo "   建立 $CLIENT_ID"
else
  echo "   已存在 $CLIENT_ID"
fi

# ─── ④ 掛上觸發器 ──────────────────────────────────────────────────
say "④ Lambda 觸發器（PreSignUp 自動確認 / PostConfirmation 寫 profiles＋加 group）"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
AUTH_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${AUTH_FN}"

if aws lambda get-function --function-name "$AUTH_FN" --region "$REGION" >/dev/null 2>&1; then
  aws cognito-idp update-user-pool --user-pool-id "$POOL_ID" --region "$REGION" \
    --lambda-config "PreSignUp=${AUTH_ARN},PostConfirmation=${AUTH_ARN}" \
    --auto-verified-attributes email >/dev/null
  # 讓 Cognito 有權呼叫這支 Lambda（重複執行會回 ResourceConflict，忽略）
  aws lambda add-permission --function-name "$AUTH_FN" --region "$REGION" \
    --statement-id cognito-invoke --action lambda:InvokeFunction \
    --principal cognito-idp.amazonaws.com \
    --source-arn "arn:aws:cognito-idp:${REGION}:${ACCOUNT}:userpool/${POOL_ID}" >/dev/null 2>&1 || true
  echo "   已掛上 $AUTH_FN"
else
  echo "   ⚠️  找不到 Lambda $AUTH_FN —— 先跑："
  echo "       bash $ROOT/cloud/aws/scripts/build.sh auth"
  echo "       aws lambda create-function --function-name $AUTH_FN ...（見 cloud/aws/README.md）"
  echo "   然後重跑本腳本把觸發器掛上。"
fi

say "完成"
cat <<EOF
export COGNITO_POOL_ID=$POOL_ID
export COGNITO_CLIENT_ID=$CLIENT_ID
export COGNITO_ISSUER=https://cognito-idp.${REGION}.amazonaws.com/${POOL_ID}

建立第一個社工帳號（worker 不能自助註冊）：
  aws cognito-idp admin-create-user --user-pool-id $POOL_ID \\
    --username 0933222333@jinsun.local --message-action SUPPRESS \\
    --user-attributes Name=email,Value=0933222333@jinsun.local Name=email_verified,Value=true Name=name,Value=王淑芬
  aws cognito-idp admin-set-user-password --user-pool-id $POOL_ID \\
    --username 0933222333@jinsun.local --password 'demo1234' --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id $POOL_ID \\
    --username 0933222333@jinsun.local --group-name worker
EOF
