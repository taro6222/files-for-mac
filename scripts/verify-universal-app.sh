#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/Files macOS.app" >&2
  exit 64
fi
app=$1
plist="$app/Contents/Info.plist"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
if [[ "$executable" != FilesMac || "$minimum" != 14.0 ]]; then
  echo "Expected the FilesMac executable and macOS 14.0 in Info.plist." >&2
  exit 1
fi
binary="$app/Contents/MacOS/$executable"
slices=$(lipo -archs "$binary")
case "$slices" in
  "arm64 x86_64"|"x86_64 arm64") ;;
  *) printf 'Expected arm64 and x86_64; found %s.\n' "$slices" >&2; exit 1 ;;
esac
for architecture in arm64 x86_64; do
  metadata=$(xcrun vtool -arch "$architecture" -show-build "$binary")
  if ! awk -v minimum="$minimum" '
      $1 == "platform" { platform = $2 }
      $1 == "minos" { minos = $2 }
      END { exit !(platform == "MACOS" && minos == minimum) }
    ' <<< "$metadata"; then
    printf '%s must target macOS %s.\n%s\n' "$architecture" "$minimum" "$metadata" >&2
    exit 1
  fi
done
codesign --verify --all-architectures --strict "$app"
printf 'Verified arm64 and x86_64 for macOS %s: %s\n' "$minimum" "$app"
