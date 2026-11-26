#!/bin/bash
set -euo pipefail

finder_app=""
if [[ ${1-} == --installed-app && $# -ge 2 ]]; then
  finder_app=$2
  if [[ ${finder_app##*/} != "Files macOS.app" || ! -d "$finder_app" ]]; then
    echo "Expected the Finder-installed Files macOS.app bundle." >&2
    exit 64
  fi
  shift 2
fi
if [[ $# -lt 1 || $# -gt 3 || ${1##*/} != Files-macOS.dmg ]]; then
  echo "Usage: $0 [--installed-app '/Applications/Files macOS.app'] /path/to/Files-macOS.dmg [expected-Team-ID [expected-SHA-256]]" >&2
  exit 64
fi
release_team=${2-}
if [[ $# -ge 2 && ! "$release_team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Expected a 10-character Developer ID Team ID." >&2
  exit 64
fi
release_sha=${3-}
if [[ $# -eq 3 && ! "$release_sha" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Expected a lowercase 64-character SHA-256." >&2
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
if [[ -n "$release_sha" && "$expected" != "$release_sha" ]]; then
  echo "Downloaded image does not match the expected release SHA-256." >&2
  exit 65
fi

/usr/bin/hdiutil verify "$image"
developer_id='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
verify_private_code() {
  local bundle=$1
  PYTHONDONTWRITEBYTECODE=1 python3 "$script_dir/sevenzip_bundle.py" verify --app "$bundle"
  for component in Contents/Helpers/SevenZipWorker Contents/Helpers/7z.so; do
    /usr/bin/codesign --verify --all-architectures --strict -R "=$developer_id" "$bundle/$component"
  done
}
if [[ -n "$release_team" ]]; then
  developer_id+=" and certificate leaf[subject.OU] = \"$release_team\""
fi
/usr/bin/codesign --verify --strict --verbose=2 -R "=$developer_id" "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"

verify_dir=$(mktemp -d "${TMPDIR:-/tmp}/files-verify-dmg.XXXXXX")
mount_dir="$verify_dir/mount"
mkdir "$mount_dir"
mounted=false
cleanup() {
  rm -rf -- "$verify_dir/installation"
  if "$mounted" && ! /usr/bin/hdiutil detach "$mount_dir" >/dev/null; then
    echo "Could not detach verification mount: $mount_dir" >&2
    return 1
  fi
  rmdir "$mount_dir"
  rmdir "$verify_dir"
}
trap cleanup EXIT
/usr/bin/hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mount_dir"
mounted=true
app="$mount_dir/Files macOS.app"
bash "$script_dir/verify-dmg-contents.sh" "$mount_dir"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :FilesReleaseChannel' "$app/Contents/Info.plist")" != stable ]]; then
  echo "The release app must declare the stable update channel." >&2
  exit 65
fi
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
verify_private_code "$app"
/usr/bin/syspolicy_check distribution "$app"
installation="$verify_dir/installation"
mkdir "$installation"
installed_app="$installation/Files macOS.app"
/usr/bin/ditto "$app" "$installed_app"
/usr/bin/codesign --verify --all-architectures --strict -R "=$developer_id" "$installed_app"
verify_private_code "$installed_app"
/usr/bin/syspolicy_check distribution "$installed_app"
printf 'Release image, mounted app, and copied app passed verification: %s\n' "$image"
if [[ -n "$finder_app" ]]; then
  if ! /usr/bin/xattr -p com.apple.quarantine "$image" >/dev/null; then
    echo "Use a downloaded release image with its quarantine attribute intact." >&2
    exit 65
  fi
  /usr/bin/codesign --verify --all-architectures --strict -R "=$developer_id" "$finder_app"
  verify_private_code "$finder_app"
  /usr/bin/syspolicy_check distribution "$finder_app"
  cdhash() {
    /usr/bin/codesign --display --arch "$1" --verbose=4 -- "$2" 2>&1 | awk -F= '$1 == "CDHash" { print $2 }'
  }
  for arch in arm64 x86_64; do
    mounted_hash=$(cdhash "$arch" "$app")
    finder_hash=$(cdhash "$arch" "$finder_app")
    if [[ -z "$mounted_hash" || "$mounted_hash" != "$finder_hash" ]]; then
      echo "Finder-installed app differs from the released $arch app." >&2
      exit 65
    fi
  done
  native_arch=x86_64
  if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]]; then
    native_arch=arm64
  fi
  python3 "$script_dir/verify-preview-install.py" --inspect-installed --expect-architecture "$native_arch" "$finder_app"
  printf 'Observed the browser window of the installed release. DMG SHA-256: %s\n' "$expected"
fi
