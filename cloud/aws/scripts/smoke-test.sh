#!/usr/bin/env bash
# AWS 平行環境的端點煙霧測試。不需要 AWS 憑證——它打的是公開端點，
# 走的路徑跟三端 App 完全一樣（Cognito USER_PASSWORD_AUTH → Bearer token → /data/*）。
#
# 用法：
#   bash cloud/aws/scripts/smoke-test.sh            # 唯讀，安全，隨時可跑
#   bash cloud/aws/scripts/smoke-test.sh --voice    # 追加真實升級鏈路（會寫資料庫、開派遣單）
#
# ⚠️ --voice 會真的觸發一次疑似跌倒 → 20 秒後升級 → 開派遣單 → 推到三端。
#    Demo 前跑會留下測試資料，要自己清。
set -uo pipefail

API=${API_BASE:-https://yr0ep335el.execute-api.us-west-2.amazonaws.com}
CLIENT_ID=${COGNITO_CLIENT_ID:-42rpj4dsabhqcq6gi0jrgc2l37}
COG=https://cognito-idp.${AWS_REGION:-us-west-2}.amazonaws.com
PASSWORD=${DEMO_PASSWORD:-demo1234}
ORIGIN=${ORIGIN:-https://d22h4jxlikk4jo.cloudfront.net}

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# ── 1. 健康檢查（不需認證）────────────────────────────────────────────
echo "── 1. /health ──"
h=$(curl -s --max-time 30 "$API/health")
case "$h" in
  *'"ok":true'*) ok "$h" ;;
  *)             bad "非預期回應：$h" ;;
esac
case "$h" in
  *'"dispatch":"live"'*) : ;;
  *) bad 'dispatch 不是 live —— Aurora 可能睡著或 IAM 過期，看 CloudWatch /aws/lambda/jinsun-voice' ;;
esac

# ── 2. 認證防線 ──────────────────────────────────────────────────────
echo "── 2. 認證 ──"
c=$(curl -s -o /dev/null -w '%{http_code}' "$API/data/version")
[ "$c" = 401 ] && ok "無 token → 401" || bad "無 token → $c（預期 401）"
c=$(curl -s -o /dev/null -w '%{http_code}' "$API/data/version" -H 'Authorization: Bearer garbage')
[ "$c" = 401 ] && ok "爛 token → 401" || bad "爛 token → $c（預期 401）"

# ── 3. CORS preflight —— 瀏覽器才會走的路徑，curl 平常測不到 ──────────
#    preflight 必須回 2xx，瀏覽器才會送出真正的請求。
#    這裡曾經是 404：$default 路由會 match 掉 OPTIONS，把它轉進 jinsun-voice。
echo "── 3. CORS preflight ──"
pf=$(curl -s -o /dev/null -X OPTIONS "$API/data/version" \
      -H "Origin: $ORIGIN" -H 'Access-Control-Request-Method: GET' \
      -H 'Access-Control-Request-Headers: authorization' \
      -w '%{http_code}')
if [ "${pf:-0}" -ge 200 ] && [ "${pf:-0}" -lt 300 ]; then
  ok "OPTIONS /data/version → ${pf}"
else
  bad "OPTIONS /data/version → ${pf}（預期 2xx；非 2xx 時瀏覽器會擋掉整個請求，"
  echo "      curl 測起來卻一切正常。修法見 docs/requirements/aws-handoff.md）"
fi

# ── 3.5 下行佇列（模擬器通道）──────────────────────────────────────
#    只驗「路由活著、語義正確」，不驗實際下發（那要 invoke jinsun-speak，需 AWS 憑證）。
#    ⚠️ 序號刻意用 JS-SMOKETEST 而非 JS-0001：GET /commands 是消耗式的，
#       只要有人開著 admin/?sim=1 就會持續輪詢 JS-0001 並搶先領走，
#       拿真序號來測會永遠是空的、看起來像壞掉。
echo "── 3.5 下行佇列 ──"
c=$(curl -s -o /dev/null -w '%{http_code}' "$API/commands")
[ "$c" = 400 ] && ok "缺 device_serial → 400" || bad "缺 device_serial → $c（預期 400）"
t0=$(date +%s)
c=$(curl -s -o /dev/null -w '%{http_code}' "$API/commands?device_serial=JS-SMOKETEST")
held=$(( $(date +%s) - t0 ))
if [ "$c" = 200 ] && [ "$held" -ge 5 ]; then
  ok "空佇列 → 200 且 hold ${held}s（有節流，模擬器不會變忙迴圈）"
