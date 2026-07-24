# Capture from anywhere

Brain.app sends every capture to the explicitly selected mode. It never
silently falls back from remote to local or from local to remote.

## Local mode

Brain.app writes notes, links, images, and transcripts directly below the local
`BRAIN_DATA_ROOT`. Image originals stay in owner-only
`system/attachments/`. No gateway, pairing, Cloudflare resource, MCP server,
or remote runner is involved.

The CLI provides the same basic capture path:

```sh
scripts/brain note "A thought"
scripts/brain add "https://example.com" "Why it matters"
```

## Remote mode

The Cloudflare edge acknowledges `POST /v1/captures` only after D1 state, an
optional permanent R2 original, and a Queue envelope are durable. The remote
Agent then writes the canonical Markdown inbox item.

Remote clients hold only a scoped device token:

```http
POST /v1/captures
Authorization: Bearer <paired-device-token>
Idempotency-Key: <RFC-4122 UUID>
Content-Type: application/json
```

A client cannot choose the runner, repository, Queue, R2 key, command, or
filesystem destination. HTTP 202 means the gateway accepted durable delivery,
not that Librarian processing has completed.

## Brain.app

Press **Control–Option–B** for adaptive capture. Brain can read the focused
application's selected text through Accessibility before it activates its own
UI. A selected HTTP(S) URL becomes a link capture; other selections can open
Apple's single-window picker for a PNG plus user-supplied searchable context.
Cancelling queues nothing.

The manual **Capture…** form accepts:

- notes and dictated text;
- links with optional comment and selected text;
- JPEG, PNG, or WebP images with searchable context; and
- finalized Markdown or text transcripts.

Every remote request uses a stable idempotency key. Retryable failures preserve
the request; accepted captures are polled without resubmitting their body.

## Speech and meetings

VoxType is a separate optional installation for dictation and local meeting
transcription. Brain records microphone and system audio locally, lets the user
review the transcript, and sends only finalized transcript text to the active
Brain mode. Meeting audio is never uploaded.

See [meetings.md](meetings.md).

## Remote-only capture clients

The following require a configured remote gateway:

- the browser extension in `apps/brain-clipper/`;
- iPhone Shortcuts or future share extensions using a capture-scoped token;
- the optional MCP server; and
- third-party clients using the paired `/v1` API.

MCP link, note, file, and transcript writes use the same D1/R2/Queue delivery
pipeline. MCP is intentionally unavailable in local mode; local automation
should call the CLI.

The browser extension currently implements the deprecated token route. New
clients should use pairing and `/v1/captures`. Do not enable the legacy route
unless compatibility is necessary.

## Telegram

The private Telegram bot runs on the remote runner. It reads the canonical
remote vault and normally writes captures directly to its inbox. Only the
paired Telegram account IDs are accepted; bot credentials and conversation
state remain in Keychain or owner-only files on that runner.

## Remote binary delivery

1. D1 records queued/delivery state and safe object metadata.
2. R2 permanently stores the original binary.
3. Queue delivers a bounded envelope to the Agent.
4. The Agent downloads to owner-only temporary state, verifies size and
   SHA-256, ingests the reference, and removes the temporary file.
5. Markdown stores a stable `brain://capture/<id>` reference and metadata, not
   object bytes.

Paired read clients resolve the stable capture ID through the authenticated
object endpoint. R2 keys are never placed in Markdown or returned directly.

## Scope

Remote deployment is single-owner and self-hosted. Public anonymous capture,
multi-tenant routing, arbitrary SSH control, and using Git as a personal sync
bus are non-goals.
