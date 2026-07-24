#!/usr/bin/env bash
set -euo pipefail

LABEL="app.voxbrain.cloudflared"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/app.voxbrain.cloudflared.plist"
TARGET_HOME="${BRAIN_REMOTE_HOME:-$HOME}"
TARGET_UID="${BRAIN_REMOTE_UID:-$(id -u)}"
CONFIG_DIR="${BRAIN_AGENT_CONFIG_DIR:-$TARGET_HOME/Library/Application Support/Brain Agent}"
AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$TARGET_HOME/Library/LaunchAgents}"
TOKEN_FILE="$CONFIG_DIR/cloudflared-token"
PLIST="$AGENTS_DIR/$LABEL.plist"
ACCOUNT="${BRAIN_REMOTE_USER:-${USER:-$(id -un)}}"
TOKEN_SERVICE="app.voxbrain.tunnel-token"
CLOUDFLARED="${BRAIN_REMOTE_CLOUDFLARED:-$(command -v cloudflared || true)}"
SECURITY="${BRAIN_REMOTE_SECURITY:-$(command -v security || true)}"
LAUNCHCTL="${BRAIN_REMOTE_LAUNCHCTL:-$(command -v launchctl || true)}"
PYTHON3="${BRAIN_REMOTE_PYTHON3:-$(command -v python3 || true)}"

usage() {
  echo "Usage: remote/install-cloudflared.sh install|status"
}

case "${1:-}" in
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    exec "$LAUNCHCTL" print "gui/$TARGET_UID/$LABEL"
    ;;
  install)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

for executable in "$CLOUDFLARED" "$SECURITY" "$LAUNCHCTL" "$PYTHON3"; do
  [ -n "$executable" ] && [ -x "$executable" ] || {
    echo "error: cloudflared, security, launchctl, and Python 3 are required" >&2
    exit 1
  }
done

token="$("$SECURITY" find-generic-password -a "$ACCOUNT" -s "$TOKEN_SERVICE" -w)"
[ -n "$token" ] && [[ "$token" != *[[:space:]]* ]] || {
  echo "error: Keychain item $TOKEN_SERVICE is missing or invalid" >&2
  exit 1
}

umask 077
mkdir -p "$CONFIG_DIR" "$AGENTS_DIR"
token_tmp="$(mktemp "$CONFIG_DIR/.cloudflared-token.XXXXXX")"
plist_tmp="$(mktemp "$AGENTS_DIR/.$LABEL.plist.XXXXXX")"
cleanup() {
  rm -f "$token_tmp" "$plist_tmp"
}
trap cleanup EXIT

printf '%s' "$token" > "$token_tmp"
chmod 600 "$token_tmp"
mv -f "$token_tmp" "$TOKEN_FILE"
token_tmp=""

"$PYTHON3" - "$TEMPLATE" "$CLOUDFLARED" "$TOKEN_FILE" \
  "$CONFIG_DIR/cloudflared.stdout.log" "$CONFIG_DIR/cloudflared.stderr.log" \
  > "$plist_tmp" <<'PY'
import sys
from xml.sax.saxutils import escape

source, cloudflared, token_file, stdout, stderr = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    rendered = handle.read()
for marker, value in {
    "@CLOUDFLARED@": cloudflared,
    "@TOKEN_FILE@": token_file,
    "@STDOUT@": stdout,
    "@STDERR@": stderr,
}.items():
    rendered = rendered.replace(marker, escape(value))
if "@" in rendered:
    raise SystemExit("unresolved launchd template placeholder")
sys.stdout.write(rendered)
PY
chmod 600 "$plist_tmp"
plutil -lint "$plist_tmp" >/dev/null
mv -f "$plist_tmp" "$PLIST"
plist_tmp=""

domain="gui/$TARGET_UID"
"$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootstrap "$domain" "$PLIST"
"$LAUNCHCTL" kickstart -k "$domain/$LABEL"

echo "Cloudflare Tunnel connector installed."
echo "status: $SCRIPT_DIR/install-cloudflared.sh status"
