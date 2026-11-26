#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 || ! -d "$1" || -L "$1" ]]; then
  echo "Usage: $0 /path/to/app /new/report-directory" >&2
  exit 64
fi
app=$1
output=$2
if [[ -e "$output" || -L "$output" ]]; then
  echo "Package report directory already exists." >&2
  exit 73
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
python3 "$script_dir/sevenzip_bundle.py" verify --app "$app"
reference=$(python3 "$script_dir/sevenzip_reference.py")
worker="$app/Contents/Helpers/SevenZipWorker"
library="$app/Contents/Frameworks/7z.so"
manifest="$app/Contents/Resources/ThirdParty/7zip/manifest.json"
python3 "$script_dir/verify-sevenzip-worker.py" --worker "$worker" --library "$library" --bundle-manifest "$manifest" --reference "$reference" --output "$output/worker"
python3 "$script_dir/verify-sevenzip-client.py" --worker "$worker" --library "$library" --bundle-manifest "$manifest" --reference "$reference" --output "$output/client"
