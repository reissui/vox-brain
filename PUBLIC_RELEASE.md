# Public-release checklist

Application source can be public. A personal Brain vault cannot.

## Never import private history

Create a clean source export for a new public repository. Do not make a
private vault repository public: deleting files or adding `.gitignore` does not
remove earlier commits, author metadata, attachments, or credentials from Git
history.

If a secret has reached any Git host, revoke it before doing anything else.
History rewriting is not credential rotation.

## Personal data

- Keep `BRAIN_DATA_ROOT` outside the source checkout.
- Do not commit `inbox/`, `sources/`, `notes/`, `projects/`, `project-notes/`,
  `people/`, `me/`, `daily/`, `maps/`, `.trash/`, or real attachments.
- Use only synthetic examples with reserved domains and invented identities.
- Inspect generated app archives; build output can leak data even when source
  paths are ignored.

## Configuration

- Store release signing and notarization credentials in macOS Keychain or
  owner-only generated files outside the checkout.
- Never commit `.env*`, OAuth clients or tokens, signing certificates, private
  keys, or generated configuration containing personal values.
- Keep the product usable with its local vault and bundled runtime alone.

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
- test automatic local setup with a fresh macOS user; and
- review release logs for paths and secret values.

Do not publish until every check passes.
