#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
if [[ $# -ne 2 || ! -d "$1" || -L "$1" ]]; then
  echo "Usage: $0 /path/to/app signing-identity" >&2
  exit 64
fi
app=$1
identity=$2
script_dir=$(cd "$(dirname "$0")" && pwd)
python3 "$script_dir/sevenzip_bundle.py" verify --app "$app" --skip-signatures
options=(--timestamp=none)
if [[ "$identity" != - ]]; then
  case "$identity" in
    "Developer ID Application: "*) ;;
    *) echo "Expected ad-hoc or Developer ID Application signing identity." >&2; exit 64 ;;
  esac
  options=(--options runtime --timestamp)
fi
codesign --force "${options[@]}" --sign "$identity" --identifier org.taro6222.files-for-mac.sevenzip "$app/Contents/Frameworks/7z.so"
codesign --force "${options[@]}" --sign "$identity" --identifier org.taro6222.files-for-mac.sevenzip-worker "$app/Contents/Helpers/SevenZipWorker"
python3 "$script_dir/sevenzip_bundle.py" refresh-code-hashes --app "$app"
codesign --force "${options[@]}" --sign "$identity" "$app"
python3 "$script_dir/sevenzip_bundle.py" verify --app "$app"
