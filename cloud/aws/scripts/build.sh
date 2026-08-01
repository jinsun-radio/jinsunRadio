#!/usr/bin/env bash
# 打包三支 Lambda。
#
# handler 直接沿用 cloud/prototype/src 的 agents/dispatch/triggers/progress，
# 不重複實作——所以打包時把需要的模組複製進各自的 src/，再安裝依賴、壓 zip。
# （Lambda 沒有 monorepo workspace 的概念，只能把用到的檔案帶進 bundle。）
#
# 用法：bash cloud/aws/scripts/build.sh [voice|speak|progress|data|auth]   省略＝全部
# 注意：用 case 而非 declare -A，因為 macOS 內建 bash 是 3.2、沒有關聯陣列。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC="$ROOT/cloud/prototype/src"
OUT="$ROOT/cloud/aws/.build"

needs_for() {
  case "$1" in
    voice)    echo "agents config llm dispatch.js elders.js db.js" ;;
    progress) echo "progress.js db.js" ;;
    speak)    echo "" ;;
    data)     echo "db.js" ;;
    auth)     echo "db.js" ;;
    *)        echo "unknown lambda: $1" >&2; exit 1 ;;
  esac
}

# 除了 index.mjs 之外還要一起打包的同目錄檔案（handler 拆檔用）
extras_for() {
  case "$1" in
    data) echo "authz.mjs ops.mjs" ;;
    *)    echo "" ;;
  esac
}

# lambda/_shared/ 下的共用模組（多支 Lambda 都要，但不屬於 prototype 的商業邏輯）。
# 複製進各自 bundle 的 shared/，import 路徑一律 './shared/xxx.mjs'。
shared_for() {
  case "$1" in
    voice|speak|progress) echo "downlink.mjs" ;;
    *)                    echo "" ;;
  esac
}

build_one() {
  fn="$1"
  dir="$ROOT/cloud/aws/lambda/$fn"
  work="$OUT/$fn"
  echo "── $fn ──"
  rm -rf "$work"; mkdir -p "$work"
  cp "$dir/index.mjs" "$dir/package.json" "$work/"
  for extra in $(extras_for "$fn"); do cp "$dir/$extra" "$work/"; done

  mods="$(needs_for "$fn")"
  if [ -n "$mods" ]; then
    mkdir -p "$work/src"
    for item in $mods; do cp -R "$SRC/$item" "$work/src/"; done
  fi

  shared="$(shared_for "$fn")"
  if [ -n "$shared" ]; then
    mkdir -p "$work/shared"
    for item in $shared; do cp "$ROOT/cloud/aws/lambda/_shared/$item" "$work/shared/"; done
  fi

  ( cd "$work" && npm install --silent --omit=dev --no-audit --no-fund )
  rm -f "$OUT/$fn.zip"
  ( cd "$work" && zip -qr "$OUT/$fn.zip" . -x '.*' )
  echo "   → cloud/aws/.build/$fn.zip  ($(du -h "$OUT/$fn.zip" | cut -f1))"
}

mkdir -p "$OUT"
if [ $# -gt 0 ]; then build_one "$1"; else for f in voice speak progress data auth; do build_one "$f"; done; fi
