#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 /Volumes/mounted-smb-share" >&2
  exit 64
fi
python3 - "$1" "$(dirname "$0")/.." <<'PY'
import os
import signal
import subprocess
import sys

volume = os.path.abspath(sys.argv[1])
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
export FILES_TEST_SMB_VOLUME="$volume"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_TMPDIR=/tmp
exec swift test --filter mountedSMBCopyMoveUndoRoundTrip \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
'''

process = subprocess.Popen(
    ["/bin/bash", "-euo", "pipefail", "-c", command, "verify-smb-volume", volume],
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
