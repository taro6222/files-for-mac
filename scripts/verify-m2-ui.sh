#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case $# in
  0)
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
    swift build --disable-sandbox -Xswiftc -gnone
    binary="$(swift build --show-bin-path)/FilesMac"
    ;;
  1) binary=$1 ;;
  *) echo "Usage: $0 [path-to-debug-FilesMac]" >&2; exit 2 ;;
esac
if [[ ! -x "$binary" ]]; then
  echo "Debug executable unavailable: $binary" >&2
  exit 2
fi
output_root=$(mktemp -d "${TMPDIR:-/tmp}/files-m2-ui.XXXXXX")
output_root=$(cd "$output_root" && pwd -P)
printf 'File operation UI results: %s\n' "$output_root"
for language in ko en; do
  for theme in light dark; do
    output="$output_root/$language-$theme"
    mkdir "$output"
    python3 - "$binary" "$output" "$language" "$theme" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

binary, output = (Path(value).resolve() for value in sys.argv[1:3])
language, theme = sys.argv[3:]
env = dict(os.environ, FILES_M2_UI_QA_OUTPUT=str(output), FILES_UI_QA_THEME=theme)
log = output / "run.log"
report = output / "report.json"
try:
    with log.open("wb") as stream:
        subprocess.run([binary, "-AppleLanguages", f"({language})", "-AppleLocale", language],
                       env=env, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=120)
    result = json.loads(report.read_text())
    if not result["checks"] or not all(value is True for value in result["checks"].values()):
        raise ValueError("file operation checks failed or are missing")
except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
    if log.exists():
        print(log.read_text(errors="replace"), file=sys.stderr)
    if report.exists():
        print(report.read_text(), file=sys.stderr)
    raise SystemExit(f"{language}/{theme}: {error}")
print(f"{language}/{theme}: {len(result['checks'])} file operation UI checks passed")
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
  done
done
