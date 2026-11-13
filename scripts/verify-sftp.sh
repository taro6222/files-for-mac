#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_root="$(mktemp -d /tmp/files-sftp-fixture.XXXXXX)"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
username="$(id -un)"
remote_root="$fixture_root/remote"
mkdir -p "$remote_root"
printf 'live-fixture' >"$remote_root/fixture-한글.txt"
/usr/sbin/mkfile -n 256m "$remote_root/large-fixture.bin"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/client_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/wrong_host_key"
cp "$fixture_root/client_key.pub" "$fixture_root/authorized_keys"
chmod 600 "$fixture_root/client_key" "$fixture_root/authorized_keys"
host_public="$(cut -d' ' -f1-2 "$fixture_root/host_key.pub")"
printf '[127.0.0.1]:%s %s\n' "$port" "$host_public" >"$fixture_root/known_hosts"
wrong_host_public="$(cut -d' ' -f1-2 "$fixture_root/wrong_host_key.pub")"
printf '[127.0.0.1]:%s %s\n' "$port" "$wrong_host_public" >"$fixture_root/wrong_known_hosts"
chmod 600 "$fixture_root/known_hosts" "$fixture_root/wrong_known_hosts"
printf '%s\n' \
  "Port $port" \
  'ListenAddress 127.0.0.1' \
  "HostKey $fixture_root/host_key" \
  "PidFile $fixture_root/sshd.pid" \
  "AuthorizedKeysFile $fixture_root/authorized_keys" \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'UsePAM no' \
  'StrictModes no' \
  'PermitRootLogin no' \
  'Subsystem sftp internal-sftp' >"$fixture_root/sshd_config"
/usr/sbin/sshd -D -e -f "$fixture_root/sshd_config" >"$fixture_root/server.log" 2>&1 &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$fixture_root"; }
trap cleanup EXIT
for _ in {1..50}; do
  if /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
/usr/bin/nc -z 127.0.0.1 "$port" >/dev/null
printf 'ls -1 "%s"\n' "$remote_root" | /usr/bin/sftp -q -b - -P "$port" -i "$fixture_root/client_key" \
  -o "UserKnownHostsFile=$fixture_root/known_hosts" -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes "$username@127.0.0.1"
/usr/bin/env FILES_TEST_SFTP_PORT="$port" FILES_TEST_SFTP_USERNAME="$username" \
  FILES_TEST_SFTP_IDENTITY="$fixture_root/client_key" FILES_TEST_SFTP_KNOWN_HOSTS="$fixture_root/known_hosts" \
  FILES_TEST_SFTP_WRONG_KNOWN_HOSTS="$fixture_root/wrong_known_hosts" \
  FILES_TEST_SFTP_REMOTE_ROOT="$remote_root" FILES_TEST_SFTP_LARGE_REMOTE="$remote_root/large-fixture.bin" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFT_TMPDIR=/tmp \
  swift test --filter sftpLocalFixtureListsDownloadsAndProbesRenameThroughOpenSSH \
  -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
