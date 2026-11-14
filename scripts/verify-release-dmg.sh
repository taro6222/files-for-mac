#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ${1##*/} != Files-macOS.dmg ]]; then
  echo "Usage: $0 /path/to/Files-macOS.dmg [expected-Team-ID]" >&2
  exit 64
fi
release_team=${2-}
if [[ $# -eq 2 && ! "$release_team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Expected a 10-character Developer ID Team ID." >&2
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
developer_id='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
if [[ -n "$release_team" ]]; then
  developer_id+=" and certificate leaf[subject.OU] = \"$release_team\""
fi
/usr/bin/codesign --verify --strict --verbose=2 -R "=$developer_id" "$image"
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
bash "$script_dir/verify-dmg-contents.sh" "$mount_dir"
if [[ -z "$release_team" ]]; then
  signature=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)
  team=$(awk -F= '/^TeamIdentifier=/ { print $2 }' <<< "$signature")
  if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "The release app has no valid signing Team ID." >&2
    exit 65
  fi
  developer_id+=" and certificate leaf[subject.OU] = \"$team\""
  /usr/bin/codesign --verify --strict -R "=$developer_id" "$image"
fi
/usr/bin/codesign --verify --all-architectures --strict -R "=$developer_id" "$app"
/usr/bin/syspolicy_check distribution "$app"
printf 'Release image and app passed verification: %s\n' "$image"
