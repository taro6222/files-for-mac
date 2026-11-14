#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mode=${1:-}
case "$mode" in
  "") ;;
  --universal) ;;
  *) echo "Usage: $0 [--universal]" >&2; exit 64 ;;
esac

APP="build/Files macOS.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
if [[ "$mode" == --universal ]]; then
  for architecture in arm64 x86_64; do
    scratch="$PWD/build/swiftpm-$architecture"
    triple="$architecture-apple-macosx14.0"
    swift build --scratch-path "$scratch" --triple "$triple" -c release --disable-sandbox
    bin_path=$(swift build --scratch-path "$scratch" --triple "$triple" -c release --show-bin-path)
    if [[ "$architecture" == arm64 ]]; then arm_app="$bin_path/FilesMac"; else intel_app="$bin_path/FilesMac"; fi
  done
  lipo -create "$arm_app" "$intel_app" -output "$APP/Contents/MacOS/FilesMac"
  slices=$(lipo -archs "$APP/Contents/MacOS/FilesMac")
  for architecture in arm64 x86_64; do
    if [[ " $slices " != *" $architecture "* ]]; then
      echo "Missing architecture: $architecture" >&2
      exit 1
    fi
  done
else
  swift build -c release --disable-sandbox
  bin_path=$(swift build -c release --show-bin-path)
  cp "$bin_path/FilesMac" "$APP/Contents/MacOS/FilesMac"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FilesMac</string>
<key>CFBundleIdentifier</key><string>org.taro6222.files-for-mac</string>
<key>CFBundleName</key><string>Files macOS</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
