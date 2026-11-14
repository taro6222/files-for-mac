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
# Keep the app's report and exit status as written. Package a final result
# that can be reviewed without the run directory or the test executable.
python3 - "$run_dir" "$status" "$seconds" "$workload" <<'PY'
import json
import platform
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
status, duration = map(int, sys.argv[2:4])
workload = sys.argv[4]
report_error = None
try:
    report = json.loads((root / "report.json").read_text())
    if not isinstance(report, dict):
        raise ValueError("Expected an object in report.json")
except (OSError, ValueError) as error:
    report, report_error = None, str(error)

completed = (
    status == 0 and report is not None
    and report.get("state") == "completed"
    and report.get("targetSeconds") == duration
    and report.get("workload") == workload
    and isinstance(report.get("elapsedSeconds"), (int, float))
    and report["elapsedSeconds"] >= duration
    and isinstance(report.get("cycles"), int)
    and report["cycles"] > 0
    and bool(report.get("samples"))
)
result = {
    "sourceBaseSHA": (root / "source-sha").read_text().strip(),
    "binarySHA256": (root / "binary.sha256").read_text().split()[0],
    "macOS": platform.mac_ver()[0],
    "macOSBuild": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip(),
    "architecture": platform.machine(),
    "targetSeconds": duration,
    "workload": workload,
    "exitStatus": status,
    "completed": completed,
    "report": report,
}
if report_error:
    result["reportError"] = report_error
temporary = root / ".result.json"
temporary.write_text(json.dumps(result, indent=2) + "\n")
temporary.replace(root / "result.json")
if not completed:
    print("Soak did not produce a complete result. See result.json.", file=sys.stderr)
sys.exit(status if status else int(not completed))
PY
