#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pacing=${1:-display}
case "$pacing" in
  display|timer|control|layout) ;;
  *) echo "Usage: $0 [display|timer|control|layout]" >&2; exit 64 ;;
esac
mkdir -p build
run_dir=$(mktemp -d "$PWD/build/scroll-window.XXXXXX")
echo "$run_dir"
printf '%s\n' "$pacing" > "$run_dir/pacing"
scratch="$PWD/build/release-performance-swiftpm"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swiftc -parse-as-library scripts/measure-scroll-window.swift -o "$run_dir/capture"
swift build --scratch-path "$scratch" -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA
binary="$(swift build --scratch-path "$scratch" -c release --show-bin-path)/FilesMac"
fixture="$run_dir/fixture"
mkdir "$fixture"
python3 - "$fixture" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
for index in range(10_000):
    (root / f"item-{index:06d}.txt").touch()
PY
export FILES_PERFORMANCE_FIXTURE="$fixture" FILES_PERFORMANCE_REPORT="$run_dir/app.json"
export FILES_PERFORMANCE_COUNT=10000 FILES_PERFORMANCE_IDLE_SECONDS=3 FILES_PERFORMANCE_SCROLL=1
export FILES_PERFORMANCE_SCROLL_PACING="$pacing"
export FILES_PERFORMANCE_START_NS=$(python3 -c 'import time; print(time.monotonic_ns())')
"$binary" >"$run_dir/app.log" 2>&1 &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; rm -rf -- "$fixture"' EXIT
"$run_dir/capture" "$app_pid" "$run_dir/app.json" "$run_dir/frames.json"
wait "$app_pid"
trap 'rm -rf -- "$fixture"' EXIT
cat "$run_dir/frames.json"
