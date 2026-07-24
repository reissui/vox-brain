# Public-release checklist

Application source can be public. A personal Brain vault cannot.

## Never import private history

Create a clean source export for a new public repository. Do not push a private
vault repository and then change its visibility: deleting files or adding
`.gitignore` does not remove earlier commits, author metadata, attachments, or
credentials from Git history.

If a secret has ever reached a Git remote, revoke it before doing anything
else. History rewriting is not credential rotation.

## Personal data

- Keep `BRAIN_DATA_ROOT` outside the source checkout.
- Do not commit `inbox/`, `sources/`, `notes/`, `projects/`, `project-notes/`,
  `people/`, `me/`, `daily/`, `maps/`, `.trash/`, or real attachments.
- Use only synthetic examples with reserved domains and invented identities.
- Inspect generated app archives and site builds; build output can leak data
  even when source paths are ignored.

## Configuration

- Supply account IDs, resource IDs, domains, instance names, repository names,
  and absolute machine paths during setup.
- Store runtime secrets in macOS Keychain, Cloudflare secrets, GitHub encrypted
  Actions secrets, or owner-only generated files outside the checkout.
- Never commit `.dev.vars`, `.env*`, OAuth clients/tokens, Telegram tokens,
  signing certificates, private keys, or generated Wrangler configuration that
  contains operator-specific values.
- Require local mode to work without any remote configuration.

## Verification

Run:

```sh
scripts/public-audit
scripts/check
```

Then also:

- inspect `git log --all --stat` and `git ls-files`;
- run GitHub secret scanning after the first push;
- inspect the packaged `Brain.app`, ZIP, and DMG contents;
- test local setup with a fresh macOS user;
- test remote setup in an account containing no unrelated production
  resources; and
- review release logs for paths, account identifiers, and secret values.

Do not publish until every check passes.
