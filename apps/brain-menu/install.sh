#!/usr/bin/env bash
# Build, sign, and atomically install the local Brain menu-bar application.
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
destination="${BRAIN_MENU_APP_DEST:-$HOME/Applications/Brain.app}"
destination_parent="$(dirname "$destination")"
destination_name="$(basename "$destination")"
entitlements="$app_dir/Resources/Brain.entitlements"
app_icon="$app_dir/Resources/Brain.icns"
canonical_destination="$HOME/Applications/Brain.app"
manage_privacy="${BRAIN_MENU_MANAGE_PRIVACY:-}"
requested_sign_identity="${BRAIN_SIGN_IDENTITY:-auto}"
lsregister="${BRAIN_MENU_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
tccutil="${BRAIN_MENU_TCCUTIL:-$(command -v tccutil || true)}"
source_root="$(git -C "$app_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$source_root" ]; then
  echo "error: cannot determine the Brain source checkout" >&2
  exit 66
fi
if ! source_status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)"; then
  echo "error: cannot inspect the Brain source checkout" >&2
  exit 66
fi
if [ -n "$source_status" ]; then
  echo "error: Brain.app can only be installed from a clean source checkout" >&2
  exit 65
fi
revision_count="$(git -C "$source_root" rev-list --count HEAD 2>/dev/null || true)"
source_sha="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)"
app_version="${BRAIN_APP_VERSION:-0.0.$revision_count}"
build_number="${BRAIN_APP_BUILD:-$revision_count}"
build_channel="development"
build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! [[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: BRAIN_APP_VERSION must be a three-component semantic version" >&2
  exit 64
fi
if ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
  echo "error: BRAIN_APP_BUILD must be numeric" >&2
  exit 64
fi
if ! [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: the Brain source revision must be a full 40-character Git SHA" >&2
  exit 66
fi

sign_identity="$requested_sign_identity"
if [ "$requested_sign_identity" = "auto" ]; then
  sign_identity="-"
  if [ "$destination" = "$canonical_destination" ] && command -v security >/dev/null 2>&1; then
    discovered_identity="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Apple Development:/ { print $2; exit }'
    )" || discovered_identity=""
    if [ -n "$discovered_identity" ]; then
      sign_identity="$discovered_identity"
    fi
  fi
fi

if [ -z "$manage_privacy" ]; then
  if [ "$destination" = "$canonical_destination" ]; then
    manage_privacy=1
  else
    manage_privacy=0
  fi
fi
if [ "$manage_privacy" != "0" ] && [ "$manage_privacy" != "1" ]; then
  echo "error: BRAIN_MENU_MANAGE_PRIVACY must be 0 or 1" >&2
  exit 64
fi
if [ "$manage_privacy" = "1" ]; then
  [ -x "$lsregister" ] || { echo "error: LaunchServices registration tool is unavailable" >&2; exit 69; }
  [ -n "$tccutil" ] && [ -x "$tccutil" ] \
    || { echo "error: tccutil is unavailable" >&2; exit 69; }
fi

designated_requirement() {
  codesign -dr - "$1" 2>&1 \
    | sed -nE 's/^#?[[:space:]]*designated =>[[:space:]]*//p'
}

old_requirement=""
if [ -e "$destination" ]; then
  old_requirement="$(designated_requirement "$destination" || true)"
fi

mkdir -p "$destination_parent"
staging_root="$(mktemp -d "$destination_parent/.brain-menu-install.XXXXXX")"
staged_app="$staging_root/$destination_name"

cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

swift build --package-path "$app_dir" --configuration release --product BrainMenu
swift build --package-path "$app_dir" --configuration release --product BrainDictationObserver
binary_dir="$(swift build --package-path "$app_dir" --configuration release --show-bin-path)"

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Helpers" \
  "$staged_app/Contents/Resources"
install -m 0644 "$app_dir/Resources/Info.plist" "$staged_app/Contents/Info.plist"
install -m 0644 "$app_icon" "$staged_app/Contents/Resources/Brain.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainSourceSHA $source_sha" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainChannel $build_channel" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :BrainBuildDate $build_date" "$staged_app/Contents/Info.plist"
install -m 0755 "$binary_dir/BrainMenu" "$staged_app/Contents/MacOS/BrainMenu"
install -m 0755 "$binary_dir/BrainDictationObserver" "$staged_app/Contents/Helpers/BrainDictationObserver"

runtime="$staged_app/Contents/Resources/BrainRuntime"
mkdir -p "$runtime/scripts" "$runtime/prompts" "$runtime/system/templates"
install -m 0644 "$source_root/CLAUDE.md" "$runtime/CLAUDE.md"
for prompt in ask digest journal process; do
  install -m 0644 "$source_root/prompts/$prompt.md" "$runtime/prompts/$prompt.md"
done
for template in daily design meeting note person project source; do
  install -m 0644 "$source_root/system/templates/$template.md" \
    "$runtime/system/templates/$template.md"
done
for helper in brain build-libraries.py clean_vtt.py design-media design-shot tweet-fetch yt-transcript; do
  install -m 0755 "$source_root/scripts/$helper" "$runtime/scripts/$helper"
done
install -m 0644 "$source_root/scripts/requirements.txt" "$runtime/scripts/requirements.txt"

codesign --force --sign "$sign_identity" --timestamp=none "$staged_app/Contents/Helpers/BrainDictationObserver"
codesign --force --sign "$sign_identity" --timestamp=none "$staged_app/Contents/MacOS/BrainMenu"
codesign --force --sign "$sign_identity" --timestamp=none --entitlements "$entitlements" \
  --generate-entitlement-der "$staged_app"
codesign --verify --deep --strict "$staged_app"
new_requirement="$(designated_requirement "$staged_app")"

identity_changed=0
if [ "$manage_privacy" = "1" ] \
  && { [ -z "$old_requirement" ] || [ "$old_requirement" != "$new_requirement" ]; }; then
  identity_changed=1
fi

if [ "$manage_privacy" = "1" ] && [ -e "$destination" ]; then
  osascript -e 'tell application id "app.voxbrain.menu" to quit' >/dev/null 2>&1 || true
  "$lsregister" -u "$destination" >/dev/null 2>&1 || true
fi

# Keep staging beside the destination so the final replacement stays on one
# volume. FileManager's replace operation gives existing installs safe-save
# semantics; a first install is a single rename from the sibling staging path.
if [ -e "$destination" ]; then
  swift - "$staged_app" "$destination" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let stagedURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
_ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
SWIFT
else
  mv "$staged_app" "$destination"
fi

if [ "$manage_privacy" = "1" ]; then
  "$lsregister" -gc >/dev/null 2>&1 || true
  "$lsregister" -f "$destination" >/dev/null
  if [ "$identity_changed" = "1" ]; then
    for service in ScreenCapture AudioCapture Microphone Accessibility ListenEvent; do
      "$tccutil" reset "$service" app.voxbrain.menu >/dev/null 2>&1 || true
    done
    echo "Reset Brain privacy grants because the local development signature changed."
  fi
fi

if [ "${BRAIN_NO_OPEN:-0}" != "1" ]; then
  open "$destination"
fi

echo "Installed Brain $app_version ($build_number, $source_sha, $build_channel, $build_date) at $destination"
