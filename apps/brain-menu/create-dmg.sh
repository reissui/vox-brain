#!/usr/bin/env bash
# Package a signed Brain.app in a drag-to-Applications disk image.
set -euo pipefail

app="${BRAIN_DMG_APP:-${1:-}}"
output="${BRAIN_DMG_OUTPUT:-${2:-}}"
sign_identity="${BRAIN_DMG_SIGN_IDENTITY:--}"
volume_name="${BRAIN_DMG_VOLUME_NAME:-Brain}"

usage() {
  echo "usage: BRAIN_DMG_APP=/path/to/Brain.app BRAIN_DMG_OUTPUT=/path/to/Brain-version.dmg [BRAIN_DMG_SIGN_IDENTITY=identity] [BRAIN_DMG_VOLUME_NAME=Brain] $0" >&2
}

if [ -z "$app" ] || [ -z "$output" ]; then
  usage
  exit 64
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Brain disk-image packaging requires macOS" >&2
  exit 69
fi

for command in codesign ditto hdiutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: required disk-image command is unavailable: $command" >&2
    exit 69
  fi
done

if [ ! -d "$app" ] || [ ! -x "$app/Contents/MacOS/BrainMenu" ]; then
  echo "error: BRAIN_DMG_APP must identify a packaged Brain.app" >&2
  exit 66
fi

if [[ "$output" != *.dmg ]]; then
  echo "error: BRAIN_DMG_OUTPUT must end in .dmg" >&2
  exit 64
fi

codesign --verify --deep --strict --verbose=2 "$app"

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd)"
output="$output_parent/$(basename "$output")"
staging_root="$(mktemp -d "$output_parent/.brain-dmg.XXXXXX")"

cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

ditto "$app" "$staging_root/Brain.app"
ln -s /Applications "$staging_root/Applications"

rm -f "$output"
hdiutil create \
  -volname "$volume_name" \
  -fs HFS+ \
  -format UDZO \
  -srcfolder "$staging_root" \
  -ov \
  "$output" >/dev/null

sign_args=(--force --sign "$sign_identity")
if [ "$sign_identity" = "-" ]; then
  sign_args+=(--timestamp=none)
else
  sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$output"
codesign --verify --verbose=2 "$output"

printf '%s\n' "$output"
