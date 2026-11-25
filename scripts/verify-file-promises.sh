#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=drag
if [[ ${1:-} == --contract ]]; then mode=contract; shift; fi
if [[ $# != 2 || "$1" != --binary || ! -x "$2" ]]; then
  echo 'Usage: verify-file-promises.sh [--contract] --binary path-to-debug-FilesMac' >&2
  exit 2
fi
output=$(mktemp -d "${TMPDIR:-/tmp}/files-promise-verification.XXXXXX")
python3 - "$2" "$output" "$mode" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import uuid

binary, output = (Path(value).resolve() for value in sys.argv[1:3])
mode = sys.argv[3]
print(f"File promise {mode} verification results: {output}", flush=True)
if mode == "contract":
    env = dict(os.environ, FILES_PROMISE_QA_OUTPUT=str(output), FILES_PROMISE_QA_MODE="contract")
    with (output / "run.log").open("wb") as log:
        status = subprocess.run([binary], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45).returncode
    result = json.loads((output / "report.json").read_text())
    expected = {
        "writesPasteboard", "preservesFileURLRepresentation", "promiseIsLazy", "offersPromiseTypes",
        "readsOnePromiseReceiver", "delegateNamesOriginalFile", "usesBackgroundPromiseQueue",
        "delegateCompletesWithoutError", "delegateUsesReceiversName", "delegatePreservesMode",
        "delegateReportsCollision", "delegateProtectsExistingDestination", "delegateRejectsChangedSource",
        "delegatePreservesBothSourceVersions", "offersDirectoryType", "delegateExportsDirectory",
        "delegatePreservesSymbolicLink", "unknownIdentityKeepsOnlyFileURL",
        "receivePolicyCancellationRetainsRetry", "receiveHandoffIncludesAllIntakes", "receiveAcceptedBatchMarkedOnce",
        "receiveDoesNotResubmitAcceptedBatch", "receivePauseRetainsVerifiedFiles", "receiveTypesIncludeURLAndPromises",
        "recoveryListsPersistedJobs", "recoveryEnablesVerifiedCopyRequest", "recoveryDamagedReceiptAllowsRevealOnly", "recoveryMixedSelectionProtectsDamagedData",
    }
    checks = result["checks"]
    if status or result.get("mode") != "delegate-contract" or not expected.issubset(checks) or not all(value is True for value in checks.values()):
        raise SystemExit(f"File promise delegate contract checks failed: {json.dumps(result, ensure_ascii=False)}")
    print(f"{len(checks)} AppKit file promise export and receive-handoff contract checks passed; actual SDK drag delivery remains separate")
    raise SystemExit(0)
app = output / "File Promise QA.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True)
shutil.copy2(binary, macos / "FilesMac")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "org.taro6222.files-for-mac.qa.promise." + uuid.uuid4().hex,
    "CFBundleName": "File Promise QA", "CFBundleExecutable": "FilesMac", "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1", "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True, "FilesReleaseChannel": "preview",
}))
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
probe = output / "drag-probe"
subprocess.run(["swiftc", "-parse-as-library", "scripts/FilePromiseDragProbe.swift", "-o", str(probe)], check=True)
with (output / "run.log").open("wb") as log:
    with subprocess.Popen([probe, app, output], stdout=log, stderr=subprocess.STDOUT) as process:
        try:
            status = process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            subprocess.run(["/usr/bin/sample", str(process.pid), "1", "-file", output / "timeout-sample.txt"],
                           stdout=log, stderr=log, timeout=5)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            launch = output / "launch.json"
            if launch.exists():
                pid = json.loads(launch.read_text())["processID"]
                command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
                if str(app) in command.stdout:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
if not (output / "report.json").exists():
    print((output / "run.log").read_text(errors="replace"), file=sys.stderr)
    raise SystemExit(f"File promise did not produce a final report; see {output / 'run.log'}")
result = json.loads((output / "report.json").read_text())
expected = {
    "writesPasteboard", "preservesFileURLRepresentation", "promiseIsLazy", "offersPromiseTypes",
    "readsOnePromiseReceiver", "receiverCompletesWithoutError", "receiverWritesExpectedName",
    "receiverWritesExpectedBytes", "receiverPreservesMode", "sourceRemainsUnchanged", "realDraggingSession",
}
checks = result["checks"]
if status or not expected.issubset(checks) or not all(value is True for value in checks.values()):
    raise SystemExit(f"File promise checks failed: {json.dumps(result, ensure_ascii=False)}")
print(f"{len(checks)} AppKit file promise checks passed")
PY
