#!/usr/bin/env bash
# Install the single remote Brain Agent for the current remote runner user.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="app.voxbrain.agent"
PUBLISHER_LABEL="app.voxbrain.site-publisher"
TEMPLATE="$APP_DIR/app.voxbrain.agent.plist"
PUBLISHER_TEMPLATE="$APP_DIR/app.voxbrain.site-publisher.plist"
TUNNEL_TEMPLATE="$APP_DIR/cloudflared.example.yml"
SERVICE="$APP_DIR/service.py"
PUBLISHER="$APP_DIR/site_publisher.py"
MIGRATOR="$APP_DIR/migrate_data.py"

usage() {
  cat <<'EOF'
Usage: install.sh \
  --instance-id ID \
  --gateway-url HTTPS_URL \
  --site-url HTTPS_URL \
  --code-root ABSOLUTE_SOURCE_PATH \
  --data-root ABSOLUTE_DATA_PATH \
  --tunnel-hostname HOSTNAME \
  --account-id CLOUDFLARE_ACCOUNT_ID \
  --queue-id CLOUDFLARE_QUEUE_ID \
  [--source-data-root LEGACY_PATH] [--brain-cli ABSOLUTE_PATH] \
  [--api-port PORT] [--keychain-account ACCOUNT]

       install.sh rollback

The four Agent and publisher credentials must already be in the target user's Keychain.
See README.md for the Keychain service names and test-only path overrides.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Rollback is deliberately credential-free. The migration helper restores the
# exact pre-cutover config, environment, and plist, then this reloads that
# prior launchd definition. Neither the source nor destination data is touched.
if [ "${1:-}" = "rollback" ]; then
  [ "$#" -eq 1 ] || die "rollback accepts no additional arguments"
  target_home="${BRAIN_AGENT_HOME:-$HOME}"
  target_uid="${BRAIN_AGENT_UID:-$(id -u)}"
  launch_agents_dir="${LAUNCH_AGENTS_DIR:-$target_home/Library/LaunchAgents}"
  config_dir="${BRAIN_AGENT_CONFIG_DIR:-$target_home/Library/Application Support/Brain Agent}"
  state_dir="${BRAIN_AGENT_STATE_DIR:-$config_dir/state}"
  plist="$launch_agents_dir/$LABEL.plist"
  publisher_plist="$launch_agents_dir/$PUBLISHER_LABEL.plist"
  python3="${BRAIN_AGENT_PYTHON3:-$(command -v python3 || true)}"
  launchctl_command="${BRAIN_AGENT_LAUNCHCTL:-$(command -v launchctl || true)}"
  [ -x "$python3" ] || die "Python 3 is required"
  [ -x "$launchctl_command" ] || die "launchctl is required"
  "$python3" "$MIGRATOR" rollback --state-dir "$state_dir" || exit 1
  domain="gui/$target_uid"
  "$launchctl_command" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  "$launchctl_command" bootout "$domain/$PUBLISHER_LABEL" >/dev/null 2>&1 || true
  if [ -f "$plist" ]; then
    "$launchctl_command" bootstrap "$domain" "$plist"
    "$launchctl_command" kickstart -k "$domain/$LABEL"
  fi
  if [ -f "$publisher_plist" ]; then
    "$launchctl_command" bootstrap "$domain" "$publisher_plist"
  fi
  echo "Brain Agent runtime rollback complete; both data copies are unchanged."
  exit 0
fi

instance_id=""
gateway_url=""
site_url=""
code_root=""
data_root=""
source_data_root=""
tunnel_hostname=""
account_id=""
queue_id=""
brain_cli=""
api_port="8765"
keychain_account="${BRAIN_AGENT_USER:-${USER:-$(id -un)}}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance-id|--gateway-url|--site-url|--code-root|--data-root|--source-data-root|--tunnel-hostname|--account-id|--queue-id|--brain-cli|--api-port|--keychain-account)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --instance-id) instance_id="$2" ;;
        --gateway-url) gateway_url="$2" ;;
        --site-url) site_url="$2" ;;
        --code-root) code_root="$2" ;;
        --data-root) data_root="$2" ;;
        --source-data-root) source_data_root="$2" ;;
        --tunnel-hostname) tunnel_hostname="$2" ;;
        --account-id) account_id="$2" ;;
        --queue-id) queue_id="$2" ;;
        --brain-cli) brain_cli="$2" ;;
        --api-port) api_port="$2" ;;
        --keychain-account) keychain_account="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

