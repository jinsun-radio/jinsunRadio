#!/usr/bin/env bash
# 幫某個 device_serial 在 AWS IoT 準備好對應的 Thing。
#
# 為什麼需要這支：JinsunDevicePolicy 用 ${iot:Connection.Thing.ThingName} 限縮 client id
# 與 topic（cloud/aws/iot/device-policy.json），而韌體的 MQTT client id 就是 device_serial。
# 所以 .ino 改了 device_serial 卻沒有同名 Thing → **連線直接被切，且沒有任何錯誤訊息**，
# 症狀是「事件送得上去、但收音機不開口」，最難回推原因的一種壞法。
#
# 憑證沿用既有那張（一張憑證可以掛多個 Thing，policy 綁在憑證上），所以板子上的
# secrets.h 不用重燒，原本的 JS-0001 也照樣連得上。
#
# 用法：
#   bash cloud/aws/scripts/provision-thing.sh JS-0002
#   bash cloud/aws/scripts/provision-thing.sh JS-0002 <certificateId>   # 指定憑證
#
# 不指定 certificateId 時，預設沿用 FROM_THING（JS-0001）身上的憑證；那個 Thing 掛了
# 多張就會停下來要你指明，而不是替你亂猜一張。
#
# 板子上燒的是哪一張？certificateId 就是憑證 DER 的 SHA-256：
#   openssl x509 -in device.cert.pem -outform DER | shasum -a 256
set -euo pipefail

SERIAL="${1:-}"
CERT_ID="${2:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
POLICY="${POLICY:-JinsunDevicePolicy}"
FROM_THING="${FROM_THING:-JS-0001}"

if [[ -z "$SERIAL" ]]; then
  echo "用法：bash cloud/aws/scripts/provision-thing.sh <device_serial> [certificateId]" >&2
  exit 1
fi

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
aws() { command aws --region "$REGION" "$@"; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# ─── ① 決定要掛哪張憑證 ──────────────────────────────────────────────
say "① 憑證"
if [[ -n "$CERT_ID" ]]; then
  CERT_ARN="arn:aws:iot:${REGION}:${ACCOUNT}:cert/${CERT_ID}"
else
  # 不用 mapfile／readarray：macOS 內建的是 bash 3.2，沒有這兩個內建指令
  CERTS="$(aws iot list-thing-principals --thing-name "$FROM_THING" \
    --query 'principals[]' --output text | tr '\t' '\n' | grep -v '^$' || true)"
  N="$(printf '%s\n' "$CERTS" | grep -c . || true)"
  if [[ "$N" -eq 0 ]]; then
    echo "✗ $FROM_THING 身上沒有憑證，請用第二個參數指定 certificateId" >&2
    exit 1
  fi
  if [[ "$N" -gt 1 ]]; then
    echo "✗ $FROM_THING 掛了 $N 張憑證，請指明板子上燒的是哪一張：" >&2
    printf '%s\n' "$CERTS" | sed 's/^/    /' >&2
    exit 1
  fi
  CERT_ARN="$CERTS"
fi
echo "  $CERT_ARN"

STATUS="$(aws iot describe-certificate --certificate-id "${CERT_ARN##*/}" \
  --query 'certificateDescription.status' --output text)"
[[ "$STATUS" == "ACTIVE" ]] || { echo "✗ 憑證狀態是 $STATUS，不是 ACTIVE" >&2; exit 1; }

# 憑證沒掛 policy 的話，連得上也發不出 / 收不到任何 topic
if ! aws iot list-attached-policies --target "$CERT_ARN" \
     --query 'policies[].policyName' --output text | tr '\t' '\n' | grep -qx "$POLICY"; then
  echo "  憑證未掛 $POLICY，補上"
  aws iot attach-policy --policy-name "$POLICY" --target "$CERT_ARN"
fi

# ─── ② Thing ────────────────────────────────────────────────────────
say "② Thing $SERIAL"
if aws iot describe-thing --thing-name "$SERIAL" >/dev/null 2>&1; then
  echo "  已存在，略過建立"
else
  aws iot create-thing --thing-name "$SERIAL" >/dev/null
  echo "  已建立"
fi

# ─── ③ 綁定 ─────────────────────────────────────────────────────────
say "③ attach 憑證到 Thing"
if aws iot list-thing-principals --thing-name "$SERIAL" \
   --query 'principals[]' --output text | grep -qF "$CERT_ARN"; then
  echo "  已綁定，略過"
else
  aws iot attach-thing-principal --thing-name "$SERIAL" --principal "$CERT_ARN"
  echo "  已綁定"
fi

say "完成"
echo "Thing 清單：$(aws iot list-things --query 'things[].thingName' --output text)"
cat <<EOF

接下來：
  1. 確認 .ino 的 device_serial 與 #define BACKEND_AWS 對得起來，重燒板子。
  2. 驗下行（要看得到 speak 指令）：
       aws iot-data --region $REGION publish --topic jinsun/$SERIAL/cmd \\
         --cli-binary-format raw-in-base64-out --payload '{"type":"speak","text":"測試","lang":"mandarin"}'
  3. 驗上行：
       curl -s https://yr0ep335el.execute-api.$REGION.amazonaws.com/voice \\
         -H 'content-type: application/json' \\
         -d '{"device_serial":"$SERIAL","event":"fall_suspected"}'
EOF
