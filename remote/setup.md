# Self-host a remote Brain

This is the reference setup for one owner and one always-on macOS runner. A
Mac mini is a common choice, but it is not a special account or fixed machine.
If you do not need multi-device capture or MCP, use
[local mode](../local/README.md) and skip this entire guide.

The remote Markdown folder is canonical. Cloudflare stores delivery and
authentication state, not the knowledge vault. GitHub stores source only.

## What you need

- an always-on Mac running macOS 14 or newer;
- a filesystem backup for its Brain data folder;
- Codex signed in with ChatGPT on that Mac;
- Node.js 22, Python 3.9+, `cloudflared`, and Xcode command-line tools;
- a Cloudflare account with Workers, D1, R2, Queues, KV, Pages, Tunnel, and a
  DNS zone; and
- optionally, a Telegram bot and Google OAuth client.

Choose your own values:

| Value | Example only |
|---|---|
| instance ID | `my-brain` |
| gateway Worker | `vox-brain-gateway` |
| delivery Queue | `vox-brain-delivery` |
| D1 database | `vox-brain-gateway` |
| R2 bucket | `vox-brain-captures` |
| Pages project | `brain-vault` |
| origin hostname | `brain-origin.example.com` |

Do not put secrets in shell history, command arguments, config files, or Git.

## 1. Prepare the runner

```sh
git clone https://github.com/reissui/vox-brain.git "$HOME/dev/vox-brain"
cd "$HOME/dev/vox-brain"
scripts/brain init-data
scripts/brain doctor
codex login --device-auth
codex login status
```

The default data root is
`~/Library/Application Support/Brain/Vault`. To use another absolute folder,
set `BRAIN_DATA_ROOT` for initialization and every Brain command.

Keep the source checkout and data root separate. Never clone this repository
into the vault or copy the vault into the checkout.

## 2. Create Cloudflare resources

Install dependencies and authenticate Wrangler:

```sh
cd "$HOME/dev/vox-brain/gateway"
npm ci
npx wrangler whoami
```

Create one D1 database, R2 bucket, Queue, and KV namespace:

```sh
npx wrangler d1 create vox-brain-gateway
npx wrangler r2 bucket create vox-brain-captures
npx wrangler queues create vox-brain-delivery
npx wrangler kv namespace create OAUTH_KV
```

Copy `gateway/wrangler.jsonc` to ignored
`gateway/wrangler.local.jsonc`. In the local copy:

- set `vars.INSTANCE_ID`;
- set `vars.BRAIN_ORIGIN_URL` to your Tunnel hostname;
- add the D1 `database_id` returned by Wrangler;
- add the KV `id` returned by Wrangler; and
- change resource names if you chose different ones.

The local config is machine/account configuration and must remain untracked.
The committed config contains no account ID, resource UUID, custom domain, or
secret.

## 3. Create independent credentials

Create separate random values for:

- Agent authentication;
- origin authentication;
- MCP authentication;
- Cloudflare Queue API access;
- Cloudflare Pages deployment; and
- the Tunnel connector.

Set Worker secrets through Wrangler's hidden prompt:

```sh
cd "$HOME/dev/vox-brain/gateway"
npx wrangler secret put AGENT_TOKEN --config wrangler.local.jsonc
npx wrangler secret put ORIGIN_TOKEN --config wrangler.local.jsonc
npx wrangler secret put MCP_PASSWORD --config wrangler.local.jsonc
```

Store the matching Agent and origin values plus independently scoped Queue and
Pages API tokens in the runner's Keychain. Each command prompts for the secret:

```sh
security add-generic-password -U -a "$USER" -s app.voxbrain.agent-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.origin-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.queue-api-token -w
security add-generic-password -U -a "$USER" -s app.voxbrain.pages-api-token -w
```

The Queue token should have only the account-level Queue permissions needed to
inspect, pull, and acknowledge this Queue. The Pages token should have only
`Account → Cloudflare Pages → Edit`.

The deprecated GitHub-backed `/capture` route is disabled by default. Do not
configure `CAPTURE_TOKEN`, `GITHUB_TOKEN`, or `GITHUB_REPOSITORY` for a new
installation.

## 4. Migrate and deploy the gateway

```sh
cd "$HOME/dev/vox-brain/gateway"
npm run check
npm test
npx wrangler d1 migrations apply vox-brain-gateway --remote \
  --config wrangler.local.jsonc
npx wrangler deploy --dry-run --config wrangler.local.jsonc
npx wrangler deploy --config wrangler.local.jsonc
```

Record the resulting HTTPS Worker URL as `GATEWAY_URL`. `GET /health` proves
only that the Worker is live; end-to-end health is tested after the runner is
connected.