for required in instance_id gateway_url site_url code_root data_root tunnel_hostname account_id queue_id; do
  [ -n "${!required}" ] || {
    usage >&2
    die "--${required//_/-} is required"
  }
done

PYTHON3="${BRAIN_AGENT_PYTHON3:-$(command -v python3 || true)}"
LAUNCHCTL="${BRAIN_AGENT_LAUNCHCTL:-$(command -v launchctl || true)}"
SECURITY="${BRAIN_AGENT_SECURITY:-$(command -v security || true)}"
CLOUDFLARED="${BRAIN_AGENT_CLOUDFLARED:-$(command -v cloudflared || true)}"
NODE="${BRAIN_AGENT_NODE:-$(command -v node || true)}"
NPX="${BRAIN_AGENT_NPX:-$(command -v npx || true)}"
[ -n "$PYTHON3" ] && [ -x "$PYTHON3" ] || die "Python 3 is required"
[ -n "$LAUNCHCTL" ] && [ -x "$LAUNCHCTL" ] || die "launchctl is required"
[ -n "$SECURITY" ] && [ -x "$SECURITY" ] || die "the macOS security CLI is required"
[ -n "$CLOUDFLARED" ] && [ -x "$CLOUDFLARED" ] || die "cloudflared is required"
[ -n "$NODE" ] && [ -x "$NODE" ] || die "Node.js is required for private-site publication"
[ -n "$NPX" ] && [ -x "$NPX" ] || die "npx is required for private-site publication"
[ -f "$SERVICE" ] && [ -f "$TEMPLATE" ] && [ -f "$PUBLISHER" ] \
  && [ -f "$PUBLISHER_TEMPLATE" ] && [ -f "$TUNNEL_TEMPLATE" ] && [ -f "$MIGRATOR" ] \
  || die "Brain Agent installation files are incomplete"

"$PYTHON3" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' \
  || die "Python 3.9 or newer is required"

if [ -z "$brain_cli" ]; then
  brain_cli="$code_root/scripts/brain"
fi
[ -n "$source_data_root" ] || source_data_root="$code_root"

"$PYTHON3" - "$instance_id" "$gateway_url" "$site_url" "$code_root" "$data_root" \
  "$source_data_root" "$tunnel_hostname" "$account_id" "$queue_id" "$brain_cli" \
  "$api_port" <<'PY' || exit 1
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

