#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(/usr/bin/mktemp -d /tmp/files-volume-matrix.XXXXXX)
devices=()
cleanup() {
  for ((index=${#devices[@]}-1; index>=0; index--)); do
    /usr/bin/hdiutil detach "${devices[$index]}" >/dev/null 2>&1 || true
  done
  /bin/rm -rf "$root"
}
trap cleanup EXIT INT TERM
create_volume() {
  local name=$1 filesystem=$2 variable=$3
  local image="$root/$name.dmg" mount="$root/$name"
  /bin/mkdir -p "$mount"
  /usr/bin/hdiutil create -size 96m -fs "$filesystem" -volname "FilesM2-$name" "$image" >/dev/null
  local output device
  output=$(/usr/bin/hdiutil attach -mountpoint "$mount" "$image")
  device=$(printf '%s\n' "$output" | /usr/bin/awk 'NR == 1 { print $1 }')
  devices+=("$device")
  printf -v "$variable" '%s' "$mount"
  export "$variable"
}
create_exfat_volume() {
  local raw="$root/exfat.raw" output device mount label="FM2$$"
  /usr/sbin/mkfile 256m "$raw"
  output=$(/usr/bin/hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$raw")
  device=$(printf '%s\n' "$output" | /usr/bin/awk 'NR == 1 { print $1 }')
  devices+=("$device")
  /usr/sbin/diskutil eraseVolume ExFAT "$label" "$device" >/dev/null
  mount=$(/usr/sbin/diskutil info "$device" | /usr/bin/awk -F ': *' '/Mount Point/ { print $2; exit }')
  test -n "$mount" -a -d "$mount"
  export FILES_TEST_EXFAT_VOLUME="$mount"
}
create_volume apfs APFS FILES_TEST_APFS_VOLUME
create_volume apfsx "Case-sensitive APFS" FILES_TEST_APFSX_VOLUME
create_exfat_volume
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_TMPDIR=/tmp
swift test --filter mountedVolume \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
