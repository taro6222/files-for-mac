#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:-release-performance}
case "$name" in
  *[!a-zA-Z0-9_-]*) echo "Use a report name containing only letters, digits, hyphens and underscores." >&2; exit 2 ;;
esac
scratch="$PWD/build/release-performance-swiftpm"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --scratch-path "$scratch" -c release --disable-sandbox -Xswiftc -DRELEASE_PERFORMANCE_QA
bin_path=$(swift build --scratch-path "$scratch" -c release --show-bin-path)
python3 - "$bin_path/FilesMac" "$PWD/build/$name" <<'PY'
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

binary, output_dir = map(pathlib.Path, sys.argv[1:])
output_dir.mkdir(parents=True, exist_ok=True)
report_path = output_dir / "report.json"
report_path.unlink(missing_ok=True)
binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
storage = subprocess.check_output(["df", "-P", str(output_dir)], text=True).splitlines()[-1].split()[0]
filesystem = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", storage]))


def measure(folder, count, name, idle=0):
    sample = output_dir / f"{name}.json"
    sample.unlink(missing_ok=True)
    env = dict(os.environ, FILES_PERFORMANCE_FIXTURE=str(folder),
               FILES_PERFORMANCE_REPORT=str(sample), FILES_PERFORMANCE_COUNT=str(count),
               FILES_PERFORMANCE_IDLE_SECONDS=str(idle))
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
    for count, repetitions in ((10_000, 20), (100_000, 3)):
        folder = root / str(count)
        folder.mkdir()
        for index in range(count):
            (folder / f"item-{index:06d}.txt").touch()
        samples[str(count)] = [measure(folder, count, f"{count}-{index + 1:02}")
                               for index in range(repetitions)]
        print(f"{count:,} rows: {repetitions} processes completed", flush=True)
    idle = measure(root / "10000", 10000, "idle", idle=300)
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
        "samples": samples,
        "summary": {count: summarize(group) for count, group in samples.items()},
        "idle300Seconds": idle,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(report_path)
PY
