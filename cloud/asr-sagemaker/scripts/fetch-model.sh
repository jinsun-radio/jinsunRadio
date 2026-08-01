#!/usr/bin/env bash
# 從 HuggingFace 抓 CTranslate2 權重到 model/（3.1GB，已 gitignore）。
# 可重複執行：續傳 + 驗 size，中途斷線再跑一次即可。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

mkdir -p "$ROOT/model"
cd "$ROOT/model"
BASE="https://huggingface.co/$HF_REPO/resolve/main"

for f in config.json preprocessor_config.json tokenizer_config.json vocabulary.json; do
  echo "==> $f"
  curl -fsSL --retry 5 --retry-all-errors -o "$f" "$BASE/$f"
done

# model.bin 用 -C - 續傳。curl 遇到連線中斷會截斷檔案卻仍 exit 0，所以靠 size 判斷收斂。
for _ in $(seq 1 40); do
  sz=$(stat -f%z model.bin 2>/dev/null || stat -c%s model.bin 2>/dev/null || echo 0)
  [ "$sz" -ge "$MODEL_BIN_BYTES" ] && break
  echo "==> model.bin $sz / $MODEL_BIN_BYTES"
  curl -sL -C - --retry 8 --retry-all-errors --retry-delay 3 \
       --speed-limit 51200 --speed-time 30 -o model.bin "$BASE/model.bin" || true
done

sz=$(stat -f%z model.bin 2>/dev/null || stat -c%s model.bin)
[ "$sz" -eq "$MODEL_BIN_BYTES" ] || { echo "model.bin 不完整：$sz != $MODEL_BIN_BYTES" >&2; exit 1; }
echo "==> 模型完整（$sz bytes）"
