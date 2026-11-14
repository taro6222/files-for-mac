#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-}
case "$mode" in
  --preview)
    file_name="Files-macOS-preview.dmg"
    ;;
  --release)
    : "${FILES_SIGNING_IDENTITY:?Set FILES_SIGNING_IDENTITY to an installed Developer ID Application identity}"
    : "${FILES_NOTARY_PROFILE:?Set FILES_NOTARY_PROFILE to an existing notarytool Keychain profile}"
    case "$FILES_SIGNING_IDENTITY" in
      "Developer ID Application: "*) ;;
      *) echo "The release requires a Developer ID Application identity." >&2; exit 64 ;;
    esac
    if ! security find-identity -v -p codesigning | grep -F -- "\"$FILES_SIGNING_IDENTITY\"" >/dev/null; then
      echo "The requested Developer ID Application identity is unavailable." >&2
      exit 69
    fi
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    file_name="Files-macOS.dmg"
    ;;
  *) echo "Usage: $0 --preview | --release" >&2; exit 64 ;;
esac

scripts/build-app.sh
stage=$(mktemp -d "${TMPDIR:-/tmp}/files-dmg.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
app="$stage/contents/Files macOS.app"
mkdir -p "$stage/contents"
ditto "build/Files macOS.app" "$app"
ln -s /Applications "$stage/contents/Applications"
if [[ "$mode" == --release ]]; then
  codesign --force --options runtime --timestamp --sign "$FILES_SIGNING_IDENTITY" "$app"
fi
codesign --verify --strict --verbose=2 "$app"

image="$stage/$file_name"
/usr/bin/hdiutil create -volname "Files macOS" -srcfolder "$stage/contents" -format UDZO "$image"
/usr/bin/hdiutil verify "$image"
if [[ "$mode" == --release ]]; then
  codesign --timestamp --sign "$FILES_SIGNING_IDENTITY" "$image"
  xcrun notarytool submit "$image" --keychain-profile "$FILES_NOTARY_PROFILE" --wait
  xcrun stapler staple "$image"
  xcrun stapler validate "$image"
  codesign --verify --verbose=2 "$image"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi

mv -f -- "$image" "build/$file_name"
(cd build && shasum -a 256 "$file_name" > "$file_name.sha256")
printf 'Built %s\n' "$PWD/build/$file_name"
