#!/usr/bin/env bash
# 用 OpenAI /v1/audio/transcriptions 的 multipart 形狀打 endpoint，
# 送出的 body 與韌體目前打 XCC Gateway 的內容一致（boundary=Taiwan）。
#
# 用法：scripts/test-openai.sh samples/sos.wav [json|verbose_json|text]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"

WAV="${1:?用法：scripts/test-openai.sh <檔案> [response_format]}"
FMT="${2:-json}"

python3 - "$WAV" "$FMT" "$ROOT/.payload.bin" <<'PY'
import sys
wav, fmt, out = sys.argv[1], sys.argv[2], sys.argv[3]
B = b"Taiwan"
def field(name, value):
    return (b"--" + B + b"\r\nContent-Disposition: form-data; name=\"" + name +
            b"\"\r\n\r\n" + value + b"\r\n")
body  = field(b"model", b"paulpengtw/faster-whisper-Breeze-ASR-26")
body += field(b"language", b"zh")
body += field(b"response_format", fmt.encode())
body += (b"--" + B + b"\r\nContent-Disposition: form-data; name=\"file\"; "
         b"filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
         + open(wav, "rb").read() + b"\r\n")
body += b"--" + B + b"--\r\n"
open(out, "wb").write(body)
PY

# Content-Type 標 octet-stream 而非 multipart/form-data：容器裡的 MMS 看到
# multipart 會先把 parts 拆走，handler 就收不到 body。body 本身仍是標準
# OpenAI multipart，由 inference.py 嗅 boundary 自行解析。
aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT_NAME" \
  --content-type 'application/octet-stream' \
  --body "fileb://$ROOT/.payload.bin" --cli-binary-format raw-in-base64-out \
  /dev/stdout | head -c 2000
echo
