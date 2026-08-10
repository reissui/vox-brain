# Vox Brain

Vox Brain turns links, transcripts, designs, images, meetings, Voice Notes, and
thoughts into a connected plain-Markdown knowledge vault. The vault stays
readable in Finder, Obsidian, a text editor, or any agent that can work with
files.

Brain is local-first. Remote infrastructure is optional and stays out of the
app unless it has been configured.

| Mode | Canonical vault | Processing | Network services |
|---|---|---|---|
| **This Mac** | `~/Library/Application Support/Brain/Vault` on the Mac running Brain.app | bundled Brain CLI on the same Mac | none required; MCP is unavailable |
| **Remote Brain** | a folder on a separately operated Mac or server | Brain CLI and Brain Agent on that runner | paired HTTPS gateway; optional MCP and other server integrations |

The mode changes where the Librarian processes the vault. Switching modes never
deletes the other vault.

## Start locally

Local-only is the default recommendation. It requires no Cloudflare account,
server, pairing, or MCP:

1. Install and open Brain.app.
2. Choose **This Mac**.
3. Brain creates the local vault and stores all new knowledge there.
4. Brain automatically runs the Librarian after new captures so inbox items are
   enriched, filed, linked, and reflected in maps and evidence-backed profiles.
5. Use **AI Setup** to give the Librarian and meeting or Voice Note
   post-processing their own CLI command templates, for example
   `codex exec --skip-git-repo-check --model gpt-5.6-sol`, or use **Activity**
   to follow current work.

The release app contains the reusable Brain CLI, Librarian prompts, and note
templates needed for local operation. Codex is required only for intelligent
commands such as `process`, `digest`, and `ask`; basic capture, local storage,
status, search, and reading remain file-based.

From a source checkout, the same setup is available directly:

```sh
git clone https://github.com/reissui/vox-brain.git
cd vox-brain
scripts/brain init-data
scripts/brain note "A thought"
scripts/brain add "https://example.com" "Why this matters"
scripts/brain search "a phrase"
scripts/brain status
```

Then use the Librarian:

```sh
scripts/brain process
scripts/brain digest
scripts/brain ask "What do I know about this?"
```

Set `BRAIN_DATA_ROOT=/absolute/path` before a command to use a different local
vault. Content commands never require Git and never treat the source checkout
as the knowledge store. See [the local runbook](local/README.md).

## Build Brain.app

Brain.app requires macOS 14 or newer and Swift 6.2:

```sh
swift test --package-path apps/brain-menu
BRAIN_SIGN_IDENTITY=- apps/brain-menu/install.sh
```

The ad-hoc build is suitable for development on your own Mac. Public
distribution requires your own Apple Developer ID certificate and
notarization credentials; see
[the app build guide](apps/brain-menu/README.md).

## Use a remote runner

Choose **Remote Brain** only when you want an always-on Mac/server, capture from
multiple devices, or MCP access. The app pairs with a versioned HTTPS API; the
remote runner owns the vault and executes the same fixed Brain CLI operations.

Cloudflare, D1, R2, Queues, Tunnel, the Brain Agent, server credentials, and MCP
belong entirely to this optional mode. They are not local-mode prerequisites.
Start with [the remote area](remote/README.md). Every account ID, hostname,
resource name, and secret is supplied by the operator. The repository contains
only safe defaults and reserved example domains.

## Data and source are separate

Application assets are read from `BRAIN_SOURCE_ROOT`; personal content is read
and written only below `BRAIN_DATA_ROOT`.

| Vault path | Purpose |
|---|---|
| `inbox/` | durable captures awaiting processing |
| `sources/` | enriched source material and transcripts |
| `notes/` | distilled concept notes |
| `projects/`, `people/`, `me/` | current context and evidence-linked knowledge |
| `daily/` | activity and command-center notes |
| `maps/` | indexes, entities, and topic maps |
| `system/attachments/` | local-only binary originals |

In remote mode, immutable binary originals can instead live in R2 while the
canonical Markdown retains their stable references. In local mode, originals
remain owner-only files inside the local vault.

## Repository map

| Path | Purpose |
|---|---|
| `apps/brain-menu/` | native macOS Brain.app |
| `scripts/`, `prompts/`, `system/templates/` | reusable local runtime |
| `local/` | local-only setup and operation |
| `remote/` | optional remote architecture and setup |
| `gateway/` | optional Cloudflare gateway |
| `apps/brain-agent/` | optional remote runner |
| `CLAUDE.md` | generic Librarian charter bundled with the app |

## Privacy and public-repository boundary

This repository was created as a clean source export: it does not include a
personal vault or the private repository's history. Personal vault content must
never be committed here. GitHub distributes source and releases only.

Before contributing or publishing a fork, run:

```sh
scripts/public-audit
```

The audit catches known private identifiers, credential-shaped files, common
secret formats, and accidental vault directories. It supplements—not
replaces—review and platform secret scanning. See
[the public-release checklist](PUBLIC_RELEASE.md).

Architecture and invariants are documented in [SYSTEM.md](SYSTEM.md).

## License

Vox Brain is available under the [MIT License](LICENSE). The site includes
MIT-licensed upstream components with their original notices preserved.
