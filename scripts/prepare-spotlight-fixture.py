#!/usr/bin/env python3
"""Index an exact source-code fixture outside the runner's disposable checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import spotlight_volume_fixture as volume_fixture

project = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["prepare", "cleanup"])
parser.add_argument("--state", type=Path, default=project / "build/spotlight-fixture/state.json")
parser.add_argument("--enable-indexing", action="store_true")
parser.add_argument("--isolated-volume", action="store_true")
args = parser.parse_args()
state_path = args.state.resolve()
relative_source = Path("Sources/FilesCore/LocalSearch.swift")
marker_name = ".files-mac-spotlight-qa.json"

def save(value):
    state_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_path.with_suffix(".pending.json")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(state_path)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(arguments, timeout=20):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
        return {"arguments": arguments, "exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    except (OSError, subprocess.SubprocessError) as error:
        return {"arguments": arguments, "exitCode": -1, "stdout": "", "stderr": str(error)}

def indexed_file(root, expected):
    result = subprocess.run(["mdfind", "-0", "-onlyin", str(root), 'kMDItemTextContent == "*SearchRouter*"cd'],
                            capture_output=True, timeout=10)
    if result.returncode:
        raise RuntimeError("Spotlight query failed: " + os.fsdecode(result.stderr))
    hits = [os.fsdecode(value) for value in result.stdout.split(b"\0") if value]
    for hit in hits:
        try:
            if os.path.samefile(hit, expected):
                return hit, hits
        except OSError:
            pass
    return None, hits

if args.action == "cleanup":
    if not state_path.exists():
        print("No Spotlight fixture was created.")
        sys.exit(0)
    state = json.loads(state_path.read_text())
    if state.get("fixtureKind") == "isolated-apfs-volume":
        volume_fixture.cleanup(state, state_path, save)
        sys.exit(0)
    root = Path(state["fixtureRoot"])
    if not root.exists() and not root.is_symlink():
        print("Spotlight fixture is already absent.")
        sys.exit(0)
    info = root.lstat()
    if root.parent.resolve() != Path.home().resolve() or not root.name.startswith("FilesMac-Spotlight-QA.") \
            or not stat.S_ISDIR(info.st_mode) or info.st_dev != state["device"] or info.st_ino != state["inode"]:
        raise SystemExit("Spotlight fixture identity changed; cleanup refused.")
    marker = json.loads((root / marker_name).read_text())
    if marker.get("id") != state["id"] or marker.get("sourceSHA256") != state["sourceSHA256"]:
        raise SystemExit("Spotlight fixture ownership marker changed; cleanup refused.")
    paths = list(root.rglob("*"))
    expected_files = {relative_source.as_posix(), marker_name}
    expected_directories = {"Sources", "Sources/FilesCore"}
    if any(path.is_symlink() for path in paths) \
            or {path.relative_to(root).as_posix() for path in paths if path.is_file()} != expected_files \
            or {path.relative_to(root).as_posix() for path in paths if path.is_dir()} != expected_directories \
            or digest(root / relative_source) != state["sourceSHA256"]:
        raise SystemExit("Spotlight fixture contents changed; cleanup refused.")
    shutil.rmtree(root)
    state["cleaned"] = True
    save(state)
    print("Removed the owned Spotlight source fixture.")
    sys.exit(0)

if state_path.exists():
    prior = json.loads(state_path.read_text())
    if not prior.get("cleaned") and any(Path(prior[key]).exists() for key in ["fixtureRoot", "resourceDirectory"] if prior.get(key)):
        raise SystemExit("An earlier owned fixture still exists; clean it before preparing another one")
source = project / relative_source
state = {"state": "preparing", "id": uuid.uuid4().hex, "sourceSHA256": digest(source),
         "query": 'kMDItemTextContent == "*SearchRouter*"cd', "sourcePublished": False}
try:
    if args.isolated_volume:
        root = volume_fixture.create(state, state_path, save)
    else:
        root = Path(tempfile.mkdtemp(prefix="FilesMac-Spotlight-QA.", dir=Path.home()))
        root.chmod(0o755)
        info = root.lstat()
        state.update(fixtureRoot=str(root), device=info.st_dev, inode=info.st_ino)
    expected = root / relative_source
    state["expectedFile"] = str(expected)
    save(state)
    (root / marker_name).write_text(json.dumps({"id": state["id"], "sourceSHA256": state["sourceSHA256"]}))
    expected.parent.mkdir(parents=True)
    shutil.copy2(source, expected)
    if digest(expected) != state["sourceSHA256"]:
        raise RuntimeError("Copied source fixture differs from the repository source")
    state["sourcePublished"] = True
    save(state)
    if args.enable_indexing:
        if args.isolated_volume:
            volume_fixture.validate_resource(state, state_path)
            volume_fixture.mounted_volume(state)
            state["enableIndexing"] = run(["/usr/bin/mdutil", "-i", "on", state["mountPoint"]])
        else:
            if os.environ.get("GITHUB_ACTIONS") != "true":
                raise RuntimeError("Host indexing configuration is restricted to the disposable GitHub Actions runner")
            state["enableIndexing"] = run(["sudo", "/usr/bin/mdutil", "-i", "on", "/System/Volumes/Data"])
        if state["enableIndexing"]["exitCode"]:
            raise RuntimeError("Could not enable Spotlight indexing on the disposable runner")
    state["import"] = run(["/usr/bin/mdimport", "-i", str(expected)], timeout=30)
    if state["import"]["exitCode"]:
        raise RuntimeError("Spotlight rejected the source fixture import")
    started = time.monotonic()
    indexed = None
    for attempt in range(46):
        indexed, hits = indexed_file(root, expected)
        state["indexHits"] = hits
        if indexed:
            break
        if attempt < 45:
            time.sleep(2)
    state["indexWaitSeconds"] = time.monotonic() - started
    if not indexed:
        raise RuntimeError("Spotlight did not index the exact Swift source fixture")
    state["state"] = "indexed"
    state["indexedFile"] = indexed
    state["searchRoot"] = str(Path(indexed).parents[2])
    save(state)
    if github_env := os.environ.get("GITHUB_ENV"):
        with Path(github_env).open("a") as stream:
            stream.write("FILES_UI_SPOTLIGHT_ROOT=" + state["searchRoot"] + "\n")
    print("Spotlight indexed the unchanged Swift source fixture: " + indexed)
except Exception as error:
    state["state"] = "failed"
    state["error"] = str(error)
    diagnostic_expected = state.get("expectedFile", str(source))
    state["diagnostics"] = [run(command) for command in [
        ["/usr/bin/mdutil", "-s", state.get("mountPoint", "/System/Volumes/Data")],
        ["/usr/bin/mdls", "-name", "kMDItemContentType", "-name", "kMDItemFSName", diagnostic_expected],
        ["/usr/bin/mdimport", "-t", "-d2", diagnostic_expected],
        ["/usr/bin/mdimport", "-L"],
    ]]
    save(state)
    raise SystemExit(str(error))
