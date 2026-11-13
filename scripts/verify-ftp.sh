#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_bin="${PYFTPDLIB_PYTHON:-python3}"
"$python_bin" -c 'import pyftpdlib' >/dev/null
fixture_root="$(mktemp -d /tmp/files-ftp-fixture.XXXXXX)"
port="$("$python_bin" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
username='files-fixture'
password='fixture-password'
printf 'live-fixture' >"$fixture_root/fixture-한글.txt"
"$python_bin" -m pyftpdlib -i 127.0.0.1 -p "$port" -u "$username" -P "$password" -d "$fixture_root" -w >"$fixture_root/server.log" 2>&1 &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$fixture_root"; }
trap cleanup EXIT
for _ in {1..50}; do
  if /usr/bin/curl -q --silent --fail --user "$username:$password" "ftp://127.0.0.1:$port/" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
/usr/bin/curl -q --silent --fail --user "$username:$password" "ftp://127.0.0.1:$port/" >/dev/null
/usr/bin/env FILES_TEST_FTP_PORT="$port" FILES_TEST_FTP_USERNAME="$username" FILES_TEST_FTP_PASSWORD="$password" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp \
  swift test --filter ftpLocalFixtureListsAndDownloadsThroughRealCurl \
  -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
