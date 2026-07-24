#!/usr/bin/env bash
# Install and pair the owner's private Brain Telegram bot on the always-on remote Mac.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${BRAIN_SOURCE_ROOT:-$(cd "$APP_DIR/../.." && pwd)}"
DATA_ROOT="${BRAIN_DATA_ROOT:-$HOME/Library/Application Support/Brain/Vault}"
AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/app.voxbrain.telegram.plist"
PYTHON3="$(command -v python3)"
MODEL="${BRAIN_TELEGRAM_MODEL:-gpt-5.6-terra}"
LEARNING_MODEL="${BRAIN_TELEGRAM_LEARNING_MODEL:-gpt-5.6-sol}"
SITE_URL="${BRAIN_SITE_URL:-https://brain-vault.example.pages.dev}"
STATE_DIR="${BRAIN_STATE_DIR:-$HOME/Library/Application Support/Brain}"
TOKEN_SERVICE="app.voxbrain.telegram-token"
USER_SERVICE="app.voxbrain.telegram-user-id"
CHAT_SERVICE="app.voxbrain.telegram-chat-id"
account="${USER:-$(id -un)}"

if [ ! -x "$SOURCE_ROOT/scripts/brain" ] || [ ! -f "$APP_DIR/bot.py" ]; then
  echo "error: Brain Telegram files are incomplete — check BRAIN_SOURCE_ROOT" >&2
  exit 1
fi
if [ ! -d "$DATA_ROOT" ]; then
  echo "error: Brain data root is missing — run scripts/brain init-data first" >&2
  exit 1
fi
case "$LEARNING_MODEL" in
  *[Ss][Oo][Ll]*) ;;
  *) echo "error: BRAIN_TELEGRAM_LEARNING_MODEL must be a Sol model" >&2; exit 1 ;;
esac
if ! command -v codex >/dev/null 2>&1 && [ -z "${BRAIN_NO_CODEX_CHECK:-}" ]; then
  echo "error: Codex CLI is required on the remote Mac" >&2
  exit 1
fi
if [ -z "${BRAIN_NO_CODEX_CHECK:-}" ] && ! env -u OPENAI_API_KEY -u CODEX_API_KEY codex login status 2>&1 | grep -qF 'Logged in using ChatGPT'; then
  echo "error: sign Codex into the ChatGPT subscription first: codex login --device-auth" >&2
  exit 1
fi

token="${BRAIN_TELEGRAM_TOKEN:-}"
if [ -z "$token" ] && command -v security >/dev/null 2>&1; then
  token="$(security find-generic-password -a "$account" -s "$TOKEN_SERVICE" -w 2>/dev/null || true)"
fi
if [ -z "$token" ]; then
  read -r -s -p "Paste the BotFather token (input hidden): " token
  printf '\n'
fi
if [ -z "$token" ]; then
  echo "error: Telegram token cannot be empty" >&2
  exit 1
fi

if [ -z "${BRAIN_NO_NETWORK:-}" ]; then
  bot_name="$(BRAIN_TELEGRAM_TOKEN="$token" "$PYTHON3" "$APP_DIR/bot.py" validate)"
  echo "validated Telegram bot $bot_name"
fi

user_id="${BRAIN_TELEGRAM_USER_ID:-}"
chat_id="${BRAIN_TELEGRAM_CHAT_ID:-}"
if [ -z "$user_id" ] || [ -z "$chat_id" ]; then
  pair="$(BRAIN_TELEGRAM_TOKEN="$token" "$PYTHON3" "$APP_DIR/bot.py" pair)"
  user_id="${pair%%$'\t'*}"
  chat_id="${pair#*$'\t'}"
fi
case "$user_id:$chat_id" in
  *[!0-9:-]*|:|*:) echo "error: pairing did not return numeric Telegram IDs" >&2; exit 1 ;;
esac

credential_store="not persisted (test mode)"
store_file_secrets() {
  printf '%s\n%s\n%s\n' "$token" "$user_id" "$chat_id" \
    | BRAIN_STATE_DIR="$STATE_DIR" "$PYTHON3" "$APP_DIR/bot.py" store-secrets
  credential_store="$STATE_DIR/telegram-secrets.json (owner-only fallback)"
}
if [ -n "${BRAIN_STORE_FILE_SECRETS:-}" ]; then
  store_file_secrets
elif [ -z "${BRAIN_NO_KEYCHAIN:-}" ]; then
  if command -v security >/dev/null 2>&1 \
    && security add-generic-password -U -a "$account" -s "$TOKEN_SERVICE" -w "$token" >/dev/null 2>&1 \
    && security add-generic-password -U -a "$account" -s "$USER_SERVICE" -w "$user_id" >/dev/null 2>&1 \
    && security add-generic-password -U -a "$account" -s "$CHAT_SERVICE" -w "$chat_id" >/dev/null 2>&1; then
    credential_store="macOS Keychain"
  else
    echo "Keychain writes are unavailable in this session; using the owner-only headless fallback."
    store_file_secrets
  fi
fi

mkdir -p "$AGENTS_DIR" "$STATE_DIR"
runtime_path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
sed -e "s|@PYTHON@|$PYTHON3|g" \
    -e "s|@BOT@|$APP_DIR/bot.py|g" \
    -e "s|@SOURCE_ROOT@|$SOURCE_ROOT|g" \
    -e "s|@DATA_ROOT@|$DATA_ROOT|g" \
    -e "s|@STATE_DIR@|$STATE_DIR|g" \
    -e "s|@MODEL@|$MODEL|g" \
    -e "s|@LEARNING_MODEL@|$LEARNING_MODEL|g" \
    -e "s|@SITE_URL@|$SITE_URL|g" \
    -e "s|@PATH@|$runtime_path|g" \
    "$APP_DIR/app.voxbrain.telegram.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [ -z "${BRAIN_NO_LAUNCHCTL:-}" ]; then
  launchctl bootout "gui/$(id -u)/app.voxbrain.telegram" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart -k "gui/$(id -u)/app.voxbrain.telegram"
fi

echo "Telegram Brain is installed for user $user_id (chat: $MODEL, learning: $LEARNING_MODEL)"
echo "credentials: $credential_store"
echo "status: launchctl print gui/$(id -u)/app.voxbrain.telegram"
echo "log: /tmp/app.voxbrain.telegram.log"
