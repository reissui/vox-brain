# Brain.app

Brain.app is the native macOS client for one local Markdown vault. On first
launch it automatically configures its bundled runtime and initializes
`~/Library/Application Support/Brain/Vault`; no server setup is required.

Activity shows local recording, transcription, analysis, and Librarian work.
Meetings and Voice Notes have separate saved lists. See the [native capture
guide](../../integrations/meetings.md) for recording and review.

## VoxType speech

VoxType owns recording, transcription, shortcuts, limits, models, and output
behavior. Brain includes a verified VoxType login item for dictation, meetings,
and Voice Notes, and Speech Setup can enable it and download or select an
approved model. A compatible standalone VoxType installation takes precedence.
Brain changes only the speech engine or model the user explicitly selects and
the maximum recording duration when the user starts Live Dictation.

Whisper Large v3 is the single verified fresh-install default for dictation
and final meeting transcription. Live meeting captions are off by default so
recording a call does not compete with Zoom or Meet for the GPU; the full
transcript is built after you stop. Optional live captions use Whisper Small.
The other approved models remain available as explicit fallbacks. Before
recording, Brain attests that VoxType's effective model is exactly the
requested model; a mismatch is shown as a setup failure instead of silently
producing differently sourced transcripts.

**Live Dictation** stays active until stopped and uses a configurable global
shortcut in **Settings → Shortcuts**.

VoxType model downloads and app updates may use the network. They are optional:
local capture, Markdown storage, search, and reading remain local.

## Meetings: floating Transcript / Notes panel

During a meeting or Voice Note, Brain presents a floating **Transcript / Notes**
panel. The Transcript tab shows the local VoxType transcription; the Notes tab
is an editable meeting scratchpad.

- Closing the panel hides it; it does not stop recording or discard the
  meeting. Reopen the panel to return to the same in-progress session.
- Notes autosave locally after a short pause and are atomically persisted.
  Relaunch recovery restores the saved notes for an unfinished meeting.
- Meeting and Voice Note audio stays on the recording Mac. Only final text is
  written to the local inbox.

Saved meetings open on **Processed**. Processing starts as soon as the raw
transcript completes, compares final text with overlapping audio-derived live
previews and speech activity, and removes supported fillers or accidental
repetition. Conservative local cleanup is the mandatory baseline even when the
optional AI provider succeeds, so a no-op provider response cannot restore known
fillers or repetition. **Raw** always exposes the immutable engine evidence,
including preserved previews and bounded failure diagnostics. Adjacent
utterances from one speaker remain one readable turn when silence is under
eight seconds; eight seconds or a speaker change starts a new turn. After
hangup, distinct voices on system audio become Speaker 2, Speaker 3, …; live
captions stay You vs Remote; rename/merge in review still works. Clustering
is local and fail-closed.

Retained meeting audio is playable only on the recording Mac. Transcript
timestamps seek the local player; pause, resume, and explicit audio deletion do
not remove raw or processed transcript text. A stale processed transcript
regenerates when review opens; persistence failures remain retryable and Raw is
always one click away. **Regenerate** bypasses the stored projection and compares
Raw with the audio evidence again. The per-version improvement action builds a
short prompt from the specific failures, timestamps, disfluencies, and correction
categories detected in that call; Brain does not generate, render, or export
follow-up material automatically.

Brain waits for the current Processed projection before its first vault handoff.
The immutable Raw transcript is used only when processing cannot produce a
current, valid projection.

## Local Librarian and AI

Brain bundles the generic Librarian charter, prompts, templates, and CLI
helpers in `Contents/Resources/BrainRuntime`. The Librarian preserves captures
while enriching sources, filing notes, building links and maps, and updating
evidence-backed project, person, and owner-profile material.

Automatic processing can be disabled or run immediately from **AI Setup**.
Each workflow has a command-template field, for example:

```sh
codex exec --skip-git-repo-check --model gpt-5.6-sol
```

Brain validates the template and supplies its fixed sandbox and structured
arguments internally; it never invokes a shell with entered text. An optional,
configured AI provider may receive finalized text for Librarian or meeting
post-processing and may consume its own billing or credits.

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

Release-channel packaging requires a Developer ID identity. The output ZIP
contains the BrainMenu executable, helpers, VoxType login item, local runtime,
application metadata, and signatures. The pinned upstream VoxType binary is
verified by SHA-256 and universal architecture, signed inside Brain’s nested
code, and distributed with its MIT license.

It must not contain vault Markdown, personal attachments, tokens, Git metadata,
OAuth files, source-control history, or machine-specific paths.

## Privacy and permissions

Brain requests permissions only for enabled features:

- Microphone for meeting and Voice Note audio;
- Screen & System Audio Recording for system audio in meetings;
- Accessibility for selected-text context and paste-related features; and
- Notifications for app status.

The included VoxType login item requests its own macOS permissions when needed;
Brain cannot grant them on the user’s behalf. Audio never leaves the recording
Mac. Only final transcript text can enter the local vault.

## Development verification

```sh
scripts/check
```

The suite exercises automatic local setup, capture and attachment retention,
knowledge search/read, fixed CLI jobs, meeting notes persistence, and VoxType
integration boundaries.
