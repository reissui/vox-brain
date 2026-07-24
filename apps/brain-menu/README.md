# Brain.app

Brain.app is the native macOS client for Brain. It supports a fully local vault
and an optional paired remote runner.

## First launch

Brain asks where the canonical vault should live:

- **This Mac** initializes
  `~/Library/Application Support/Brain/Vault`, uses the runtime bundled inside
  Brain.app, and requires no server or pairing.
- **Remote Brain** opens the pairing flow for a separately operated Brain
  runner and HTTPS gateway.

Activity is the local-first home screen. It shows current recording,
transcription, analysis, and Librarian work using actual local process state,
plus recent completed work. Remote services stay hidden unless configured.

Speech and meeting setup no longer blocks first launch. VoxType is an optional
separate installation used only for dictation and meeting transcription.

## Optional VoxType speech

VoxType is installed separately. VoxType owns dictation end to end: shortcut,
recording, models, limits, transcription, and output.
Brain read-only tails VoxType's existing local `stdout.log` for Dictation
History and records text only after VoxType logs successful output. Brain never
changes VoxType configuration, and VoxType dictation continues unaffected.

For meetings, Brain records microphone plus system audio and uses VoxType for
local transcription. Failed or interrupted jobs retain their private source
audio for explicit retry and never resume automatically when Brain launches.
The app checks **Microphone**, **Screen & System Audio
Recording**, and **Accessibility** permissions only when their related features
are used.

## Local mode

Local mode provides:

- owner-only local attachment storage;
- direct vault access in Finder and Obsidian;
- accurate local activity and Librarian progress;
- fixed local Librarian processing; and
- local meetings and optional VoxType speech.

The app package contains `Contents/Resources/BrainRuntime` with the generic
Librarian charter, prompts, templates, and CLI helpers. It contains no personal
vault content. Codex is needed for Librarian intelligence, but not for basic
capture, storage, search, or reading.

MCP, Cloudflare, pairing, remote device credentials, Gmail, runner health, and
private-site access are hidden in local mode.

## Remote mode

Remote mode preserves the existing paired-client boundary:

- the runner owns the canonical Markdown vault and Brain CLI;
- Brain.app communicates only with the public HTTPS gateway;
- the opaque device token is stored under Keychain service
  `app.voxbrain.device`;
- jobs use stable identifiers and fixed API routes; and
- no SSH key, runner path, Cloudflare credential, or arbitrary command reaches
  the client.

Configured remote integrations appear only when their service is available.
See [the remote runbook](../../remote/README.md).

## Build and install from source

Brain requires macOS 14 or newer.

```sh
apps/brain-menu/install.sh
```

The development installer requires a clean Git checkout because the displayed
version identifies the exact source revision. It builds `BrainMenu` and the
lossless `BrainDictationObserver`, assembles the reusable local runtime, signs
the app, and atomically installs it at `~/Applications/Brain.app` by default.

Set `BRAIN_MENU_APP_DEST` to use another destination. Set
`BRAIN_SIGN_IDENTITY=-` only for an explicit ad-hoc build.

## Package a release

```sh
BRAIN_APP_VERSION=1.2.3 \
BRAIN_APP_BUILD=123 \
BRAIN_APP_SOURCE_SHA="$(git rev-parse HEAD)" \
BRAIN_APP_CHANNEL=development \
BRAIN_APP_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
apps/brain-menu/package.sh
```

Release-channel packaging requires a Developer ID identity. The output ZIP must
contain:

- `Contents/MacOS/BrainMenu`;
- `Contents/Helpers/BrainDictationObserver`;
- `Contents/Helpers/BrainUpdater`;
- `Contents/Resources/BrainRuntime`; and
- application metadata and signatures.

It must not contain vault Markdown, personal attachments, tokens, Git metadata,
OAuth files, source-control history, or machine-specific paths.

## Privacy and permissions

Brain requests permissions only for features the user enables:

- Microphone for meeting audio;
- Screen & System Audio Recording for system meeting audio;
- Accessibility for selected-text context and paste-related features; and
- Notifications for app status.

Meeting audio retention is off by default. Local and remote modes both keep
recording audio on the recording Mac; only finalized transcript text can enter
the configured Brain vault.

## Development verification

```sh
swift test --package-path apps/brain-menu
scripts/public-audit
```

Local-mode tests create isolated temporary vaults and exercise initialization,
capture, local attachment retention, knowledge search/read, and fixed CLI jobs.
Remote tests continue to verify pairing, token handling, API boundaries,
delivery, stale status, and closed job controls.
