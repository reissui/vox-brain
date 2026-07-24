# Vox Brain gateway

This Cloudflare Worker is optional. It provides pairing, authenticated capture,
knowledge access, allowlisted jobs, status, and MCP for one self-hosted remote
Brain. Local mode does not load or require it.

## Storage boundary

- The remote runner's `BRAIN_DATA_ROOT` is canonical Markdown.
- D1 stores device, capture, job, and recent health state.
- R2 permanently stores immutable binary capture originals.
- Queues deliver capture and fixed-job envelopes to the Agent.
- KV and a Durable Object support the MCP OAuth/session surface.
- Tunnel reaches the runner's loopback-only Agent API.

Cloudflare state is not a vault backup. GitHub distributes source and releases
only.

## Develop and test

```sh
npm ci
npm run check
npm test
npx wrangler dev
```

`wrangler.jsonc` contains only generic resource names, reserved example
domains, and no account/resource IDs. Miniflare supplies synthetic credentials
for tests.

## Configure your deployment

Copy `wrangler.jsonc` to ignored `wrangler.local.jsonc`, then set:

- `vars.INSTANCE_ID`;
- `vars.BRAIN_ORIGIN_URL`;
- the D1 `database_id`; and
- the OAuth KV namespace `id`.

Create the named R2 bucket and Queue in the same Cloudflare account. Full
commands and the runner setup are in [remote/setup.md](../remote/setup.md).

Set these independent Worker secrets with Wrangler's interactive prompt:

```sh
npx wrangler secret put AGENT_TOKEN --config wrangler.local.jsonc
npx wrangler secret put ORIGIN_TOKEN --config wrangler.local.jsonc
npx wrangler secret put MCP_PASSWORD --config wrangler.local.jsonc
```

For optional Gmail OAuth, also set an independent `GMAIL_STATE_SECRET` and add
`GMAIL_CALLBACK_URL` to local deployment vars.

Apply migrations and deploy:

```sh
npx wrangler d1 migrations apply vox-brain-gateway --remote \
  --config wrangler.local.jsonc
npx wrangler deploy --dry-run --config wrangler.local.jsonc
npx wrangler deploy --config wrangler.local.jsonc
```

Current Wrangler configuration and resource commands are documented by
[Cloudflare](https://developers.cloudflare.com/workers/wrangler/).

## Versioned API

All `/v1` client routes except pairing claim require a paired device bearer.
Agent routes require the independent Agent bearer.

| Route | Purpose |
|---|---|
| `POST /v1/pair/start`, `/claim`, `/revoke` | one-use device pairing and revocation |
| `POST /v1/captures` | persist capture state/object and enqueue delivery |
| `GET /v1/captures`, `/:id`, `/:id/object` | receipt and original-object reads |
| `GET /v1/status`, `/v1/health` | live origin or explicitly stale snapshot |
| `GET /v1/knowledge/documents`, `/search`, `/document` | bounded Markdown reads |
| `POST /v1/jobs`, `GET /v1/jobs/:id` | fixed Process, Digest, and Ask jobs |
| `/v1/gmail/*` | optional server-side Gmail consent/status relay |
| `/v1/agent/*` | heartbeat, capture result, job result, and object delivery |
| `/mcp`, `/authorize`, `/token`, `/register` | optional single-owner MCP |

Clients cannot select an instance, origin, Queue, R2 key, SQL statement,
repository, command, or local filesystem path.

## MCP

MCP is available only in remote mode. For direct-bearer Codex configuration:

```sh
export BRAIN_MCP_PASSWORD='<your Worker MCP_PASSWORD secret>'
codex mcp add brain \
  --url "https://your-gateway.example/mcp" \
  --bearer-token-env-var BRAIN_MCP_PASSWORD
```

Alternatively configure the `/mcp` URL and use browser OAuth. The MCP password
is not a Brain.app device token.

## Deprecated compatibility route

Legacy `POST /capture` can write through the GitHub Contents API only when all
of `CAPTURE_TOKEN`, `GITHUB_TOKEN`, and `GITHUB_REPOSITORY` are explicitly
configured. New installations must leave it disabled and use
`POST /v1/captures`, Queue, and the canonical runner vault.

## Security

- CORS is disabled unless `CORS_ALLOWED_ORIGINS` contains exact origins.
- Request logs contain route labels and timing, never bodies or bearer values.
- Device, Agent, origin, MCP, Queue, Pages, and Tunnel credentials must be
  independent and rotated at their owning boundary.
- Real values belong in Cloudflare secrets or ignored operator config, never
  the public repository.