## 5. Create the outbound Tunnel

In Cloudflare Zero Trust, create a remotely managed Tunnel and a public
hostname that routes your chosen origin hostname to
`http://127.0.0.1:8765`. Add a final catch-all 404 rule. No router port
forwarding or LAN listener is needed.

Copy the connector token from Cloudflare's **Add a replica** flow into
Keychain, then install its launch agent:

```sh
security add-generic-password -U -a "$USER" -s app.voxbrain.tunnel-token -w
cd "$HOME/dev/vox-brain"
remote/install-cloudflared.sh install
remote/install-cloudflared.sh status
```

The installer writes an owner-only token file outside the repository and runs
`cloudflared tunnel run --token-file ...`. It requires cloudflared 2025.4.0 or
newer.

## 6. Create the private site

The reference Agent publishes an allowlisted private site to the Pages project
named `brain-vault`:

```sh
cd "$HOME/dev/vox-brain"
npx wrangler pages project create brain-vault --production-branch main
```

Protect the resulting Pages hostname with Cloudflare Access before publishing
personal content. Allow only the owner's identity. Record the protected HTTPS
URL as `SITE_URL`.

See [site.md](site.md) for the publication allowlist and verification checks.

## 7. Install Telegram and automation

Telegram is a runner-side convenience and a current prerequisite of the
reference Agent installer. Create a bot with BotFather, then:

```sh
cd "$HOME/dev/vox-brain"
BRAIN_SOURCE_ROOT="$PWD" \
BRAIN_DATA_ROOT="$HOME/Library/Application Support/Brain/Vault" \
BRAIN_SITE_URL="$SITE_URL" \
  apps/telegram-bot/install.sh

BRAIN_DATA_ROOT="$HOME/Library/Application Support/Brain/Vault" \
  scripts/brain automate on hourly
```

The Telegram token and paired account IDs stay in Keychain or an owner-only
fallback file. The bot reads from `BRAIN_DATA_ROOT` and reads code/prompts from
`BRAIN_SOURCE_ROOT`; it does not require the vault to be a Git repository.

## 8. Install the Brain Agent

Find your Cloudflare account ID and the Queue's opaque ID in the dashboard or
Wrangler output. Then run:

```sh
cd "$HOME/dev/vox-brain"
apps/brain-agent/install.sh \
  --instance-id "$INSTANCE_ID" \
  --gateway-url "$GATEWAY_URL" \
  --site-url "$SITE_URL" \
  --code-root "$PWD" \
  --data-root "$HOME/Library/Application Support/Brain/Vault" \
  --tunnel-hostname "$ORIGIN_HOSTNAME" \
  --account-id "$CLOUDFLARE_ACCOUNT_ID" \
  --queue-id "$CLOUDFLARE_QUEUE_ID"
```

The installer:

- migrates and SHA-256 verifies any legacy vault data before changing runtime
  files;
- writes only owner-readable generated configuration outside the repository;
- loads the loopback Agent and event-driven site publisher with launchd;
- verifies Codex, Telegram, the Brain CLI, gateway heartbeat, and Queue access;
  and
- treats Gmail as optional.

It never places credentials in the launchd plist or application checkout.

## 9. Pair Brain.app

Mint a ten-minute, one-use code with the Agent credential:

```sh
curl -fsS -X POST "$GATEWAY_URL/v1/pair/start" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"device_name":"My Mac"}'
```

Avoid exporting `AGENT_TOKEN` in a long-lived shell; the command above is a
shape example. Prefer a short-lived owner-controlled terminal or password
manager substitution that does not log the value.

In Brain.app choose **Remote Brain**, enter `GATEWAY_URL`, and claim the
one-use code. The app stores only the returned device token in Keychain.

Verify:

```sh
scripts/brain status
scripts/brain doctor
launchctl print "gui/$(id -u)/app.voxbrain.agent"
remote/install-cloudflared.sh status
```

Then test one note, one URL, one image, Knowledge search/read, Process, Digest,
Ask, and MCP. Confirm each capture appears in the remote data root and that no
personal content appears in the source checkout.

## Updates, backup, and rollback

Before an update, back up the data root and keep the previous app/source
artifact. Pull source, run `scripts/check`, apply new D1 migrations, deploy the
Worker, and rerun the idempotent Agent installer.

The low-level Agent runtime can restore the configuration saved before its
first installation:

```sh
apps/brain-agent/install.sh rollback
```

Rollback never deletes either data copy. Do not reset a vault, delete a Queue
message, or discard an R2 object merely to make health appear green.
