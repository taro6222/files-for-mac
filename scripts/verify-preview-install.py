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
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

if CommandLine.arguments[1] == "--launch" {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.environment = ["CFFIXED_USER_HOME": CommandLine.arguments[3]]
    configuration.arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en"]
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
        guard let application else {
            if let error { fputs("\\(error)\\n", stderr) }
            exit(2)
        }
        print(application.processIdentifier)
        exit(0)
    }
    RunLoop.main.run()
    exit(2)
}
if CommandLine.arguments[1] == "--close" {
    guard let pid = pid_t(CommandLine.arguments[2]),
          let application = NSRunningApplication(processIdentifier: pid),
          application.bundleURL?.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
    else { exit(2) }
    _ = application.terminate()
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while !application.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if !application.isTerminated {
        _ = application.forceTerminate()
        let forcedDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !application.isTerminated && ProcessInfo.processInfo.systemUptime < forcedDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
    exit(application.isTerminated ? 0 : 2)
}

if CommandLine.arguments[1] == "--check-interaction-access" {
    exit(AXIsProcessTrusted() ? 0 : 2)
}
let owner = Int(CommandLine.arguments[1])
let title = CommandLine.arguments[2]
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let found = windows.contains {
    $0[kCGWindowOwnerPID as String] as? Int == owner &&
    (title == "About Files macOS" || $0[kCGWindowLayer as String] as? Int == 0) &&
    $0[kCGWindowName as String] as? String == title
}
guard found else { exit(1) }
if CommandLine.arguments.count == 4 {
    guard let pid = owner.flatMap(pid_t.init(exactly:)) else { exit(2) }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    guard let menuBar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
          let appMenu = children(menuBar as! AXUIElement).first(where: {
              attribute($0, kAXTitleAttribute) as? String == "Files macOS"
          }),
          let menu = children(appMenu).first,
          let about = children(menu).first(where: {
              attribute($0, kAXTitleAttribute) as? String == "About Files macOS"
          }) else { exit(1) }
    let action = AXUIElementPerformAction(about, kAXPressAction as CFString)
    exit(action == .success || action == .cannotComplete ? 0 : 2)
}
exit(0)
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


def launch(app, probe, fixture, home, log, *, interactive=False, launch_services=False):
    env = dict(os.environ, CFFIXED_USER_HOME=str(home))
    title = f"{fixture.name} — Files macOS"
    with log.open("ab") as output:
        start = time.monotonic()
        arguments = [app / "Contents/MacOS/FilesMac"]
        if interactive:
            arguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en"]
        if launch_services:
            pid = int(run(probe, "--launch", app, home, capture_output=True, timeout=15).stdout)
            process = None
        else:
            process = subprocess.Popen(arguments, env=env, stdout=output, stderr=subprocess.STDOUT)
            pid = process.pid
        try:
            window_time = None
            next_press = 0.0
            while time.monotonic() - start < 15:
                if process is not None and process.poll() is not None:
                    raise RuntimeError(f"App exited with {process.returncode}; see {log}")
                if window_time is not None:
                    if subprocess.run([probe, str(pid), "About Files macOS"], timeout=5).returncode == 0:
                        return {"windowSeconds": window_time, "interactiveSeconds": round(time.monotonic() - start, 3)}
                    if time.monotonic() >= next_press:
                        status = subprocess.run([probe, str(pid), title, "--press-about"], timeout=5).returncode
                        if status > 1:
                            raise RuntimeError(f"Window probe exited with {status}")
                        next_press = time.monotonic() + 0.1
                    time.sleep(0.02)
                    continue
                status = subprocess.run([probe, str(pid), title], timeout=5).returncode
                if status == 0:
                    elapsed = round(time.monotonic() - start, 3)
                    if not interactive:
                        return elapsed
                    window_time = elapsed
                elif status != 1:
                    raise RuntimeError(f"Window probe exited with {status}")
                time.sleep(0.02 if interactive else 0.05)
            missing = "the About window after pressing the menu item" if window_time is not None else "the startup location"
            raise RuntimeError(f"No window for {missing}; see {log}")
        finally:
            if launch_services:
                run(probe, "--close", str(pid), app, timeout=8)
            elif process.poll() is None:
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


def measure_startup(image, root, bundle_id, *, interactive=False, launch_services=False):
    digest = image_hash(image)
    mountpoint, home, fixture = (root / name for name in ("mount", "home", "Startup Fixture"))
    for folder in (mountpoint, home, fixture):
        folder.mkdir()
    probe = build_window_probe(root)
    if interactive and subprocess.run([probe, "--check-interaction-access"]).returncode != 0:
        raise RuntimeError("This session lacks macOS Accessibility access for the preview menu")
    app = home / "Files macOS.app"
    with mounted(image, mountpoint) as mounted_app:
        verify_signature(mounted_app)
        run("ditto", mounted_app, app)
    verify_signature(app)
    app_version = version(app)
    isolate(app, bundle_id)
    run("defaults", "write", bundle_id, "startupLocationPath", "-string", fixture)
    run("defaults", "write", bundle_id, "continueLastSession", "-bool", "NO")
    samples = [launch(app, probe, fixture, home, root / "app.log",
                      interactive=interactive, launch_services=launch_services) for _ in range(20)]
    if interactive:
        times = sorted(sample["interactiveSeconds"] for sample in samples)
        return {
            **launch_environment(),
            "imageSHA256": digest,
            "appVersion": app_version,
            "isolatedExecutableSHA256": sha256(app / "Contents/MacOS/FilesMac"),
            "metric": ("Launch Services" if launch_services else "Direct process launch")
                      + " to observing the About window after pressing its menu item through Accessibility",
            "cacheCondition": "Fresh processes; shared OS caches, no cache purge",
            "samples": samples,
            "p95Seconds": times[math.ceil(len(times) * 0.95) - 1],
            "maximumSeconds": times[-1],
        }
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
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--startup", action="store_true", help="Measure 20 launches from one preview image")
    modes.add_argument("--interactive-startup", action="store_true", help="Measure 20 launches through an About menu accessibility action")
    parser.add_argument("--launch-services", action="store_true", help="Use Launch Services for interactive startup measurement")
    parser.add_argument("--run-parent", type=Path, help="Existing directory for the isolated installation and mount")
    args = parser.parse_args()
    if args.launch_services and not args.interactive_startup:
        parser.error("--launch-services requires --interactive-startup")
    startup = args.startup or args.interactive_startup
    if startup and args.candidate is not None:
        parser.error("Startup measurement accepts one preview image")
    if not startup and args.candidate is None:
        parser.error("Installation verification requires a previous and candidate preview image")
    images = [image.resolve() for image in (args.previous, args.candidate) if image is not None]
    if any(image.name != "Files-macOS-preview.dmg" for image in images):
        parser.error("Use local Files-macOS-preview.dmg files")
    if args.run_parent is None:
        run_parent = Path(__file__).resolve().parents[1] / "build"
        run_parent.mkdir(exist_ok=True)
    else:
        run_parent = args.run_parent.resolve()
        if not run_parent.is_dir():
            parser.error("--run-parent must be an existing directory")
    root = Path(tempfile.mkdtemp(prefix="preview-install.", dir=run_parent))
    bundle_id = f"org.taro6222.files-for-mac.qa.{uuid.uuid4()}"
    print(root, flush=True)
    try:
        if startup:
            result = measure_startup(images[0], root, bundle_id, interactive=args.interactive_startup,
                                     launch_services=args.launch_services)
        else:
            result = exercise(*images, root, bundle_id)
        (root / "report.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


if __name__ == "__main__":
    main()
