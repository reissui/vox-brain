#!/usr/bin/env bash
# Install the direct-to-Brain dictation app and keep its gateway credentials in Keychain.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$APP_DIR/../.." && pwd)"
BRAIN_CLI="$VAULT/scripts/brain"
APP_DEST="${BRAIN_DICTATION_APP_DEST:-$HOME/Applications/Brain Note.app}"
ACCOUNT="${USER:-$(id -un)}"
URL_SERVICE="app.voxbrain.gateway-url"
TOKEN_SERVICE="app.voxbrain.capture-token"
GATEWAY_URL="${BRAIN_GATEWAY_URL:-${1:-}}"
TOKEN="${BRAIN_CAPTURE_TOKEN:-}"

if [ -z "$GATEWAY_URL" ]; then
  read -r -p "Brain gateway URL (https://…workers.dev): " GATEWAY_URL
fi
GATEWAY_URL="${GATEWAY_URL%/}"
case "$GATEWAY_URL" in
  https://*) ;;
  *) echo "error: gateway URL must begin with https://" >&2; exit 1 ;;
esac

if [ -z "$TOKEN" ]; then
  read -r -s -p "Capture token: " TOKEN
  echo
fi
[ -n "$TOKEN" ] || { echo "error: capture token cannot be empty" >&2; exit 1; }

if [ -z "${BRAIN_NO_NETWORK:-}" ]; then
  health="$(curl -fsS --max-time 15 "$GATEWAY_URL/health")"
  printf '%s' "$health" | grep -q '"ok":true' || {
    echo "error: gateway health check failed" >&2
    exit 1
  }
fi

if [ -z "${BRAIN_NO_KEYCHAIN:-}" ]; then
  security add-generic-password -U -a "$ACCOUNT" -s "$URL_SERVICE" -w "$GATEWAY_URL" >/dev/null
  security add-generic-password -U -a "$ACCOUNT" -s "$TOKEN_SERVICE" -w "$TOKEN" >/dev/null
fi

if [ -z "${BRAIN_NO_COMPILE:-}" ]; then
  command -v osacompile >/dev/null 2>&1 || { echo "error: osacompile is required" >&2; exit 1; }
  mkdir -p "$(dirname "$APP_DEST")"
  tmp_script="$(mktemp "${TMPDIR:-/tmp}/brain-dictate.XXXXXX.applescript")"
  tmp_app="$(mktemp -d "${TMPDIR:-/tmp}/brain-dictate-app.XXXXXX")/Brain Note.app"
  cleanup() { rm -f "$tmp_script"; rm -rf "$(dirname "$tmp_app")"; }
  trap cleanup EXIT
  escaped_cli="$(printf '%s' "$BRAIN_CLI" | sed 's/[\\&|]/\\&/g')"
  sed "s|@BRAIN_CLI@|$escaped_cli|g" "$APP_DIR/brain-dictate.applescript" > "$tmp_script"
  osacompile -o "$tmp_app" "$tmp_script"
  rm -rf "$APP_DEST"
  ditto "$tmp_app" "$APP_DEST"
fi

echo "Brain Note installed — open it with Spotlight, hold Fn to dictate, then press Save to Brain."
echo "Gateway credentials are stored in macOS Keychain, not in the vault or app bundle."