instance, gateway, site, code, data, source_data, hostname, account, queue, cli, port = sys.argv[1:]
identifier = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
dns_name = re.compile(
    r"^(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)

def fail(message):
    print("error: " + message, file=sys.stderr)
    raise SystemExit(1)

for name, value in (("instance ID", instance), ("account ID", account), ("queue ID", queue)):
    if not identifier.fullmatch(value):
        fail(name + " is invalid")

parts = urlsplit(gateway)
if (
    parts.scheme not in ("http", "https")
    or not parts.hostname
    or parts.username is not None
    or parts.password is not None
    or parts.query
    or parts.fragment
):
    fail("gateway URL is invalid")
if parts.scheme == "http" and parts.hostname not in ("127.0.0.1", "localhost", "::1"):
    fail("gateway URL must use HTTPS (HTTP is allowed only for a loopback test gateway)")
try:
    site_parts = urlsplit(site)
    site_hostname = site_parts.hostname
    _ = site_parts.port
except ValueError:
    fail("site URL is invalid")
if (
    len(site.encode("utf-8")) > 2048
    or site != site.strip()
    or "\\" in site
    or any(ord(character) < 0x20 or ord(character) > 0x7e for character in site)
    or site_parts.scheme != "https"
    or not site_hostname
    or site_parts.username is not None
    or site_parts.password is not None
    or site_parts.query
    or site_parts.fragment
):
    fail("site URL is invalid")
if not dns_name.fullmatch(hostname):
    fail("tunnel hostname must be a fully qualified DNS hostname")

code_root = Path(code)
data_root = Path(data)
source_data_root = Path(source_data)
cli_path = Path(cli)
if not code_root.is_absolute() or not code_root.is_dir():
    fail("code root must be an existing absolute directory")
if not source_data_root.is_absolute() or not source_data_root.is_dir():
    fail("source data root must be an existing absolute directory")
if not data_root.is_absolute():
    fail("data root must be an absolute path")
if data_root.exists() and not data_root.is_dir():
    fail("data root must be a directory path")
if not cli_path.is_absolute() or not cli_path.is_file() or not os.access(cli_path, os.X_OK):
    fail("Brain CLI must be an executable absolute file")
try:
    parsed_port = int(port)
except ValueError:
    fail("API port must be an integer")
if str(parsed_port) != port or not 1 <= parsed_port <= 65535:
    fail("API port must be between 1 and 65535")
PY

TARGET_HOME="${BRAIN_AGENT_HOME:-$HOME}"
TARGET_UID="${BRAIN_AGENT_UID:-$(id -u)}"
AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$TARGET_HOME/Library/LaunchAgents}"
CONFIG_DIR="${BRAIN_AGENT_CONFIG_DIR:-$TARGET_HOME/Library/Application Support/Brain Agent}"
STATE_DIR="${BRAIN_AGENT_STATE_DIR:-$CONFIG_DIR/state}"
LOG_DIR="${BRAIN_AGENT_LOG_DIR:-$CONFIG_DIR/logs}"
CONFIG_PATH="$CONFIG_DIR/agent.json"
ENV_PATH="$CONFIG_DIR/agent.env"
TUNNEL_CONFIG="$CONFIG_DIR/cloudflared.yml"
PLIST="$AGENTS_DIR/$LABEL.plist"
PUBLISHER_PLIST="$AGENTS_DIR/$PUBLISHER_LABEL.plist"
PUBLISHER_ENV_PATH="$CONFIG_DIR/site-publisher.env"
RUNTIME_PATH="$TARGET_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

