# Local-only Brain

Local mode keeps the app, Markdown vault, attachments, search, and Librarian
commands on one Mac. It needs no gateway, server, Cloudflare account, device
pairing, or MCP configuration.

## App setup

On first launch choose **This Mac**. Brain.app:

1. resolves its bundled Brain CLI;
2. initializes `~/Library/Application Support/Brain/Vault`;
3. records local mode in app preferences;
4. sends capture, knowledge, Ask, Process, and Digest operations to that local
   vault; and
5. keeps image originals under `system/attachments/` with owner-only
   permissions.

Open **Settings → Storage & Mode** to reveal the vault in Finder or switch to a
remote Brain later. Switching is non-destructive.

## CLI setup from source

```sh
git clone https://github.com/reissui/vox-brain.git
cd vox-brain
scripts/brain init-data
scripts/brain doctor
```

An alternative absolute vault location is supported:

```sh
BRAIN_DATA_ROOT="/absolute/path/to/My Brain" scripts/brain init-data
```

Use the same environment variable for later commands. The source directory is
read-only runtime material; the data directory is the only canonical
knowledge store.

## Dependencies

- macOS 14 or newer for Brain.app
- Python 3 and standard macOS command-line tools for the CLI
- Codex signed in with ChatGPT for `process`, `digest`, `ask`, and `journal`
- VoxType only for optional dictation and meeting transcription

Capture, Markdown storage, local knowledge search, and document reading do not
depend on Codex, VoxType, Git, MCP, or any remote service.

MCP is intentionally unavailable in local mode because there is no network
gateway. Local automation should call `scripts/brain` directly.

## Backups

Local mode has no synchronization service. Back up the vault with Time Machine
or another filesystem backup. Backing up the source checkout does not back up
the vault.
