#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
seconds=${1:-28800}
case "$seconds" in
  ''|*[!0-9]*) echo "Usage: $0 [positive-duration-seconds]" >&2; exit 2 ;;
esac
if ! [[ "$seconds" -gt 0 ]]; then exit 2; fi
mkdir -p build
run_dir=$(mktemp -d "$PWD/build/release-soak.XXXXXX")
echo "$run_dir"
scratch="$PWD/build/release-soak-swiftpm"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --scratch-path "$scratch" -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA
bin_path=$(swift build --scratch-path "$scratch" -c release --show-bin-path)
# Retain a private binary so later builds cannot replace the executable under test.
cp "$bin_path/FilesMac" "$run_dir/FilesMac"
git rev-parse HEAD > "$run_dir/source-sha"
(cd "$run_dir" && shasum -a 256 FilesMac > binary.sha256)
sw_vers > "$run_dir/macos.txt"
export FILES_SOAK_DIRECTORY="$run_dir" FILES_SOAK_SECONDS="$seconds"
exec caffeinate -i "$run_dir/FilesMac" >"$run_dir/app.log" 2>&1
