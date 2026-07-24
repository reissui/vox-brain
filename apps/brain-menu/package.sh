#!/usr/bin/env bash
# Build a standalone release Brain.app, sign it, and archive it.
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_source_root="$(cd "$app_dir/../.." && pwd)"
version="${BRAIN_APP_VERSION:-${1:-}}"
build_number="${BRAIN_APP_BUILD:-}"
source_sha="${BRAIN_APP_SOURCE_SHA:-}"
channel="${BRAIN_APP_CHANNEL:-}"
build_date="${BRAIN_APP_BUILD_DATE:-}"
output_dir="${BRAIN_APP_OUTPUT_DIR:-$app_dir/dist}"
sign_identity="${BRAIN_SIGN_IDENTITY:--}"
plist_source="$app_dir/Resources/Info.plist"
entitlements="$app_dir/Resources/Brain.entitlements"
app_icon="$app_dir/Resources/Brain.icns"

usage() {
  echo "usage: BRAIN_APP_VERSION=1.2.3 BRAIN_APP_BUILD=123 BRAIN_APP_SOURCE_SHA=<40 lowercase hex> BRAIN_APP_CHANNEL=development|test|release BRAIN_APP_BUILD_DATE=YYYY-MM-DDTHH:MM:SSZ [BRAIN_APP_OUTPUT_DIR=path] [BRAIN_SIGN_IDENTITY=identity] $0" >&2
}

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  usage
  echo "error: BRAIN_APP_VERSION must be a three-component semantic version (for example, 1.2.3)" >&2
  exit 64
fi

if ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
  echo "error: BRAIN_APP_BUILD must be numeric" >&2
  exit 64
fi

if ! [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: BRAIN_APP_SOURCE_SHA must be exactly 40 lowercase hexadecimal characters" >&2
  exit 64
fi

if ! [[ "$channel" =~ ^(development|test|release)$ ]]; then
  echo "error: BRAIN_APP_CHANNEL must be development, test, or release" >&2
  exit 64
fi

if ! [[ "$build_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "error: BRAIN_APP_BUILD_DATE must be a canonical UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)" >&2
  exit 64
fi

if [ "$channel" = "release" ] && [ "$sign_identity" = "-" ]; then
  echo "error: release channel rejects ad-hoc signing" >&2
  exit 64
fi

for required in "$plist_source" "$entitlements" "$app_icon"; do
  if [ ! -f "$required" ]; then
    echo "error: required packaging input is missing: $required" >&2
    exit 66
  fi
done

# Source archives deliberately have no Git metadata and rely on the explicit
# provenance inputs above. When packaging from a checkout, reject every tracked,
# staged, untracked, or submodule change before the build can mutate output.
source_root="$(git -C "$app_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$source_root" ]; then
  checkout_sha="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)"
  if [ "$checkout_sha" != "$source_sha" ]; then
    echo "error: BRAIN_APP_SOURCE_SHA must match the checked-out source revision" >&2
    exit 65
  fi
  if ! source_status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)"; then
    echo "error: cannot inspect the Brain source checkout" >&2
    exit 66
  fi
  if [ -n "$source_status" ]; then
    echo "error: Brain.app can only be packaged from a clean source checkout" >&2
    exit 65
  fi
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Brain.app packaging requires macOS" >&2
  exit 69
fi

canonical_build_date="$(
  LC_ALL=C TZ=UTC /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$build_date" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true
)"
if [ "$canonical_build_date" != "$build_date" ]; then
  echo "error: BRAIN_APP_BUILD_DATE is not a valid canonical UTC timestamp" >&2
  exit 64
fi

for command in swift codesign ditto plutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: required packaging command is unavailable: $command" >&2
    exit 69
  fi
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
version_dir="$output_dir/Brain-$version"
app="$version_dir/Brain.app"
archive="$output_dir/Brain-$version.zip"
staging_root="$(mktemp -d "$output_dir/.brain-app-package.XXXXXX")"
staged_app="$staging_root/Brain.app"

cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

echo "Building Brain release executables" >&2
swift build --package-path "$app_dir" --configuration release >&2
binary_dir="$(swift build --package-path "$app_dir" --configuration release --show-bin-path)"
binary="$binary_dir/BrainMenu"
observer_binary="$binary_dir/BrainDictationObserver"
if [ ! -x "$binary" ]; then
  echo "error: Swift release executable was not produced" >&2
  exit 70
fi
if [ ! -x "$observer_binary" ]; then
  echo "error: BrainDictationObserver release executable was not produced" >&2
  exit 70
fi

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Helpers" \
  "$staged_app/Contents/Resources"
install -m 0644 "$plist_source" "$staged_app/Contents/Info.plist"
install -m 0644 "$app_icon" "$staged_app/Contents/Resources/Brain.icns"
install -m 0755 "$binary" "$staged_app/Contents/MacOS/BrainMenu"
install -m 0755 "$observer_binary" "$staged_app/Contents/Helpers/BrainDictationObserver"

runtime="$staged_app/Contents/Resources/BrainRuntime"
mkdir -p "$runtime/scripts" "$runtime/prompts" "$runtime/system/templates"
install -m 0644 "$runtime_source_root/CLAUDE.md" "$runtime/CLAUDE.md"
for prompt in ask digest journal process; do
  install -m 0644 "$runtime_source_root/prompts/$prompt.md" "$runtime/prompts/$prompt.md"
done
for template in daily design meeting note person project source; do
  install -m 0644 "$runtime_source_root/system/templates/$template.md" \
    "$runtime/system/templates/$template.md"
done
for helper in brain build-libraries.py clean_vtt.py design-media design-shot tweet-fetch yt-transcript; do
  install -m 0755 "$runtime_source_root/scripts/$helper" "$runtime/scripts/$helper"
done
install -m 0644 "$runtime_source_root/scripts/requirements.txt" "$runtime/scripts/requirements.txt"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainSourceSHA $source_sha" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainChannel $channel" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainBuildDate $build_date" "$staged_app/Contents/Info.plist"
plutil -lint "$staged_app/Contents/Info.plist" >/dev/null

# Remove checkout metadata before signing. The final app contains only its
# executables, reusable local runtime assets, and Info.plist metadata.
xattr -cr "$staged_app"
strip -x "$staged_app/Contents/MacOS/BrainMenu"
strip -x "$staged_app/Contents/Helpers/BrainDictationObserver"

sign_args=(--force --sign "$sign_identity" --options runtime)
if [ "$sign_identity" = "-" ]; then
  sign_args+=(--timestamp=none)
else
  sign_args+=(--timestamp)
fi

echo "Signing helper executable: Contents/Helpers/BrainDictationObserver" >&2
codesign "${sign_args[@]}" "$staged_app/Contents/Helpers/BrainDictationObserver"
echo "Signing main executable: Contents/MacOS/BrainMenu" >&2
codesign "${sign_args[@]}" "$staged_app/Contents/MacOS/BrainMenu"
echo "Signing outer application: Brain.app" >&2
codesign "${sign_args[@]}" --entitlements "$entitlements" --generate-entitlement-der "$staged_app"

codesign --verify --deep --strict --verbose=2 "$staged_app"

rm -rf "$version_dir"
rm -f "$archive"
mkdir -p "$version_dir"
mv "$staged_app" "$app"

# ditto preserves code-signature extended attributes while keeping the archive
# name stable for a given semantic version.
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

printf '%s\n' "$archive"
