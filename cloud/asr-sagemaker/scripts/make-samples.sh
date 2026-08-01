#!/usr/bin/env bash
# 重新產生 samples/ 的台灣國語測試音檔（macOS 內建 say，zh_TW 音色）。
# 音檔已進版控，平常不需要跑；要加新情境時再用。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/samples"

gen() { say -v "$2" --data-format=LEI16@16000 --file-format=WAVE -o "$ROOT/samples/$1.wav" "$3"; }

gen sos    "Grandma (中文（台灣）)" "我跌倒了，站不起來，快來幫我"
gen errand "Grandpa (中文（台灣）)" "我想買牛奶跟雞蛋，還有一包衛生紙"
gen ok     "Meijia"                "我沒事啦，只是不小心滑了一下，不用麻煩了"
gen meds   "Grandpa (中文（台灣）)" "我的血壓藥吃完了，禮拜三要回診"

ls -la "$ROOT/samples"
