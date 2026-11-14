#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 /path/to/mounted-image-or-staged-contents" >&2
  exit 64
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
root=$1
app="$root/Files macOS.app"

fail() {
  printf 'Invalid DMG contents: %s\n' "$1" >&2
  exit 65
}

shopt -s dotglob nullglob
entries=("$root"/*)
[[ ${#entries[@]} -eq 4 && -d "$app" && ! -L "$app" ]] ||
  fail "Expected the app, Applications link, license and release notes."
[[ -L "$root/Applications" && $(readlink "$root/Applications") == /Applications ]] ||
  fail "Applications must link to /Applications."

license="$app/Contents/Resources/LICENSE.txt"
for item in "$license" "$root/LICENSE.txt" "$root/Release Notes.txt"; do
  [[ -f "$item" && ! -L "$item" ]] || fail "Expected a regular file at $item."
done
cmp -s "$license" "$repo_dir/LICENSE" && cmp -s "$root/LICENSE.txt" "$license" ||
  fail "The app and image licenses must match the project license."
cmp -s "$root/Release Notes.txt" "$repo_dir/docs/RELEASE_NOTES.md" ||
  fail "Release notes must match the source used to verify this image."

# The packaged app currently has only its executable, plist, signature and license.
bundle_entries=("$app"/*)
contents=("$app/Contents"/*)
executables=("$app/Contents/MacOS"/*)
resources=("$app/Contents/Resources"/*)
[[ ${#bundle_entries[@]} -eq 1 && ${#contents[@]} -eq 4 && ${#executables[@]} -eq 1 && ${#resources[@]} -eq 1 ]] ||
  fail "Unexpected files in the app bundle."
for directory in Contents Contents/MacOS Contents/Resources Contents/_CodeSignature; do
  [[ -d "$app/$directory" && ! -L "$app/$directory" ]] || fail "Invalid bundle directory: $directory."
done

plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/FilesMac"
for item in "$plist" "$binary"; do
  [[ -f "$item" && ! -L "$item" ]] || fail "Expected a regular file at $item."
done
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
[[ "$identifier" == org.taro6222.files-for-mac ]] || fail "Unexpected app bundle identifier."
IFS= read -r heading < "$root/Release Notes.txt"
[[ -n "$version" && "$heading" == "# Files macOS $version" ]] ||
  fail "The release notes heading does not match the app version."

bash "$script_dir/verify-universal-app.sh" "$app"
for architecture in arm64 x86_64; do
  dependencies=$(otool -arch "$architecture" -L "$binary")
  awk '$1 == "/usr/lib/libarchive.2.dylib" { found = 1 } END { exit !found }' <<< "$dependencies" ||
    fail "$architecture must link to the macOS libarchive."
done
printf 'Verified DMG contents for Files macOS %s.\n' "$version"
