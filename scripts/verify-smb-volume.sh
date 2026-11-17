#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || (${2:-} != "" && ${2:-} != --skip-build) ]]; then
  echo "usage: $0 /Volumes/mounted-smb-share [--skip-build]" >&2
  exit 64
fi
python3 - "$1" "$(dirname "$0")/.." "${2:-}" <<'PY'
import os
import signal
import subprocess
import sys
import uuid

volume = os.path.abspath(sys.argv[1])
probe = os.path.join(volume, f".files-smb-probe-{uuid.uuid4()}")
try:
    timeout = int(os.environ.get("FILES_SMB_TIMEOUT_SECONDS", "180"))
    if timeout <= 0:
        raise ValueError
except ValueError:
    sys.exit("FILES_SMB_TIMEOUT_SECONDS must be a positive integer")

# A stalled smbfs can block both preflight and the Swift Testing child.
# Keep the deadline outside the processes making filesystem calls.
command = r'''
volume=$1
probe=$2
build_mode=$3
echo "SMB verification: inspecting mount" >&2
if [[ ! -d "$volume" ]]; then
  echo "SMB path is not a directory: $volume" >&2
  exit 66
fi
device=$(/bin/df -P "$volume" | /usr/bin/awk 'NR == 2 { print $1 }')
filesystem=$(/sbin/mount | /usr/bin/awk -v device="$device" '
  $1 == device {
    if ($0 ~ /\(smbfs([,)])/) print "smbfs"
    else print "other"
    exit
  }
')
if [[ "$filesystem" != "smbfs" ]]; then
  echo "Refusing non-SMB path: $volume is mounted from $device" >&2
  exit 65
fi
if [[ ! -w "$volume" ]]; then
  echo "SMB path is not writable: $volume" >&2
  exit 73
fi
echo "SMB verification: reading share directory" >&2
# Read the directory itself before compiling or launching integration tests.
# This distinguishes a mounted but unresponsive share from a test failure.
if ! /bin/ls -A "$volume" >/dev/null; then
  echo "Could not enumerate SMB directory: $volume" >&2
  exit 74
fi
echo "SMB verification: probing create, read, rename, and delete" >&2
if ! python3 - "$probe" <<'PROBE'
from pathlib import Path
import sys

folder = Path(sys.argv[1])
source = folder / "probe.txt"
destination = folder / "renamed.txt"
payload = b"Files for Mac SMB preflight\n"
print(f"SMB verification: creating probe directory {str(folder)!r}", file=sys.stderr, flush=True)
folder.mkdir(mode=0o700)
try:
    print("SMB verification: writing probe", file=sys.stderr, flush=True)
    with source.open("xb") as stream:
        stream.write(payload)
    print("SMB verification: reading probe", file=sys.stderr, flush=True)
    if source.read_bytes() != payload:
        raise OSError("SMB probe read did not match the written bytes")
    print("SMB verification: renaming probe", file=sys.stderr, flush=True)
    source.rename(destination)
    if destination.read_bytes() != payload or source.exists():
        raise OSError("SMB probe rename did not preserve the expected result")
finally:
    print("SMB verification: removing probe", file=sys.stderr, flush=True)
    source.unlink(missing_ok=True)
    destination.unlink(missing_ok=True)
    folder.rmdir()
PROBE
then
  echo "Could not complete file operations on SMB share: $volume" >&2
  exit 75
fi
echo "SMB verification: running file operation tests" >&2
export FILES_TEST_SMB_VOLUME="$volume"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_TMPDIR=/tmp
test_filter='mountedSMB(CopyMoveUndoRoundTrip|ReadOnlyRejectsWrites|ReconnectSeesServerChanges|TransferTimestamps|ReconnectDuringReplacementMove|ReconnectDuringPayloadWrite)'
if [[ "$build_mode" == --skip-build ]]; then
  exec swift test --skip-build --disable-xctest --no-parallel --filter "$test_filter"
fi
exec swift test --filter "$test_filter" \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
'''

process = subprocess.Popen(
    ["/bin/bash", "-euo", "pipefail", "-c", command, "verify-smb-volume", volume, probe, sys.argv[3]],
    cwd=sys.argv[2],
    start_new_session=True,
)
try:
    sys.exit(process.wait(timeout=timeout))
except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if isinstance(error, KeyboardInterrupt):
        sys.exit(130)
    print(f"SMB verification timed out after {timeout}s: {volume}", file=sys.stderr)
    sys.exit(124)
PY