for path_value in "$TARGET_HOME" "$AGENTS_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"; do
  case "$path_value" in
    /*) ;;
    *) die "installation paths must be absolute" ;;
  esac
done
case "$TARGET_UID" in
  ''|*[!0-9]*) die "target UID must be numeric" ;;
esac

AGENT_TOKEN_SERVICE="app.voxbrain.agent-token"
ORIGIN_TOKEN_SERVICE="app.voxbrain.origin-token"
QUEUE_TOKEN_SERVICE="app.voxbrain.queue-api-token"
PAGES_TOKEN_SERVICE="app.voxbrain.pages-api-token"

keychain_secret() {
  local service="$1" value
  if ! value="$($SECURITY find-generic-password -a "$keychain_account" -s "$service" -w 2>/dev/null)"; then
    die "Keychain item $service is missing for account $keychain_account"
  fi
  [ -n "$value" ] || die "Keychain item $service is empty"
  printf '%s' "$value"
}

agent_token="$(keychain_secret "$AGENT_TOKEN_SERVICE")"
origin_token="$(keychain_secret "$ORIGIN_TOKEN_SERVICE")"
queue_api_token="$(keychain_secret "$QUEUE_TOKEN_SERVICE")"
pages_api_token="$(keychain_secret "$PAGES_TOKEN_SERVICE")"
for secret in "$agent_token" "$origin_token" "$queue_api_token" "$pages_api_token"; do
  [[ "$secret" != *[[:space:]]* ]] || die "Brain Agent credentials cannot contain whitespace"
done
if [ "$(printf '%s\n' "$agent_token" "$origin_token" "$queue_api_token" "$pages_api_token" | sort -u | wc -l | tr -d ' ')" -ne 4 ]; then
  die "Brain Agent and publisher credentials must be independent"
fi

umask 077
mkdir -p "$AGENTS_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"

# Copy and SHA-256 verify all legacy content before changing any runtime file.
# The manifest is the cutover gate; the original source tree is never edited.
"$PYTHON3" "$MIGRATOR" apply --source-root "$source_data_root" \
  --data-root "$data_root" --state-dir "$STATE_DIR"
"$PYTHON3" "$MIGRATOR" status --data-root "$data_root" --state-dir "$STATE_DIR" \
  >/dev/null
echo "PASS external Brain data manifest"

# Preserve the first pre-cutover runtime exactly once. Idempotent installer
# reruns retain that same rollback point rather than backing up the new config.
"$PYTHON3" "$MIGRATOR" backup-runtime --state-dir "$STATE_DIR" \
  --runtime-file "$CONFIG_PATH" --runtime-file "$ENV_PATH" --runtime-file "$PLIST" \
  --runtime-file "$PUBLISHER_ENV_PATH" --runtime-file "$PUBLISHER_PLIST" \
  >/dev/null
echo "PASS pre-cutover runtime backup"

config_tmp=""
env_tmp=""
tunnel_tmp=""
plist_tmp=""
publisher_env_tmp=""
publisher_plist_tmp=""
status_tmp=""
health_tmp=""
cleanup() {
  [ -z "$config_tmp" ] || rm -f "$config_tmp"
  [ -z "$env_tmp" ] || rm -f "$env_tmp"
  [ -z "$tunnel_tmp" ] || rm -f "$tunnel_tmp"
  [ -z "$plist_tmp" ] || rm -f "$plist_tmp"
  [ -z "$publisher_env_tmp" ] || rm -f "$publisher_env_tmp"
  [ -z "$publisher_plist_tmp" ] || rm -f "$publisher_plist_tmp"
  [ -z "$status_tmp" ] || rm -f "$status_tmp"
  [ -z "$health_tmp" ] || rm -f "$health_tmp"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

reload_launch_agent() {
  local domain="$1" label="$2" plist="$3" attempt output=""
  "$LAUNCHCTL" bootout "$domain/$label" >/dev/null 2>&1 || true
  for attempt in 1 2 3 4 5; do
    if output="$("$LAUNCHCTL" bootstrap "$domain" "$plist" 2>&1)"; then
      "$LAUNCHCTL" kickstart -k "$domain/$label"
      return 0
    fi
    [ "$attempt" -eq 5 ] || sleep 1
  done
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  return 1
}

# Every generated file is replaced by rename from the same directory. A rerun
# therefore presents either the old complete configuration or the new one.
config_tmp="$(mktemp "$CONFIG_DIR/.agent.json.XXXXXX")"
"$PYTHON3" - "$instance_id" "$gateway_url" "$site_url" "$account_id" "$queue_id" \
  "$code_root" "$data_root" "$brain_cli" "$api_port" "$STATE_DIR" > "$config_tmp" <<'PY'
import json
import sys

instance, gateway, site, account, queue, code, data, cli, port, state = sys.argv[1:]
json.dump(
    {
        "instance_id": instance,
        "gateway_url": gateway.rstrip("/"),
        "site_url": site,
        "account_id": account,
        "queue_id": queue,
        "code_root": code,
        "data_root": data,
        "brain_cli_path": cli,
        "api_port": int(port),
        "state_dir": state,
    },
    sys.stdout,
    indent=2,
    sort_keys=True,
)
sys.stdout.write("\n")
PY
chmod 600 "$config_tmp"
mv -f "$config_tmp" "$CONFIG_PATH"
config_tmp=""

env_tmp="$(mktemp "$CONFIG_DIR/.agent.env.XXXXXX")"
BRAIN_AGENT_TOKEN="$agent_token" BRAIN_ORIGIN_TOKEN="$origin_token" \
  BRAIN_QUEUE_API_TOKEN="$queue_api_token" "$PYTHON3" - > "$env_tmp" <<'PY'
import os
import shlex

for name in ("BRAIN_AGENT_TOKEN", "BRAIN_ORIGIN_TOKEN", "BRAIN_QUEUE_API_TOKEN"):
    print("export {}={}".format(name, shlex.quote(os.environ[name])))
PY
chmod 600 "$env_tmp"
mv -f "$env_tmp" "$ENV_PATH"
env_tmp=""

publisher_env_tmp="$(mktemp "$CONFIG_DIR/.site-publisher.env.XXXXXX")"
BRAIN_AGENT_TOKEN="$agent_token" CLOUDFLARE_API_TOKEN="$pages_api_token" \
  "$PYTHON3" - > "$publisher_env_tmp" <<'PY'
import os
import shlex

for name in ("BRAIN_AGENT_TOKEN", "CLOUDFLARE_API_TOKEN"):
    print("export {}={}".format(name, shlex.quote(os.environ[name])))
PY
chmod 600 "$publisher_env_tmp"
mv -f "$publisher_env_tmp" "$PUBLISHER_ENV_PATH"
publisher_env_tmp=""

tunnel_tmp="$(mktemp "$CONFIG_DIR/.cloudflared.yml.XXXXXX")"
"$PYTHON3" - "$TUNNEL_TEMPLATE" "$tunnel_hostname" "$api_port" \
  > "$tunnel_tmp" <<'PY'
import sys

source, hostname, port = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    rendered = handle.read().replace("@TUNNEL_HOSTNAME@", hostname).replace("@API_PORT@", port)
if "@TUNNEL_HOSTNAME@" in rendered or "@API_PORT@" in rendered:
    raise SystemExit("unresolved cloudflared template placeholder")
sys.stdout.write(rendered)
PY
chmod 600 "$tunnel_tmp"
if ! "$CLOUDFLARED" --config "$tunnel_tmp" tunnel ingress validate >/dev/null; then
  die "cloudflared rejected the rendered tunnel route"
fi
if ! "$CLOUDFLARED" --config "$tunnel_tmp" tunnel ingress rule \
  "https://$tunnel_hostname" >/dev/null; then
  die "cloudflared did not match the configured tunnel hostname"
fi
mv -f "$tunnel_tmp" "$TUNNEL_CONFIG"
tunnel_tmp=""
echo "PASS cloudflared loopback route"

plist_tmp="$(mktemp "$AGENTS_DIR/.$LABEL.plist.XXXXXX")"
"$PYTHON3" - "$TEMPLATE" "$ENV_PATH" "$PYTHON3" "$SERVICE" "$CONFIG_PATH" \
  "$TARGET_HOME" "$RUNTIME_PATH" "$APP_DIR" "$data_root" "$code_root" \
  "$LOG_DIR/agent.stdout.log" "$LOG_DIR/agent.stderr.log" > "$plist_tmp" <<'PY'
import sys
from xml.sax.saxutils import escape

source, env_file, python, service, config, home, path, workdir, data, code, stdout, stderr = sys.argv[1:]
replacements = {
    "@ENV_FILE@": env_file,
    "@PYTHON@": python,
    "@SERVICE@": service,
    "@CONFIG@": config,
    "@HOME@": home,
    "@PATH@": path,
    "@WORKING_DIRECTORY@": workdir,
    "@DATA_ROOT@": data,
    "@CODE_ROOT@": code,
    "@STDOUT@": stdout,
    "@STDERR@": stderr,
}
with open(source, encoding="utf-8") as handle:
    rendered = handle.read()
for marker, value in replacements.items():
    rendered = rendered.replace(marker, escape(value))
if any(marker in rendered for marker in replacements):
    raise SystemExit("unresolved launchd template placeholder")
sys.stdout.write(rendered)
PY
chmod 600 "$plist_tmp"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$plist_tmp" >/dev/null
fi
mv -f "$plist_tmp" "$PLIST"
plist_tmp=""

publisher_plist_tmp="$(mktemp "$AGENTS_DIR/.$PUBLISHER_LABEL.plist.XXXXXX")"
"$PYTHON3" - "$PUBLISHER_TEMPLATE" "$PUBLISHER_ENV_PATH" "$PYTHON3" "$PUBLISHER" \
  "$CONFIG_PATH" "$data_root/system/site-publish-ready.json" "$TARGET_HOME" "$RUNTIME_PATH" \
  "$APP_DIR" "$data_root" "$code_root" "$LOG_DIR/site-publisher.stdout.log" \
  "$LOG_DIR/site-publisher.stderr.log" > "$publisher_plist_tmp" <<'PY'
import sys
from xml.sax.saxutils import escape

source, env_file, python, publisher, config, marker, home, path, workdir, data, code, stdout, stderr = sys.argv[1:]
replacements = {
    "@PUBLISHER_ENV_FILE@": env_file,
    "@PYTHON@": python,
    "@PUBLISHER@": publisher,
    "@CONFIG@": config,
    "@PROCESS_MARKER@": marker,
    "@HOME@": home,
    "@PATH@": path,
    "@WORKING_DIRECTORY@": workdir,
    "@DATA_ROOT@": data,
    "@CODE_ROOT@": code,
    "@STDOUT@": stdout,
    "@STDERR@": stderr,
}
with open(source, encoding="utf-8") as handle:
    rendered = handle.read()
for marker, value in replacements.items():
    rendered = rendered.replace(marker, escape(value))
if any(marker in rendered for marker in replacements):
    raise SystemExit("unresolved publisher launchd template placeholder")
sys.stdout.write(rendered)
PY
chmod 600 "$publisher_plist_tmp"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$publisher_plist_tmp" >/dev/null
fi
mv -f "$publisher_plist_tmp" "$PUBLISHER_PLIST"
publisher_plist_tmp=""

domain="gui/$TARGET_UID"
reload_launch_agent "$domain" "$LABEL" "$PLIST"
"$LAUNCHCTL" bootout "$domain/$PUBLISHER_LABEL" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootstrap "$domain" "$PUBLISHER_PLIST"

failures=0
if "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null; then
  echo "PASS launchctl state"
else
  echo "FAIL launchctl state" >&2
  failures=$((failures + 1))
fi
if "$LAUNCHCTL" print "$domain/$PUBLISHER_LABEL" >/dev/null; then
  echo "PASS site publisher launchctl state"
else
  echo "FAIL site publisher launchctl state" >&2
  failures=$((failures + 1))
fi

CODEX="${BRAIN_AGENT_CODEX:-$(command -v codex || true)}"
if [ -n "$CODEX" ] && [ -x "$CODEX" ] \
  && env -u OPENAI_API_KEY -u CODEX_API_KEY "$CODEX" login status 2>&1 \
    | grep -qF 'Logged in using ChatGPT'; then
  echo "PASS Codex ChatGPT login"
else
  echo "FAIL Codex ChatGPT login (run: codex login --device-auth)" >&2
  failures=$((failures + 1))
fi

status_tmp="$(mktemp "$CONFIG_DIR/.verify-status.XXXXXX")"
health_tmp="$(mktemp "$CONFIG_DIR/.verify-health.XXXXXX")"
status_ok=1
if ! BRAIN_DATA_ROOT="$data_root" "$brain_cli" status --json > "$status_tmp"; then
  echo "FAIL Brain status CLI" >&2
  failures=$((failures + 1))
  status_ok=0
fi

if [ "$status_ok" -eq 1 ] && "$PYTHON3" - "$status_tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
services = report.get("services", []) if isinstance(report, dict) else []
telegram = next(
    (item for item in services if isinstance(item, dict) and item.get("id") == "telegram"),
    None,
)
raise SystemExit(not (telegram and telegram.get("configured") and telegram.get("running")))
PY
then
  echo "PASS Telegram remote service state"
else
  echo "FAIL Telegram remote service state" >&2
  failures=$((failures + 1))
fi

# doctor intentionally reports JSON even when one of its checks is unhealthy.
# Preserve that report in the heartbeat while keeping the transport check
# independent from Telegram and Gmail state.
BRAIN_DATA_ROOT="$data_root" "$brain_cli" doctor --json > "$health_tmp" 2>/dev/null || true

if BRAIN_DATA_ROOT="$data_root" "$brain_cli" gmail status --check-api >/dev/null 2>&1; then
  echo "PASS Gmail optional connection"
else
  echo "WARN Gmail optional connection unavailable"
fi

CLOUDFLARE_API_BASE="${BRAIN_AGENT_CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
HTTP_TIMEOUT="${BRAIN_AGENT_HTTP_TIMEOUT:-10}"
if ! BRAIN_AGENT_TOKEN="$agent_token" BRAIN_QUEUE_API_TOKEN="$queue_api_token" \
  "$PYTHON3" - "$gateway_url" "$account_id" "$queue_id" "$CLOUDFLARE_API_BASE" \
    "$instance_id" "$status_tmp" "$health_tmp" "$HTTP_TIMEOUT" <<'PY'
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

gateway, account, queue, api_base, instance, status_path, health_path, timeout = sys.argv[1:]
timeout_value = float(timeout)
failed = False

def load_report(path, fallback):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else fallback
    except (OSError, ValueError):
        return fallback

heartbeat = {
    "instance_id": instance,
    "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    "status": load_report(status_path, {"available": False}),
    "health": load_report(health_path, {"available": False}),
    "agent_version": "1",
    "last_successful_queue_poll": None,
}
heartbeat_request = urllib.request.Request(
    gateway.rstrip("/") + "/v1/agent/heartbeat",
    data=json.dumps(heartbeat, separators=(",", ":")).encode("utf-8"),
    method="POST",
    headers={
        "Accept": "application/json",
        "Authorization": "Bearer " + os.environ["BRAIN_AGENT_TOKEN"],
        "Content-Type": "application/json",
        "User-Agent": "Brain-Agent/1",
    },
)
try:
    with urllib.request.urlopen(heartbeat_request, timeout=timeout_value) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError("non-success response")
        response.read(64 * 1024)
    print("PASS gateway heartbeat")
except Exception as error:
    print("FAIL gateway heartbeat ({})".format(type(error).__name__), file=sys.stderr)
    failed = True

queue_url = "{}/accounts/{}/queues/{}".format(
    api_base.rstrip("/"),
    urllib.parse.quote(account, safe=""),
    urllib.parse.quote(queue, safe=""),
)
queue_request = urllib.request.Request(
    queue_url,
    method="GET",
    headers={
        "Accept": "application/json",
        "Authorization": "Bearer " + os.environ["BRAIN_QUEUE_API_TOKEN"],
        "User-Agent": "Brain-Agent/1",
    },
)
try:
    with urllib.request.urlopen(queue_request, timeout=timeout_value) as response:
        body = response.read(64 * 1024)
        if not 200 <= response.status < 300:
            raise RuntimeError("non-success response")
    result = json.loads(body.decode("utf-8"))
    if not isinstance(result, dict) or result.get("success") is not True:
        raise RuntimeError("invalid Cloudflare response")
    print("PASS queue access")
except Exception as error:
    print("FAIL queue access ({})".format(type(error).__name__), file=sys.stderr)
    failed = True

raise SystemExit(failed)
PY
then
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  die "$failures required Brain Agent verification group(s) failed; Gmail remains optional"
fi

echo "Brain Agent installed: $PLIST"
echo "configuration: $CONFIG_PATH"
echo "secret environment: $ENV_PATH (mode 0600)"
echo "tunnel route: $TUNNEL_CONFIG"
echo "logs: $LOG_DIR/agent.stdout.log and $LOG_DIR/agent.stderr.log"
