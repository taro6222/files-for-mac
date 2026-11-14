#!/usr/bin/env python3
"""Verify local preview startup or installation in a temporary home."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid


WINDOW_PROBE = """\
import CoreGraphics
import Darwin
let owner = Int(CommandLine.arguments[1])
let title = CommandLine.arguments[2]
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
exit(windows.contains {
    $0[kCGWindowOwnerPID as String] as? Int == owner &&
    $0[kCGWindowLayer as String] as? Int == 0 &&
    $0[kCGWindowName as String] as? String == title
} ? 0 : 1)
"""


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def image_hash(image):
    digest = sha256(image)
    manifest = Path(f"{image}.sha256").read_text().split()
    if manifest != [digest, image.name]:
        raise ValueError(f"Checksum mismatch for {image}")
    return digest


@contextmanager
def mounted(image, mountpoint):
    run("hdiutil", "attach", image, "-readonly", "-nobrowse", "-mountpoint", mountpoint)
    try:
        yield mountpoint / "Files macOS.app"
    finally:
        run("hdiutil", "detach", mountpoint)


def verify_signature(app, **kwargs):
    run("codesign", "--verify", "--all-architectures", "--strict", app, **kwargs)


def version(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    return [info["CFBundleShortVersionString"], info["CFBundleVersion"]]


def isolate(app, bundle_id):
    # Use a separate preference domain for the copied preview.
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["CFBundleIdentifier"] = bundle_id
    path.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", app)
    verify_signature(app)


def launch(app, probe, fixture, home, log):
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))
    title = f"{fixture.name} — Files macOS"
    with log.open("ab") as output:
        start = time.monotonic()
        process = subprocess.Popen(
            [app / "Contents/MacOS/FilesMac"], env=env, stdout=output, stderr=subprocess.STDOUT
        )
        try:
            while time.monotonic() - start < 15:
                if process.poll() is not None:
                    raise RuntimeError(f"App exited with {process.returncode}; see {log}")
                if subprocess.run([probe, str(process.pid), title]).returncode == 0:
                    return round(time.monotonic() - start, 3)
                time.sleep(0.05)
            raise RuntimeError(f"No window for the saved startup location; see {log}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def build_window_probe(root):
    probe = root / "window-probe"
    source = probe.with_suffix(".swift")
    source.write_text(WINDOW_PROBE)
    run("swiftc", source, "-o", probe)
    return probe


def launch_environment():
    return {
        "macOS": run("sw_vers", "-productVersion", capture_output=True).stdout.strip(),
        "macOSBuild": run("sw_vers", "-buildVersion", capture_output=True).stdout.strip(),
        "architecture": os.uname().machine,
    }


def measure_startup(image, root, bundle_id):
    digest = image_hash(image)
    mountpoint, home, fixture = (root / name for name in ("mount", "home", "Startup Fixture"))
    for folder in (mountpoint, home, fixture):
        folder.mkdir()
    probe = build_window_probe(root)
    app = home / "Files macOS.app"
    with mounted(image, mountpoint) as mounted_app:
        verify_signature(mounted_app)
        run("ditto", mounted_app, app)
    verify_signature(app)
    app_version = version(app)
    isolate(app, bundle_id)
    run("defaults", "write", bundle_id, "startupLocationPath", "-string", fixture)
    run("defaults", "write", bundle_id, "continueLastSession", "-bool", "NO")
    samples = [launch(app, probe, fixture, home, root / "app.log") for _ in range(20)]
    p95 = sorted(samples)[math.ceil(len(samples) * 0.95) - 1]
    return {
        **launch_environment(),
        "imageSHA256": digest,
        "appVersion": app_version,
        "metric": "Process creation to the first matching AppKit window in the WindowServer list",
        "cacheCondition": "Fresh processes; shared OS caches, no cache purge",
        "seconds": samples,
        "p95Seconds": p95,
        "maximumSeconds": max(samples),
    }


def exercise(previous, candidate, root, bundle_id):
    previous_hash, candidate_hash = map(image_hash, (previous, candidate))
    if previous_hash == candidate_hash:
        raise ValueError("Expected two distinct preview images")

    mountpoint, home, fixture = (root / name for name in ("mount", "home", "Install Fixture"))
    applications = home / "Applications"
    for folder in (mountpoint, fixture, applications):
        folder.mkdir(parents=True)
    user_file = fixture / "keep.txt"
    user_file.write_text("Preview upgrade fixture\n")
    app = applications / "Files macOS.app"
    backup = applications / "Previous.app"
    staged = applications / "Staged.app"
    launch_log = root / "app.log"
    probe = build_window_probe(root)

    with mounted(previous, mountpoint) as mounted_app:
        verify_signature(mounted_app)
        prior_version = version(mounted_app)
        run("ditto", mounted_app, app)
    verify_signature(app)
    isolate(app, bundle_id)
    installed_binary = app / "Contents/MacOS/FilesMac"
    prior_binary = sha256(installed_binary)
    run("defaults", "write", bundle_id, "startupLocationPath", "-string", fixture)
    run("defaults", "write", bundle_id, "continueLastSession", "-bool", "NO")
    initial_time = launch(app, probe, fixture, home, launch_log)

    with mounted(candidate, mountpoint) as mounted_app:
        verify_signature(mounted_app)
        next_version = version(mounted_app)
        run("ditto", mounted_app, staged)
        verify_signature(staged)
        # Force a signature failure in staging and verify the installation still runs.
        (staged / "Contents/Info.plist").write_bytes(b"damaged install fixture")
        try:
            verify_signature(staged, capture_output=True)
        except subprocess.CalledProcessError:
            if sha256(installed_binary) != prior_binary:
                raise RuntimeError("Staging modified the installed executable")
            failure_time = launch(app, probe, fixture, home, launch_log)
        else:
            raise RuntimeError("The damaged staging bundle passed code-signature validation")
        run("ditto", mounted_app / "Contents/Info.plist", staged / "Contents/Info.plist")
    verify_signature(staged)
    isolate(staged, bundle_id)
    next_binary = sha256(staged / "Contents/MacOS/FilesMac")
    if next_binary == prior_binary:
        raise ValueError("Expected two distinct preview executables")
    app.rename(backup)
    staged.rename(app)
    upgrade_time = launch(app, probe, fixture, home, launch_log)
    if version(app) != next_version or sha256(installed_binary) != next_binary:
        raise RuntimeError("The installed bundle does not match the candidate")
    app.rename(staged)
    backup.rename(app)
    rollback_time = launch(app, probe, fixture, home, launch_log)
    if (version(app) != prior_version or sha256(installed_binary) != prior_binary
            or user_file.read_text() != "Preview upgrade fixture\n"):
        raise RuntimeError("Rollback failed to preserve the original bundle or fixture data")
    return {
        "previousImageSHA256": previous_hash,
        "candidateImageSHA256": candidate_hash,
        "previousVersion": prior_version,
        "candidateVersion": next_version,
        "previousTestExecutableSHA256": prior_binary,
        "candidateTestExecutableSHA256": next_binary,
        **launch_environment(),
        "windowVisibleSeconds": {
            "firstInstall": initial_time,
            "afterStagedSignatureFailure": failure_time,
            "afterReplacement": upgrade_time,
            "afterRollback": rollback_time,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous", type=Path)
    parser.add_argument("candidate", type=Path, nargs="?")
    parser.add_argument("--startup", action="store_true", help="Measure 20 launches from one preview image")
    args = parser.parse_args()
    if args.startup and args.candidate is not None:
        parser.error("--startup accepts one preview image")
    if not args.startup and args.candidate is None:
        parser.error("Installation verification requires a previous and candidate preview image")
    images = [image.resolve() for image in (args.previous, args.candidate) if image is not None]
    if any(image.name != "Files-macOS-preview.dmg" for image in images):
        parser.error("Use local Files-macOS-preview.dmg files")
    build = Path(__file__).resolve().parents[1] / "build"
    build.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="preview-install.", dir=build))
    bundle_id = f"org.taro6222.files-for-mac.qa.{uuid.uuid4()}"
    print(root, flush=True)
    try:
        if args.startup:
            result = measure_startup(images[0], root, bundle_id)
        else:
            result = exercise(*images, root, bundle_id)
        (root / "report.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


if __name__ == "__main__":
    main()
