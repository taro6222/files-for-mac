#!/usr/bin/env python3
"""Constrain the test host's Swift executor without constraining SwiftPM itself."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)
driver_env = dict(os.environ)
driver_env.pop("LIBDISPATCH_COOPERATIVE_POOL_STRICT", None)
swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], env=driver_env, text=True).strip())
toolchain = swiftc.parent.parent.parent
helper = toolchain / "usr/libexec/swift/pm/swiftpm-testing-helper"
if not helper.is_file():
    raise SystemExit(f"Swift Testing host not found: {helper}")
binary_directory = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], env=driver_env, text=True).strip())
candidates = [path for path in binary_directory.glob("*.xctest") if path.is_file()]
candidates += [path for path in binary_directory.glob("*.xctest/Contents/MacOS/*") if path.is_file()]
if len(candidates) != 1:
    raise SystemExit(f"Expected one built test host, found: {candidates}")
test_binary = candidates[0].resolve()
developer = Path(driver_env.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip())
platform = developer / "Platforms/MacOSX.platform/Developer"
host_env = dict(driver_env, LIBDISPATCH_COOPERATIVE_POOL_STRICT="1")
runtime_paths = {
    "DYLD_FRAMEWORK_PATH": [toolchain / "Library/Developer/Frameworks", platform / "Library/Frameworks"],
    "DYLD_LIBRARY_PATH": [toolchain / "Library/Developer/usr/lib", platform / "usr/lib", toolchain / "usr/lib/swift/macosx"],
}
for key, candidates in runtime_paths.items():
    paths = [str(path) for path in candidates if path.is_dir()]
    if driver_env.get(key):
        paths.append(driver_env[key])
    host_env[key] = os.pathsep.join(paths)
tests = [
    "gitConcurrentSnapshotsCompleteWithoutBlockingSwiftTasks",
    "gitWaitingForProcessAllowsOtherSwiftTasksToResume",
    "gitCancellationTerminatesProcessAndCleansCloneStaging",
]
arguments = [str(helper), "--test-bundle-path", str(test_binary), "--filter", "|".join(tests),
             "--testing-library", "swift-testing"]
output = root / "build/git-scheduling-verification"
output.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
timed_out = False
with (output / "run.log").open("wb") as log:
    with subprocess.Popen(arguments, env=host_env, stdout=log, stderr=subprocess.STDOUT) as process:
        try:
            status = process.wait(timeout=75)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                subprocess.run(["sample", str(process.pid), "1", "-file", str(output / "timeout-sample.txt")],
                               stdout=log, stderr=log, timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass
            process.kill()
            status = process.wait()
        finally:
            if process.poll() is None:
                process.kill()
text = (output / "run.log").read_text(errors="replace")
passed = {name: bool(re.search(r"✔ Test " + re.escape(name) + r"\(\) passed", text)) for name in tests}
success = not timed_out and status == 0 and all(passed.values())
result = {"state": "passed" if success else "failed", "tests": passed, "exitCode": status,
          "timedOut": timed_out, "elapsedSeconds": time.monotonic() - started,
          "testBinary": str(test_binary), "constrainedProcess": "swiftpm-testing-helper",
          "swiftVersion": subprocess.check_output(["swiftc", "--version"], env=driver_env, text=True).strip(),
          "sourceCommit": driver_env.get("GITHUB_SHA"), "strictCooperativePool": True}
(output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(text, end="")
print(f"Git scheduling evidence: {output}")
sys.exit(0 if success else 1)
