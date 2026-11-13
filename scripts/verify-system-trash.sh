#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export FILES_TEST_SYSTEM_TRASH=1
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_TMPDIR=/tmp
swift test --filter systemTrashMoveAndRestoreRoundTrip \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
