#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || $# -gt 2 || ! -x "$1" ]]; then
  echo 'Usage: verify-tab-ui.sh debug-binary [existing-output-root]' >&2
  exit 2
fi
binary=$1
if [[ $# -eq 2 ]]; then
  [[ -d "$2" ]] || exit 2
  outputRoot=$2
else
  outputRoot=$(mktemp -d "${TMPDIR:-/tmp}/files-ui-verification.XXXXXX")
fi
outputRoot=$(cd "$outputRoot" && pwd -P)
printf 'Tab boundary results: %s\n' "$outputRoot"
failed=0
for language in ko en; do
  for theme in light dark; do
    output="$outputRoot/tabs-$language-$theme"
    mkdir "$output"
    python3 - "$binary" "$output" "$language" "$theme" <<'PY' || failed=1
import json
import os
from pathlib import Path
import subprocess
import sys
binary, root = (Path(v).resolve() for v in sys.argv[1:3])
language, theme = sys.argv[3:5]
log = root / 'run.log'
try:
    with log.open('wb') as stream:
        with subprocess.Popen([str(binary), '-AppleLanguages', f'({language})', '-AppleLocale', language],
                              env=dict(os.environ, FILES_TAB_UI_QA_OUTPUT=str(root), FILES_TAB_UI_QA_THEME=theme),
                              stdout=stream, stderr=subprocess.STDOUT) as app:
            try:
                app.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    subprocess.run(['sample', str(app.pid), '1', '-file', str(root/'timeout-sample.txt')],
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=5)
                finally:
                    app.kill(); app.wait(timeout=5)
                raise
            if app.returncode:
                raise RuntimeError(f'Owned app exited {app.returncode}')
    report = json.loads((root/'report.json').read_text())
    if (len(report['checks']) != 10 or not all(report['checks'].values())
            or report['theme'] != theme or report['language'].split('-')[0] != language
            or not (root/'overflow.png').is_file()):
        raise ValueError('Tab boundary checks, requested appearance, or capture are missing')
except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
    print(log.read_text(errors='replace'), file=sys.stderr)
    if (root/'report.json').exists(): print((root/'report.json').read_text(), file=sys.stderr)
    raise SystemExit(f'{language}/{theme}: {error}')
print(f'{language}/{theme}: 10 AppKit tab boundary checks passed')
PY
  done
done
exit "$failed"
