#!/usr/bin/env python3
"""Compare the build metadata of a soak executable and a candidate app slice."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys


def describe(binary, architecture):
    output = subprocess.run(
        ["xcrun", "vtool", "-arch", architecture, "-show-build", binary],
        check=True, capture_output=True, text=True, timeout=15,
    ).stdout
    if len(re.findall(r"^\s*cmd LC_BUILD_VERSION\s*$", output, re.MULTILINE)) != 1:
        raise ValueError(f"{binary}: expected exactly one LC_BUILD_VERSION")

    values = dict(re.findall(r"^\s*(platform|minos|sdk)[ \t]+(\S+)[ \t]*$", output, re.MULTILINE))
    if values.get("platform") != "MACOS" or not {"minos", "sdk"} <= values.keys():
        raise ValueError(f"{binary}: incomplete Mach-O macOS build metadata")

    digest = hashlib.sha256()
    with binary.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {
        "sha256": digest.hexdigest(),
        "platform": values["platform"],
        "minimumOS": values["minos"],
        "sdk": values["sdk"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("soak_binary", type=Path)
    parser.add_argument("candidate_app", type=Path)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), default=platform.machine())
    args = parser.parse_args()
    try:
        contents = args.candidate_app / "Contents"
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        if executable != "FilesMac":
            raise ValueError("expected FilesMac in the candidate's CFBundleExecutable")
        candidate = describe(contents / "MacOS" / executable, args.architecture)
        soak = describe(args.soak_binary, args.architecture)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Cannot compare build metadata: {error}", file=sys.stderr)
        return 2

    differences = [key for key in ("platform", "minimumOS", "sdk") if candidate[key] != soak[key]]
    print(json.dumps({
        "architecture": args.architecture,
        "candidate": candidate,
        "soak": soak,
        "differences": differences,
        "matches": not differences,
    }, indent=2))
    return int(bool(differences))


if __name__ == "__main__":
    raise SystemExit(main())
