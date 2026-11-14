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

scripts/build-app.sh --universal
stage=$(mktemp -d "$PWD/build/.files-dmg.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
app="$stage/contents/Files macOS.app"
mkdir -p "$stage/contents"
ditto "build/Files macOS.app" "$app"
ln -s /Applications "$stage/contents/Applications"
cp LICENSE "$stage/contents/LICENSE.txt"
cp docs/RELEASE_NOTES.md "$stage/contents/Release Notes.txt"
if [[ "$mode" == --release ]]; then
  codesign --force --options runtime --timestamp --sign "$FILES_SIGNING_IDENTITY" "$app"
fi
scripts/verify-dmg-contents.sh "$stage/contents"

image="$stage/$file_name"
/usr/bin/hdiutil create -volname "Files macOS" -srcfolder "$stage/contents" -format UDZO "$image"
if [[ "$mode" == --release ]]; then
  codesign --timestamp --sign "$FILES_SIGNING_IDENTITY" "$image"
  response="$stage/notarization.plist"
  if ! xcrun notarytool submit "$image" --keychain-profile "$FILES_NOTARY_PROFILE" \
      --wait --output-format plist > "$response"; then
    echo "Notarization submission failed." >&2
    /usr/libexec/PlistBuddy -c 'Print :id' "$response" >&2 || true
    exit 1
  fi
  submission=$(/usr/libexec/PlistBuddy -c 'Print :id' "$response")
  status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$response")
  printf 'Notarization submission %s: %s\n' "$submission" "$status"
  if [[ "$status" != Accepted ]]; then
    echo "The release image was not accepted for notarization." >&2
    exit 1
  fi
  xcrun stapler staple "$image"
  xcrun stapler validate "$image"
  codesign --verify --verbose=2 "$image"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi
/usr/bin/hdiutil verify "$image"
(cd "$stage" && shasum -a 256 "$file_name" > "$file_name.sha256")

mv -f -- "$image" "build/$file_name"
mv -f -- "$stage/$file_name.sha256" "build/$file_name.sha256"
printf 'Built %s\n' "$PWD/build/$file_name"
