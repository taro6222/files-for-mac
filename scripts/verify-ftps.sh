#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_bin="${PYFTPDLIB_PYTHON:-python3}"
"$python_bin" -c 'import OpenSSL, pyftpdlib' >/dev/null
fixture_root="$(mktemp -d /tmp/files-ftps-fixture.XXXXXX)"
valid_port="$("$python_bin" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
mismatch_port="$("$python_bin" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
username='files-fixture'
password='fixture-password'
printf 'live-ftps-fixture' >"$fixture_root/fixture-한글.txt"
mkdir "$fixture_root/fixture-folder"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Files FTPS Test CA' -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.pem" >/dev/null 2>&1
make_certificate() {
  local name="$1" subject="$2" alt_names="$3"
  /usr/bin/openssl req -newkey rsa:2048 -nodes -subj "/CN=$subject" -keyout "$fixture_root/$name.key" -out "$fixture_root/$name.csr" >/dev/null 2>&1
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$alt_names" >"$fixture_root/$name.ext"
  /usr/bin/openssl x509 -req -days 1 -in "$fixture_root/$name.csr" -CA "$fixture_root/ca.pem" -CAkey "$fixture_root/ca.key" -CAcreateserial -extfile "$fixture_root/$name.ext" -out "$fixture_root/$name.pem" >/dev/null 2>&1
}
make_certificate valid localhost 'DNS:localhost,IP:127.0.0.1'
make_certificate mismatch wrong.example 'DNS:wrong.example'
"$python_bin" scripts/ftps_fixture_server.py --port "$valid_port" --root "$fixture_root" --username "$username" --password "$password" --certificate "$fixture_root/valid.pem" --key "$fixture_root/valid.key" >"$fixture_root/valid.log" 2>&1 &
valid_pid=$!
"$python_bin" scripts/ftps_fixture_server.py --port "$mismatch_port" --root "$fixture_root" --username "$username" --password "$password" --certificate "$fixture_root/mismatch.pem" --key "$fixture_root/mismatch.key" >"$fixture_root/mismatch.log" 2>&1 &
mismatch_pid=$!
cleanup() {
  kill "$valid_pid" "$mismatch_pid" 2>/dev/null || true
  wait "$valid_pid" "$mismatch_pid" 2>/dev/null || true
  rm -rf "$fixture_root"
}
trap cleanup EXIT
for _ in {1..50}; do
  if /usr/bin/curl -q --silent --fail --cacert "$fixture_root/ca.pem" --user "$username:$password" "ftps://localhost:$valid_port/" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
/usr/bin/curl -q --silent --fail --cacert "$fixture_root/ca.pem" --user "$username:$password" "ftps://localhost:$valid_port/" >/dev/null
/usr/bin/env FILES_TEST_FTPS_VALID_PORT="$valid_port" FILES_TEST_FTPS_MISMATCH_PORT="$mismatch_port" \
  FILES_TEST_FTPS_CA="$fixture_root/ca.pem" FILES_TEST_FTP_USERNAME="$username" FILES_TEST_FTP_PASSWORD="$password" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp \
  swift test --filter ftpsLocalFixtureValidatesCertificateAndHostnameThroughRealCurl \
  -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
