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
if ["--close", "--quit"].contains(CommandLine.arguments[1]) {
    guard let pid = pid_t(CommandLine.arguments[2]),
          let application = NSRunningApplication(processIdentifier: pid),
          application.bundleURL?.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
    else { exit(2) }
    if !application.terminate() && CommandLine.arguments[1] == "--quit" { exit(2) }
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while !application.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if !application.isTerminated && CommandLine.arguments[1] == "--close" {
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
if CommandLine.arguments[1] == "--architecture" {
    guard let pid = pid_t(CommandLine.arguments[2]),
          let application = NSRunningApplication(processIdentifier: pid) else { exit(2) }
    switch application.executableArchitecture {
    case Int(NSBundleExecutableArchitectureARM64): print("arm64")
    case Int(NSBundleExecutableArchitectureX86_64): print("x86_64")
    default: exit(2)
    }
    exit(0)
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


def launch(app, probe, fixture, home, log, *, interactive=False, launch_services=False,
           save_session=False, expected_architecture=None):
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
                    if expected_architecture is not None:
                        actual = run(probe, "--architecture", str(pid), capture_output=True, timeout=5).stdout.strip()
                        if actual != expected_architecture:
                            raise RuntimeError(f"Expected app architecture {expected_architecture}, got {actual}")
                    if not interactive:
                        if save_session:
                            run(probe, "--quit", str(pid), app, timeout=8)
                            if process.wait(timeout=5) != 0:
                                raise RuntimeError(f"App did not quit cleanly; see {log}")
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


def measure_startup(image, root, bundle_id, *, interactive=False, launch_services=False,
                    expected_architecture=None):
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
                      interactive=interactive, launch_services=launch_services,
                      expected_architecture=expected_architecture) for _ in range(20)]
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

    mountpoint, home, fixture, session_folder = (
        root / name for name in ("mount", "home", "Install Fixture", "Saved Tab Fixture")
    )
    applications = home / "Applications"
    for folder in (mountpoint, fixture, session_folder, applications):
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
    # Legacy sessions predate workspaceSessionV2 and the tab view/grouping fields.
    legacy_session = [{
        "history": {
            "current": {"url": session_folder.resolve().as_uri() + "/", "selection": [], "scrollOffset": 0},
            "back": [],
            "forward": [],
        },
        "sortOrder": {"field": "name", "ascending": True, "foldersFirst": True},
        "showHidden": False,
    }]
    expected_preferences = {
        "startupLocationPath": str(fixture),
        "continueLastSession": True,
        "favorites": [str(fixture)],
        "showExtensions": False,
    }
    legacy_data = json.dumps(legacy_session).encode()
    prefs = root / "initial-preferences.plist"
    prefs.write_bytes(plistlib.dumps(dict(expected_preferences, tabSession=legacy_data)))
    run("defaults", "import", bundle_id, prefs)
    verified_stages = []

    def verify_user_state(stage, *, has_legacy_session=True):
        exported = subprocess.check_output(["defaults", "export", bundle_id, "-"])
        saved = plistlib.loads(exported)
        for key, value in expected_preferences.items():
            if key not in saved or type(saved[key]) is not type(value) or saved[key] != value:
                raise RuntimeError(f"{stage}: preference changed or missing: {key}")
        if user_file.read_text() != "Preview upgrade fixture\n":
            raise RuntimeError(f"{stage}: user file changed")
        if has_legacy_session and saved.get("tabSession") != legacy_data:
            raise RuntimeError(f"{stage}: legacy session changed or missing")
        verified_stages.append(stage)
        return saved

    initial_time = launch(app, probe, session_folder, home, launch_log)
    verify_user_state("firstInstall")

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
            failure_time = launch(app, probe, session_folder, home, launch_log)
            verify_user_state("afterStagedSignatureFailure")
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
    upgrade_time = launch(app, probe, session_folder, home, launch_log, save_session=True)
    if version(app) != next_version or sha256(installed_binary) != next_binary:
        raise RuntimeError("The installed bundle does not match the candidate")
    saved = verify_user_state("afterReplacement")
    workspace_data = saved["workspaceSessionV2"]
    workspaces = json.loads(workspace_data)
    panes = workspaces[0]["panes"] if len(workspaces) == 1 else []
    if len(panes) != 1 or panes[0]["tab"]["history"]["current"]["url"] != legacy_session[0]["history"]["current"]["url"]:
        raise RuntimeError("Candidate did not save the restored folder in workspaceSessionV2")
    run("defaults", "delete", bundle_id, "tabSession")
    app.rename(staged)
    backup.rename(app)
    rollback_time = launch(app, probe, session_folder, home, launch_log)
    if version(app) != prior_version or sha256(installed_binary) != prior_binary:
        raise RuntimeError("Rollback failed to restore the original bundle")
    saved = verify_user_state("afterRollback", has_legacy_session=False)
    if "tabSession" in saved or saved.get("workspaceSessionV2") != workspace_data:
        raise RuntimeError("Saved workspace changed after rollback")
    return {
        "previousImageSHA256": previous_hash,
        "candidateImageSHA256": candidate_hash,
        "previousVersion": prior_version,
        "candidateVersion": next_version,
        "previousTestExecutableSHA256": prior_binary,
        "candidateTestExecutableSHA256": next_binary,
        **launch_environment(),
        "preservedUserState": {
            "preferenceKeys": list(expected_preferences),
            "verifiedStages": verified_stages,
            "restoredSessionFormats": ["tabSession", "workspaceSessionV2"],
        },
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
    parser.add_argument("--expect-architecture", choices=("arm64", "x86_64"),
                        help="Require this architecture in each launched app process during startup measurement")
    parser.add_argument("--expect-macos", help="Require this exact macOS product version before startup measurement")
    args = parser.parse_args()
    if args.launch_services and not args.interactive_startup:
        parser.error("--launch-services requires --interactive-startup")
    startup = args.startup or args.interactive_startup
    if startup and args.candidate is not None:
        parser.error("Startup measurement accepts one preview image")
    if not startup and args.candidate is None:
        parser.error("Installation verification requires a previous and candidate preview image")
    if not startup and (args.expect_architecture is not None or args.expect_macos is not None):
        parser.error("Environment expectations require a startup measurement")
    if args.expect_macos is not None:
        actual = launch_environment()["macOS"]
        if actual != args.expect_macos:
            parser.error(f"Expected macOS {args.expect_macos}, got {actual}")
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
                                     launch_services=args.launch_services,
                                     expected_architecture=args.expect_architecture)
            if args.expect_architecture is not None:
                result["verifiedAppArchitecture"] = args.expect_architecture
        else:
            result = exercise(*images, root, bundle_id)
        (root / "report.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


if __name__ == "__main__":
    main()
