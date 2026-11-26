#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
languages=(ko en)
themes=(light dark)
runName=files-ui-verification
export FILES_UI_QA_REPETITIONS=5
binary=""
timeoutSeconds=180
while [[ $# -gt 0 ]]; do
  case "$1" in
    --performance)
      languages=(ko); themes=(dark)
      runName=files-ui-performance
      export FILES_UI_QA_REPETITIONS=20
      shift
      ;;
    --timeout-seconds)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 30 && "$2" -le 900 ]] || { echo "Expected a timeout from 30 to 900 seconds." >&2; exit 2; }
      timeoutSeconds=$2; shift 2
      ;;
    --binary)
      [[ $# -ge 2 && -x "$2" ]] || { echo "Expected a debug FilesMac executable." >&2; exit 2; }
      binary=$2
      shift 2
      ;;
    *) echo "Usage: $0 [--performance] [--binary path-to-debug-FilesMac] [--timeout-seconds 30..900]" >&2; exit 2 ;;
  esac
done
if [[ -z "$binary" ]]; then
  export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
  # UI verification needs DEBUG hooks, but does not need a dSYM bundle.
  swift build --disable-sandbox -debug-info-format none
  binary="$(swift build --show-bin-path)/FilesMac"
fi
outputRoot=$(mktemp -d "${TMPDIR:-/tmp}/$runName.XXXXXX")
outputRoot=$(cd "$outputRoot" && pwd -P)
printf 'UI verification results: %s\n' "$outputRoot"
# Exercise the same verified SDK selection as a packaged app; the override is DEBUG-only.
export PYTHONDONTWRITEBYTECODE=1
if [[ -z "${FILES_UI_QA_SEVENZIP_BUNDLE:-}" ]]; then
  export FILES_UI_QA_SEVENZIP_BUNDLE="$outputRoot/sdk/Files macOS.app"
  FILES_APP_OUTPUT="$FILES_UI_QA_SEVENZIP_BUNDLE" bash scripts/build-app.sh > "$outputRoot/sdk-build.log" 2>&1
fi
if [[ -z "${FILES_UI_QA_SEVENZIP_REFERENCE:-}" ]]; then
  FILES_UI_QA_SEVENZIP_REFERENCE=$(python3 scripts/sevenzip_reference.py)
  export FILES_UI_QA_SEVENZIP_REFERENCE
fi
# Each process gets an isolated preferences suite and a fresh fixture directory.
failed=0
for language in "${languages[@]}"; do
  for theme in "${themes[@]}"; do
    output="$outputRoot/$language-$theme"
    mkdir -p "$output"
    python3 - "$binary" "$output" "$language" "$theme" "$timeoutSeconds" <<'PY' || failed=1
import json
from itertools import islice
import os
from pathlib import Path
import subprocess
import sys

binary, output = (Path(value).resolve() for value in sys.argv[1:3])
language, theme = sys.argv[3:5]
timeout_seconds = int(sys.argv[5])
print(f"{language}/{theme}: full suite process budget {timeout_seconds}s", flush=True)
env = dict(os.environ, FILES_UI_QA_OUTPUT=str(output), FILES_UI_QA_THEME=theme)
log = output / "run.log"
report = output / "report.json"
stack = output / "timeout-sample.txt"
try:
    with log.open("wb") as stream:
        arguments = [binary, "-AppleLanguages", f"({language})", "-AppleLocale", language]
        with subprocess.Popen(arguments, env=env, stdout=stream, stderr=subprocess.STDOUT) as app:
            try:
                status = app.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                try:
                    subprocess.run(["/usr/bin/sample", str(app.pid), "1", "-file", stack],
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=5)
                except (OSError, subprocess.SubprocessError) as error:
                    print(f"Could not sample timed-out process: {error}", file=sys.stderr)
                raise
            finally:
                if app.poll() is None:
                    app.kill()
            if status:
                raise subprocess.CalledProcessError(status, arguments)
    result = json.loads(report.read_text())
    if result["language"].split("-")[0] != language or result["theme"] != theme:
        raise ValueError("reported language or theme differs from the requested environment")
    if len(result["checks"]) != 329 or not all(value is True for value in result["checks"].values()):
        raise ValueError("AppKit checks failed or are missing")
    progress_result = json.loads((output / "progress.json").read_text())
    if progress_result.get("state") != "passed" or progress_result.get("checks") != result["checks"]:
        raise ValueError("AppKit completion checkpoint differs from the final report")
except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
    if log.exists():
        print(log.read_text(errors="replace"), file=sys.stderr)
    if report.exists():
        print(report.read_text(errors="replace"), file=sys.stderr)
    progress = output / "progress.json"
    if progress.exists():
        print("Last completed checks and active phase:", file=sys.stderr)
        print(progress.read_text(errors="replace"), file=sys.stderr)
    if stack.exists():
        print(f"Timeout sample: {stack}", file=sys.stderr)
        with stack.open(errors="replace") as sample:
            sys.stderr.writelines(islice(sample, 100))
    raise SystemExit(f"{language}/{theme}: {error}")
print(f"{language}/{theme}: {len(result['checks'])} AppKit checks passed")
PY
    if [[ -f "$output/report.json" ]]; then
      cat "$output/report.json"
    fi
  done
done
if ! bash scripts/verify-tab-ui.sh "$binary" "$outputRoot"; then failed=1; fi
exit "$failed"