else
  bad "空佇列 → HTTP $c、hold ${held}s（預期 200 且 ≥5s）"
fi

# ── 4. 三個角色的授權範圍 ────────────────────────────────────────────
echo "── 4. 角色授權 ──"
login() {
  local digits; digits=$(printf '%s' "$1" | tr -cd '0-9')
  curl -s "$COG" -H 'content-type: application/x-amz-json-1.1' \
    -H 'x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth' \
    -d "{\"AuthFlow\":\"USER_PASSWORD_AUTH\",\"ClientId\":\"$CLIENT_ID\",\"AuthParameters\":{\"USERNAME\":\"${digits}@jinsun.local\",\"PASSWORD\":\"$PASSWORD\"}}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("AuthenticationResult",{}).get("IdToken","") or "")'
}

# 期望值刻意分兩種寫法：
#   家屬／社工 → 固定數字（綁定與長輩總數是種子資料，穩定）
#   志工       → **自洽斷言**，不寫死數字。志工看得到的長輩＝他手上有單的長輩，
#                跑過一次 demo 就會從 0 變成 N。寫死數字的話，每次有人測完
#                這項就會紅，然後大家開始忽略它——比沒有測試更糟。
check_role() {
  local phone=$1 want_role=$2 want_elders=$3
  local tok; tok=$(login "$phone")
  if [ -z "$tok" ]; then bad "$phone 登入失敗"; return; fi
  local body; body=$(curl -s "$API/data/snapshot" -H "Authorization: Bearer $tok")
  python3 - "$body" "$want_role" "$want_elders" "$phone" <<'PY'
import json,sys
body,want_role,want_elders,phone=sys.argv[1:5]
try: d=json.loads(body)
except Exception:
    print(f"  \033[31m✗\033[0m {phone} snapshot 非 JSON: {body[:120]}"); sys.exit(1)
role=d.get("role")
elders=d.get("elders") or []
n=len(elders)
if want_elders=="own-tasks":                    # 志工：自洽
    want=len({t.get("elder_id") for t in (d.get("tasks") or []) if t.get("elder_id")})
    desc=f"與自己派遣單涵蓋的長輩數一致({want})"
else:
    want=int(want_elders); desc=f"期望{want}"
mark="\033[32m✓\033[0m" if (role==want_role and n==want) else "\033[31m✗\033[0m"
print(f"  {mark} {phone}  role={role}(期望{want_role})  長輩={n}({desc})  name={d.get('name')}")
sys.exit(0 if role==want_role and n==want else 1)
PY
  [ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))
}
check_role 0912-345-678 family    1
check_role 0921-000-111 volunteer own-tasks
check_role 0933-222-333 worker    22

# ── 5.（選用）真實升級鏈路 ───────────────────────────────────────────
if [ "${1:-}" = "--voice" ]; then
  echo "── 5. POST /voice（真的會開派遣單）──"
  r=$(curl -s --max-time 40 -X POST "$API/voice" -H 'content-type: application/json' \
        -d '{"device_serial":"JS-0001","event":"fall_suspected"}')
  echo "  回應：$r"
  echo "  ⏳ 等 25 秒看是否升級（黃金窗是 20 秒）…"
  sleep 25
  tok=$(login 0933-222-333)
  curl -s "$API/data/snapshot" -H "Authorization: Bearer $tok" | python3 -c '
import sys,json
d=json.load(sys.stdin)
ev=[e for e in (d.get("events") or []) if e.get("elder_id")=="elder-1"][:2]
tk=[t for t in (d.get("tasks") or []) if t.get("elder_id")=="elder-1"][:2]
print("  最近事件：",[(e.get("type"),e.get("severity")) for e in ev])
print("  派遣單：  ",[(t.get("kind"),t.get("status")) for t in tk])
print("  ⚠️ 這是測試資料，demo 前記得清掉")
'
else
  echo "── 5. POST /voice ── (略過；加 --voice 才會跑，它會真的開派遣單)"
fi

echo
printf '通過 %d 項，失敗 %d 項\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
