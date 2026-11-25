#!/usr/bin/env python3
"""Exercise the product's NSMetadataQuery adapter against a prepared source fixture."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--state", type=Path, default=project / "build/spotlight-fixture/state.json")
args = parser.parse_args()
state_path = args.state.resolve()
state = json.loads(state_path.read_text())
if state.get("state") != "indexed" or state.get("cleaned") or not Path(state["expectedFile"]).is_file():
    raise SystemExit("An indexed, live Spotlight fixture is required")
binary = args.binary.resolve()
output = state_path.parent / "native-queries"
output.mkdir(parents=True, exist_ok=True)
report = output / "report.json"
report.unlink(missing_ok=True)
env = dict(os.environ, FILES_UI_SPOTLIGHT_ROOT=state["searchRoot"], FILES_SPOTLIGHT_QA_OUTPUT=str(output))
with (output / "run.log").open("wb") as log:
    with subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT) as app:
        try:
            status = app.wait(timeout=45)
        except subprocess.TimeoutExpired:
            try:
                subprocess.run(["sample", str(app.pid), "1", "-file", str(output / "timeout-sample.txt")],
                               stdout=log, stderr=log, timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
            raise
        finally:
            if app.poll() is None:
                app.kill()
if not report.exists():
    print((output / "run.log").read_text(errors="replace"), file=sys.stderr)
    raise SystemExit("NSMetadataQuery verification did not produce a report")
result = json.loads(report.read_text())
expected = {"descendantsFindExactSwiftSource", "currentFolderExcludesNestedSwiftSource",
            "indexedLocationsFindSourceOutsideCurrentFolder", "unknownContentHasNoResults"}
checks = result["checks"]
if status or result.get("sourceRoot") != state["searchRoot"] or not expected.issubset(checks) \
        or not all(value is True for value in checks.values()):
    raise SystemExit(f"Native Spotlight checks failed: {json.dumps(result)}")
print(f"{len(checks)} native NSMetadataQuery checks passed: {output}")
