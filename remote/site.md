# Private site publisher

The optional remote Agent can publish an allowlisted, searchable Astro site to
the Cloudflare Pages project `brain-vault`. Personal content never passes
through GitHub.

## Privacy boundary

The publisher creates owner-only temporary staging and output directories. It
may stage:

- generated `index.md`, `designs.md`, and `bookmarks.md`;
- `sources/`, `notes/`, and `maps/`;
- generated privacy-safe `project-notes/`; and
- explicitly referenced, hash-verified attachments.

It must not stage `me/`, `daily/`, `people/`, private project prose, `inbox/`,
`.trash/`, credentials, or source code. R2 originals are fetched through the
authenticated Agent object route and checked against Markdown SHA-256 and size
metadata before use.

Both temporary trees are removed after success, failure, timeout, or signal.

## Setup

Create the fixed project name used by the publisher:

```sh
npx wrangler pages project create brain-vault --production-branch main
```

Protect its Pages hostname with Cloudflare Access before the first personal
deployment. Create an API token with only
`Account → Cloudflare Pages → Edit` and store it in Keychain:

```sh
security add-generic-password -U -a "$USER" -s app.voxbrain.pages-api-token -w
```

The Agent installer places this value only in the owner-readable publisher
environment. The long-running Agent does not receive the Pages credential.
Cloudflare's current direct-upload flow is documented at
<https://developers.cloudflare.com/pages/get-started/direct-upload/>.

## Verify locally

```sh
cd site
npm ci
npm run check
BRAIN_SITE_CONTENT_ROOT=/absolute/path/to/synthetic/content npm run build
```

Use synthetic content for source-repository tests. Never point a public CI job
at a real vault.

## Troubleshooting

Publisher status and logs live under
`~/Library/Application Support/Brain Agent/`.

- `object_mismatch`: repair the R2 object or canonical metadata; do not bypass
  the hash check.
- `privacy_check_failed`: a path escaped the exact allowlist.
- `command_unavailable`: install Node.js 22 and npm.
- `command_failed`: inspect the bounded build/deploy error.
- `timeout` or `signal`: temporary content was removed and launchd can retry.

Finally, verify Cloudflare Access challenges an unauthenticated browser, admits
only the intended identity, and returns 404 for `/me`, `/daily`, `/people`,
`/projects/<private-project>`, and `/inbox`.
