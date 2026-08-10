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
Meetings and Voice Notes have separate top-level workspaces and saved lists;
see the [native capture guide](../../integrations/meetings.md) for the recording
and review workflow.

Speech and recording setup no longer blocks first launch. Brain includes
VoxType as an optional speech engine for dictation, meeting transcription, and
Voice Note transcription.

## Included VoxType speech

Brain's Speech Setup downloads and selects the verified Whisper English model,
then enables
and starts the included VoxType login item without opening a browser or
installer. If macOS has disabled background items, Brain opens the exact Login
Items settings page for approval. A compatible standalone VoxType installation
remains supported and takes precedence over the included copy.

Brain 0.1.3 also repairs the incompatible Parakeet default offered by 0.1.2:
when VoxType 0.7.5 reports that selection, Brain downloads and activates the
bundled-compatible Whisper model before dictation is used.

Brain can also download and activate additional catalog-approved models from
Speech settings. VoxType continues to own recording, transcription, shortcut,
limits, and output behavior.
Brain read-only tails VoxType's existing local `stdout.log` for Dictation
History and records text only after VoxType logs successful output. Brain
changes only an explicitly selected speech engine/model and leaves the rest of
VoxType's configuration untouched.

For meetings, Brain records microphone plus system audio. Voice Notes are
single-speaker microphone-only recordings, so they do not depend on Screen &
System Audio permission or a second source. VoxType transcribes both workflows
locally. Every Meeting and Voice Note recording remains private on this Mac
until the user explicitly deletes the recording or its item. Failed or
interrupted jobs retain their source audio for explicit retry and never resume
automatically when Brain launches.
The app checks **Microphone**, **Screen & System Audio
Recording**, and **Accessibility** permissions only when their related features
are used.

## Local mode

Local mode provides:

- owner-only local attachment storage;
- direct vault access in Finder and Obsidian;
- accurate local activity and Librarian progress;
- automatic local Librarian processing after capture and every 15 minutes;
- separate, single-line CLI command templates for Librarian work and meeting
  or Voice Note post-processing under **AI Setup**; and
- local Meetings and Voice Notes, plus optional VoxType speech.

The app package contains `Contents/Resources/BrainRuntime` with the generic
Librarian charter, prompts, templates, and CLI helpers. It contains no personal
vault content. Codex is needed for Librarian intelligence, but not for basic
capture, storage, search, or reading.

The Librarian preserves captured words while enriching sources, filing notes,
building links and maps, and updating project, person, and owner-profile
material from evidence in the vault. Automatic processing can be disabled or
run immediately from **AI Setup**.

Each AI workflow uses one command-template field instead of an application or
executable picker. For example:

```sh
codex exec --skip-git-repo-check --model gpt-5.6-sol
```

Brain validates the template, selects the requested model, and adds its fixed
sandbox and structured-output arguments internally. It never invokes a shell
with the entered text.

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
the app, embeds the pinned VoxType login item, and atomically installs it at
`~/Applications/Brain.app` by default.

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
- `Contents/Library/LoginItems/VoxType.app`;
- `Contents/Resources/BrainRuntime`; and
- application metadata and signatures.

The VoxType binary is fetched from the pinned upstream release, verified by
SHA-256 and universal architecture, then signed inside Brain's nested code
before the outer app is signed and notarized. Its upstream MIT license ships
inside the nested app.

It must not contain vault Markdown, personal attachments, tokens, Git metadata,
OAuth files, source-control history, or machine-specific paths.

## Privacy and permissions

Brain requests permissions only for features the user enables:

- Microphone for meeting and Voice Note audio;
- Screen & System Audio Recording for system audio in meetings;
- Accessibility for selected-text context and paste-related features; and
- Notifications for app status.

The included VoxType login item requests its own macOS permissions when the
speech engine first needs them; Brain cannot grant those permissions on the
user's behalf.

Local and remote modes always keep Meeting and Voice Note audio on the recording
Mac until the user explicitly deletes it. Only finalized transcript text can
enter the configured Brain vault.

## Development verification

```sh
swift test --package-path apps/brain-menu
scripts/public-audit
```

Local-mode tests create isolated temporary vaults and exercise initialization,
capture, local attachment retention, knowledge search/read, and fixed CLI jobs.
Remote tests continue to verify pairing, token handling, API boundaries,
delivery, stale status, and closed job controls.
