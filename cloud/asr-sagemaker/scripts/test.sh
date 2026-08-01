#!/usr/bin/env bash
# 打 endpoint 並印出逐字稿與延遲拆解（wall / gpu / net）。
# 用法：scripts/test.sh samples/*.wav
#      INITIAL_PROMPT='…照護詞彙…' scripts/test.sh samples/meds.wav
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

for wav in "$@"; do
  if [ -n "${INITIAL_PROMPT:-}" ]; then
    # 帶 initial_prompt 要走 JSON；同音字（血壓藥／血壓要）靠這個修正。
    python3 - "$wav" "$INITIAL_PROMPT" "$ROOT/.payload.json" <<'PY'
import base64, json, sys
wav, prompt, out = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"audio_base64": base64.b64encode(open(wav, "rb").read()).decode(),
           "initial_prompt": prompt, "beam_size": 5}, open(out, "w"))
PY
    CT=application/json; BODY="fileb://$ROOT/.payload.json"
  else
    CT=audio/wav; BODY="fileb://$wav"
  fi

  start=$(python3 -c 'import time;print(time.time())')
  aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT_NAME" \
    --content-type "$CT" --body "$BODY" --cli-binary-format raw-in-base64-out \
    /dev/stdout > "$ROOT/.out.json" 2>"$ROOT/.err.txt" || { cat "$ROOT/.err.txt" >&2; exit 1; }
  end=$(python3 -c 'import time;print(time.time())')

  python3 - "$wav" "$start" "$end" "$ROOT/.out.json" <<'PY'
import json, sys
wav, start, end, outfile = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
# invoke-endpoint 會在 body 之後接一段 CLI metadata，只取第一個 JSON 值。
r, _ = json.JSONDecoder().raw_decode(open(outfile, encoding="utf-8").read())
gpu = r.get("processing_ms", 0) / 1000
print(f"{wav.split('/')[-1]:<14} [wall {end-start:5.2f}s | gpu {gpu:5.2f}s | net {end-start-gpu:5.2f}s | audio {r['duration']:.2f}s]")
print(f"  → {r['text']}")
PY
done
