# Remote Brain Agent

The Agent is the long-running process on an optional remote macOS runner. It
owns the canonical Markdown vault, pulls capture/job messages, runs only fixed
Brain CLI actions, exposes a loopback API to Cloudflare Tunnel, sends
content-free health snapshots, and triggers the private-site publisher.

Local-only users do not install it.

## Prerequisites

- macOS 14 or newer, Python 3.9+, Node.js 22, `cloudflared`, and launchd;
- Codex signed in with ChatGPT;
- an initialized external `BRAIN_DATA_ROOT`;
- the Cloudflare gateway, D1, R2, Queue, and Tunnel from
  [the remote setup guide](../../remote/setup.md);
- the runner-side Telegram launch service; and
- four independent Keychain items:

```sh
security add-generic-password -U -a "$USER" -s app.voxbrain.agent-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.origin-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.queue-api-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.pages-api-token -w
```

The first two must match the Worker secrets. Queue and Pages tokens should
carry only the permissions required for those products.

## Install

Every deployment identifier and filesystem root is an argument:

```sh
apps/brain-agent/install.sh \
  --instance-id my-brain \
  --gateway-url https://your-gateway.example \
  --site-url https://your-private-site.example \
  --code-root /absolute/path/to/vox-brain \
  --data-root "$HOME/Library/Application Support/Brain/Vault" \
  --tunnel-hostname brain-origin.example.com \
  --account-id YOUR_CLOUDFLARE_ACCOUNT_ID \
  --queue-id YOUR_CLOUDFLARE_QUEUE_ID
```

Use `--source-data-root /absolute/legacy/vault` only for a one-time migration
from a previous co-located vault.

The installer:

1. copies legacy data without deleting the source;
2. verifies every copied regular file by SHA-256 and rejects symlinks or
   conflicts;
3. saves the first pre-install runtime as a rollback point;
4. writes owner-only config and environment files under
   `~/Library/Application Support/Brain Agent`;
5. installs `app.voxbrain.agent` and
   `app.voxbrain.site-publisher` launch agents; and
6. verifies Codex, Telegram, Brain health, gateway heartbeat, and Queue access.

Generated plists contain paths but no secret values.

## Runtime files

| Path | Purpose |
|---|---|
| `agent.json` | non-secret instance, URL, resource, and path configuration |
| `agent.env` | owner-only Agent/origin/Queue credentials |
| `site-publisher.env` | owner-only Pages credential |
| `state/` | progress, health, migration, and publisher state |
| `logs/` | Agent and publisher stdout/stderr |

The source root is read-only runtime material. The data root is the only
canonical knowledge store.

## Operations

```sh
scripts/brain status
scripts/brain doctor
launchctl print "gui/$(id -u)/app.voxbrain.agent"
launchctl kickstart -k "gui/$(id -u)/app.voxbrain.agent"
tail -n 200 -F "$HOME/Library/Application Support/Brain Agent/logs/agent.stderr.log"
```

A capture acknowledged with HTTP 202 is already durable at the gateway.
Investigate Queue state, Agent logs, the remote inbox, and the result callback
in that order. Do not resubmit with a new idempotency key.

## Rollback

```sh
apps/brain-agent/install.sh rollback
```

Rollback restores the saved runtime configuration and launchd definitions. It
never removes either data copy.

## Tests

```sh
python3 -m unittest discover -s apps/brain-agent/tests
```

Tests redirect home, Keychain, launchd, Cloudflare, and executable boundaries
to isolated fixtures; no live credential is required.
