#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 /Volumes/mounted-smb-share" >&2
  exit 64
fi
cd "$(dirname "$0")/.."
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
swift test --filter mountedSMBCopyMoveUndoRoundTrip \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
