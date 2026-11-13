#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --disable-sandbox -Xswiftc -gnone
for language in ko en; do
  for theme in light dark; do
    output="$PWD/build/m2-ui-verification/$language-$theme"
    mkdir -p "$output"
    rm -f "$output/report.json"
    FILES_M2_UI_QA_OUTPUT="$output" FILES_UI_QA_THEME="$theme" \
      .build/debug/FilesMac -AppleLanguages "($language)" -AppleLocale "$language" \
      >"$output/run.log" 2>&1
    cat "$output/report.json"
  done
done
