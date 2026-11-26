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

APP=${FILES_APP_OUTPUT:-build/Files macOS.app}
if [[ -e "$APP" || -L "$APP" ]]; then
  echo "App output already exists; choose a new FILES_APP_OUTPUT path." >&2
  exit 73
fi
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
<key>FilesReleaseChannel</key><string>preview</string>
<key>FilesArchiveSDKVersion</key><string>26.06</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${FILES_SEVENZIP_SOURCE_ARCHIVE:-}" ]]; then
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/sevenzip_bundle.py install --app "$APP" --source-archive "$FILES_SEVENZIP_SOURCE_ARCHIVE"
else
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/sevenzip_bundle.py install --app "$APP"
fi
bash scripts/sign-app.sh "$APP" -
if [[ "$mode" == --universal ]]; then
  bash scripts/verify-universal-app.sh "$APP"
fi
printf 'Built: %s\n' "$APP"
