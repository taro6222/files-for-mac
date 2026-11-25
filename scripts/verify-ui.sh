#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
languages=(ko en)
themes=(light dark)
runName=files-ui-verification
export FILES_UI_QA_REPETITIONS=5
binary=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --performance)
      languages=(ko); themes=(dark)
      runName=files-ui-performance
      export FILES_UI_QA_REPETITIONS=20
      shift
      ;;
    --binary)
      [[ $# -ge 2 && -x "$2" ]] || { echo "Expected a debug FilesMac executable." >&2; exit 2; }
      binary=$2
      shift 2
      ;;
    *) echo "Usage: $0 [--performance] [--binary path-to-debug-FilesMac]" >&2; exit 2 ;;
  esac
done
if [[ -z "$binary" ]]; then
  export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
  # UI verification needs DEBUG hooks, but does not need a dSYM bundle.
  swift build --disable-sandbox -Xswiftc -gnone
  binary="$(swift build --show-bin-path)/FilesMac"
fi
outputRoot=$(mktemp -d "${TMPDIR:-/tmp}/$runName.XXXXXX")
outputRoot=$(cd "$outputRoot" && pwd -P)
printf 'UI verification results: %s\n' "$outputRoot"
# Each process gets an isolated preferences suite and a fresh fixture directory.
failed=0
for language in "${languages[@]}"; do
  for theme in "${themes[@]}"; do
    output="$outputRoot/$language-$theme"
    mkdir -p "$output"
    python3 - "$binary" "$output" "$language" "$theme" <<'PY' || failed=1
import json
from itertools import islice
import os
from pathlib import Path
import subprocess
import sys

binary, output = (Path(value).resolve() for value in sys.argv[1:3])
language, theme = sys.argv[3:]
env = dict(os.environ, FILES_UI_QA_OUTPUT=str(output), FILES_UI_QA_THEME=theme)
log = output / "run.log"
report = output / "report.json"
stack = output / "timeout-sample.txt"
try:
    with log.open("wb") as stream:
        arguments = [binary, "-AppleLanguages", f"({language})", "-AppleLocale", language]
        with subprocess.Popen(arguments, env=env, stdout=stream, stderr=subprocess.STDOUT) as app:
            try:
                status = app.wait(timeout=180)
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
    if not result["checks"] or not all(value is True for value in result["checks"].values()):
        raise ValueError("AppKit checks failed or are missing")
except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
    if log.exists():
        print(log.read_text(errors="replace"), file=sys.stderr)
    if report.exists():
        print(report.read_text(errors="replace"), file=sys.stderr)
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
exit "$failed"
