#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
# UI verification needs DEBUG hooks, but does not need a dSYM bundle.
swift build --disable-sandbox -Xswiftc -gnone
languages=(ko en)
themes=(light dark)
outputRoot="$PWD/build/ui-verification"
case "${1:-}" in
  "") export FILES_UI_QA_REPETITIONS=5 ;;
  --performance)
    languages=(ko); themes=(dark)
    outputRoot="$PWD/build/ui-performance"
    export FILES_UI_QA_REPETITIONS=20
    ;;
  *) echo "Usage: $0 [--performance]" >&2; exit 2 ;;
esac
# Each process gets an isolated preferences suite; global language/theme are untouched.
for language in "${languages[@]}"; do
  for theme in "${themes[@]}"; do
    output="$outputRoot/$language-$theme"
    mkdir -p "$output"
    python3 - "$output" "$language" "$theme" <<'PY'
import os, pathlib, subprocess, sys
output, language, theme = sys.argv[1:]
report = pathlib.Path(output) / 'report.json'
report.unlink(missing_ok=True)
env = dict(os.environ, FILES_UI_QA_OUTPUT=output, FILES_UI_QA_THEME=theme)
with open(pathlib.Path(output) / 'run.log', 'w') as log:
    try:
        subprocess.run(['.build/debug/FilesMac', '-AppleLanguages', f'({language})',
                        '-AppleLocale', language], env=env, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=180)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f'UI verification failed; see {output}/run.log: {error}')
PY
    cat "$output/report.json"
  done
done
