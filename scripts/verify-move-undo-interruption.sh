#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d /tmp/files-undo-interruption.XXXXXX)
device=
cleanup() {
  if [[ -n "$device" ]]; then /usr/bin/hdiutil detach "$device" >/dev/null || return; fi
  rm -rf -- "$root"
}
trap cleanup EXIT
mkdir "$root/mount"
hdiutil create -size 96m -fs APFS -volname FilesUndoInterruption "$root/fixture.dmg" >/dev/null
attached=$(hdiutil attach -mountpoint "$root/mount" "$root/fixture.dmg")
device=$(awk 'NR == 1 { print $1 }' <<< "$attached")
export FILES_UNDO_INTERRUPTION_ROOT="$root"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp
test_args=(--filter moveUndoInterruptionWorker -Xswiftc -load-plugin-library
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib)
status=0
FILES_UNDO_INTERRUPTION_PHASE=interrupt swift test "${test_args[@]}" > "$root/interrupt.log" 2>&1 || status=$?
if [[ "$status" == 0 || ! -f "$root/copy-published" ]]; then
  cat "$root/interrupt.log"
  echo "Expected the test worker to be killed after copy publication." >&2
  exit 1
fi
FILES_UNDO_INTERRUPTION_PHASE=resume swift test "${test_args[@]}"
