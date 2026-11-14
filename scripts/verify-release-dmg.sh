#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ${1##*/} != Files-macOS.dmg ]]; then
  echo "Usage: $0 /path/to/Files-macOS.dmg" >&2
  exit 64
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
image="$(cd "$(dirname "$1")" && pwd)/Files-macOS.dmg"
expected=$(awk '
  NR == 1 && NF == 2 && $2 == "Files-macOS.dmg" && length($1) == 64 && $1 !~ /[^0-9a-f]/ { digest = $1 }
  END { if (NR != 1 || digest == "") exit 1; print digest }
' "$image.sha256") || { echo "Invalid release checksum manifest." >&2; exit 65; }
actual=$(shasum -a 256 < "$image")
if [[ "${actual%% *}" != "$expected" ]]; then
  echo "Release checksum mismatch." >&2
  exit 65
fi

/usr/bin/hdiutil verify "$image"
codesign --verify --strict --verbose=2 "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"

mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/files-verify-dmg.XXXXXX")
mounted=false
cleanup() {
  if "$mounted"; then /usr/bin/hdiutil detach "$mount_dir" >/dev/null; fi
  rmdir "$mount_dir"
}
trap cleanup EXIT
/usr/bin/hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mount_dir"
mounted=true
app="$mount_dir/Files macOS.app"
bash "$script_dir/verify-universal-app.sh" "$app"
/usr/bin/syspolicy_check distribution "$app"
printf 'Release image and app passed verification: %s\n' "$image"
