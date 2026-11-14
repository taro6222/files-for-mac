#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:-release-performance}
mode=${2:-full}
if [[ $# -gt 2 || ( "$mode" != full && "$mode" != idle-comparison && "$mode" != idle-activity ) ]]; then
  echo "Usage: $0 [report-name [full|idle-comparison|idle-activity]]" >&2
  exit 2
fi
case "$name" in
  *[!a-zA-Z0-9_-]*) echo "Use a report name containing only letters, digits, hyphens and underscores." >&2; exit 2 ;;
esac
source_sha=$(git rev-parse --verify HEAD)
snapshot=$(mktemp -d "${TMPDIR:-/tmp}/files-release-performance.XXXXXX")
trap 'rm -rf -- "$snapshot"' EXIT
git archive "$source_sha" | tar -x -C "$snapshot"
export CLANG_MODULE_CACHE_PATH="$snapshot/.build/ModuleCache"
(
  cd "$snapshot"
  swift build -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA
)
bin_path=$(cd "$snapshot" && swift build -c release --show-bin-path)
python3 - "$bin_path/FilesMac" "$PWD/build/$name" "$source_sha" "$mode" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import platform
import plistlib
import subprocess
import sys
import tempfile
import time

binary, output_dir = map(pathlib.Path, sys.argv[1:3])
source_sha = sys.argv[3]
mode = sys.argv[4]
output_dir.mkdir(parents=True, exist_ok=True)
report_path = output_dir / "report.json"
report_path.unlink(missing_ok=True)
binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
storage = subprocess.check_output(["df", "-P", str(output_dir)], text=True).splitlines()[-1].split()[0]
filesystem = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", storage]))


def measure(folder, count, name, idle=0, user_initiated_load=False):
    sample = output_dir / f"{name}.json"
    sample.unlink(missing_ok=True)
    env = dict(os.environ, FILES_PERFORMANCE_FIXTURE=str(folder),
               FILES_PERFORMANCE_REPORT=str(sample), FILES_PERFORMANCE_COUNT=str(count),
               FILES_PERFORMANCE_IDLE_SECONDS=str(idle),
               FILES_PERFORMANCE_USER_INITIATED_LOAD="1" if user_initiated_load else "0")
    with (output_dir / f"{name}.log").open("w") as log:
        env["FILES_PERFORMANCE_START_NS"] = str(time.monotonic_ns())
        subprocess.run([binary, "-AppleLanguages", "(en)", "-AppleLocale", "en"],
                       env=env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=idle + 110)
    return json.loads(sample.read_text())


def summarize(samples):
    result = {}
    for metric in samples[0]:
        values = sorted(sample[metric] for sample in samples)
        result[metric] = {"max": values[-1], "p95": values[math.ceil(len(values) * 0.95) - 1]}
    return result


with tempfile.TemporaryDirectory(prefix="fixture-", dir=output_dir) as temporary:
    root = pathlib.Path(temporary)
    samples = {}
    for count in (10_000, 100_000) if mode == "full" else (10_000,):
        folder = root / str(count)
        folder.mkdir()
        for index in range(count):
            (folder / f"item-{index:06d}.txt").touch()
    report = {
        "sourceBaseSHA": source_sha,
        "binarySHA256": binary_hash,
        "macOS": platform.mac_ver()[0],
        "macOSBuild": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
        "architecture": platform.machine(),
        "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"])),
        "fixtureFilesystem": filesystem["FilesystemType"],
        "fixtureVersion": "numbered-empty-text-v1",
        "measurement": "Optimized QA build; fresh processes, OS caches warm; no thumbnails; AppKit display, not compositor presentation; sampled RSS",
    }
    folder = root / "10000"
    if mode == "full":
        for count, repetitions in ((10_000, 20), (100_000, 3)):
            samples[str(count)] = [
                measure(root / str(count), count, f"{count}-{index + 1:02}")
                for index in range(repetitions)
            ]
            print(f"{count:,} rows: {repetitions} processes completed", flush=True)
        report["samples"] = samples
        report["summary"] = {count: summarize(group) for count, group in samples.items()}
        report["idle300Seconds"] = measure(folder, 10000, "idle", idle=300)
    elif mode == "idle-comparison":
        pairs = []
        for trial in range(1, 4):
            immediate = measure(folder, 10000, f"pair-{trial}-immediate")
            idle = measure(folder, 10000, f"pair-{trial}-idle", idle=300)
            pairs.append({"immediate": immediate, "idle300Seconds": idle})
            print(f"Idle comparison {trial}/3 complete", flush=True)
        report["idleComparison"] = pairs
    else:
        baseline = measure(folder, 10000, "idle-baseline", idle=300)
        activity = measure(folder, 10000, "idle-activity", idle=300, user_initiated_load=True)
        if baseline.get("userInitiatedLoad") != 0 or activity.get("userInitiatedLoad") != 1:
            raise RuntimeError("Idle measurements did not report the configured activity")
        report["idleActivityComparison"] = {"baseline": baseline, "userInitiated": activity}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(report_path)
PY
