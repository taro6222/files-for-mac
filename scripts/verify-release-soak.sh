#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
seconds=${1:-28800}
workload=${3-full}
if [[ $# -gt 3 || ! "$seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "Expected a positive duration and at most three arguments." >&2
  exit 2
fi
case "$workload" in
  full|navigation|tabs|windows) ;;
  *) echo "Expected workload full, navigation, tabs, or windows." >&2; exit 2 ;;
esac
source_sha=$(git rev-parse --verify HEAD)
if [[ $# -ge 2 ]]; then
  if [[ ! -d "$2" ]]; then
    echo "The run parent must be an existing directory: $2" >&2
    exit 2
  fi
  run_parent=$(cd -- "$2" && pwd -P)
else
  mkdir -p build
  run_parent="$PWD/build"
fi
run_dir=$(mktemp -d "$run_parent/release-soak.XXXXXX")
echo "$run_dir"
snapshot="$run_dir/source"
mkdir "$snapshot"
git archive "$source_sha" | tar -x -C "$snapshot"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
(
  cd "$snapshot"
  swift build -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA >&2
  swift build -c release --show-bin-path
) > "$run_dir/bin-path"
bin_path=$(cat "$run_dir/bin-path")
cp "$bin_path/FilesMac" "$run_dir/FilesMac"
printf '%s\n' "$source_sha" > "$run_dir/source-sha"
(cd "$run_dir" && shasum -a 256 FilesMac > binary.sha256)
rm -rf -- "$snapshot"
rm -- "$run_dir/bin-path"
sw_vers > "$run_dir/macos.txt"
/bin/df -P "$run_dir" > "$run_dir/filesystem.txt"
export FILES_SOAK_DIRECTORY="$run_dir" FILES_SOAK_SECONDS="$seconds" FILES_SOAK_WORKLOAD="$workload"
status=0
caffeinate -i "$run_dir/FilesMac" >"$run_dir/app.log" 2>&1 || status=$?
printf '%s\n' "$status" > "$run_dir/.exit-status"
mv "$run_dir/.exit-status" "$run_dir/exit-status"
exit "$status"
