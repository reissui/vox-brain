# Vox Brain

Vox Brain is a local-only, plain-Markdown second brain for macOS. It turns
links, transcripts, designs, images, meetings, Voice Notes, and thoughts into
one canonical vault that stays readable in Finder, Obsidian, a text editor, or
an agent that works with files.

The vault is created at `~/Library/Application Support/Brain/Vault` by default.
`BRAIN_SOURCE_ROOT` contains the read-only app runtime; `BRAIN_DATA_ROOT`
contains the only durable personal data. Content commands never need Git and
never use the source checkout as the vault.

## Start locally

1. Install and open Brain.app.
2. It automatically creates the local vault and configures its bundled runtime.
3. Capture a note, link, meeting, or Voice Note. The local Librarian files and
   links captures after they arrive in the inbox.
4. Use **AI Setup** to configure an optional CLI provider for Librarian and
   meeting post-processing, or use **Activity** to follow work.

VoxType owns speech: recording, transcription, shortcut, limits, models, and
output behavior. Brain can enable its included VoxType copy and select an
explicit model, while a compatible standalone installation takes precedence.
Whisper Large v3 is Brain's single verified default for dictation, live meeting
preview, and final meeting transcription. Other catalog models remain
available as explicit fallbacks, but Brain verifies the requested and active
model identities match before a recording starts.

Meetings use a floating **Transcript / Notes** panel. Transcript text is
produced on the Mac; Notes autosave locally and remain available for recovery.
After final transcription, Brain keeps immutable raw evidence and creates a
separate, replaceable processed transcript for readable review and optional AI
analysis. Review defaults to the current processed transcript and always
offers the raw fallback. Retained audio has local playback and timestamp seek;
only finalized text is ingested into the vault and meeting audio stays on the
recording Mac. See [the meeting guide](integrations/meetings.md).

From a source checkout:

```sh
git clone https://github.com/reissui/vox-brain.git
cd vox-brain
scripts/brain init-data
scripts/brain note "A thought"
scripts/brain add "https://example.com" "Why this matters"
scripts/brain search "a phrase"
scripts/brain status
```

For intelligent filing and retrieval, run:

```sh
scripts/brain process
scripts/brain digest
scripts/brain ask "What do I know about this?"
```

Set `BRAIN_DATA_ROOT=/absolute/path` before a command to use another local
vault. [The local runbook](local/README.md) has setup, dependencies, and backup
guidance.

## Build Brain.app

Brain.app requires macOS 14 or newer and Swift 6.2:

```sh
swift test --package-path apps/brain-menu
BRAIN_SIGN_IDENTITY=- apps/brain-menu/install.sh
```

The ad-hoc build is suitable for development on your Mac. Public distribution
requires your own Apple Developer ID certificate and notarization credentials;
see [the app build guide](apps/brain-menu/README.md).

## Vault layout

| Vault path | Purpose |
|---|---|
| `inbox/` | durable captures awaiting processing |
| `sources/` | enriched source material and transcripts |
| `notes/` | distilled concept notes |
| `projects/`, `people/`, `me/` | current context and evidence-linked knowledge |
| `daily/` | activity and command-center notes |
| `maps/` | indexes, entities, and topic maps |
| `system/attachments/` | owner-only binary originals |

## Repository map

| Path | Purpose |
|---|---|
| `apps/brain-menu/` | native macOS Brain.app |
| `scripts/`, `prompts/`, `system/templates/` | reusable local runtime |
| `local/` | local setup and operation |
| `CLAUDE.md` | Librarian charter bundled with the app |

## Privacy and public-repository boundary

This repository is a clean source export. It never contains a personal vault
or private history. GitHub distributes source and releases only.

Before contributing or publishing a fork, run:

```sh
scripts/public-audit
scripts/check
```

The audit fails on known private vault paths and exports, credential-shaped
files, and common secret formats. It supplements review and platform secret
scanning; see [the public-release checklist](PUBLIC_RELEASE.md).

Architecture and invariants are documented in [SYSTEM.md](SYSTEM.md).

## License

Vox Brain is available under the [MIT License](LICENSE).
