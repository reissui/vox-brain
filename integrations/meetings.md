# Native Meetings and Voice Notes capture

Brain.app records microphone plus system audio for Meetings and microphone only
for single-speaker Voice Notes on the Mac where the recording occurs. Its
included VoxType speech engine transcribes locally; a compatible standalone
VoxType installation can be used instead and takes precedence. The user reviews
the transcript before Brain sends finalized text to the active local or remote
vault.

Meetings and Voice Notes use the same local recording and transcription
pipeline, but they have separate top-level workspaces and saved lists in
Brain.app.

Recordings saved before Brain stored an explicit meeting/voice-note type are
migrated conservatively. An unrenamed **Voice note** stays in Voice Notes. A
genuinely ambiguous older recording stays in Meetings with a **Choose section**
marker; open it to keep it in Meetings or move it to Voice Notes. Any recording
can also be moved between the two sections later from its detail actions.

```text
Brain.app Meeting (microphone + system) or Voice Note (microphone) capture
  → local VoxType transcription
  → local review and optional AI analysis
     Meetings: speaker editing and talk time
     Voice Notes: plain paragraphs and Copy Full Transcript
  → This Mac: local inbox
     Remote Brain: paired /v1 capture → Queue → Agent → remote inbox
```

Audio never enters either capture request.

## Onboarding and permissions

1. In Brain's Speech Setup, choose **Enable Speech**. Brain prepares the
   recommended model, enables its included speech engine, and starts it without
   leaving the app. If macOS has disabled background items, approve it in the
   Login Items settings page Brain opens.
2. Complete Brain onboarding for **Microphone** and **Accessibility**. Meetings
   also need **Screen & System Audio Recording**; Voice Notes do not.
   Accessibility supports selected-text context and paste-related features;
   Brain does not monitor global keys.
3. Download and activate the recommended model in Brain's Speech Setup. Brain
   defaults English transcription to Whisper Small (English); Whisper Large v3
   Turbo is the multilingual fallback. Additional catalog models remain
   available in Speech settings. See the
   [VoxType model guide](https://voxtype.io/docs/MODEL_SELECTION_GUIDE).
4. In **Audio Tests**, speak for the full microphone test and require visible
   input. A pinned input uses its persistent Core Audio UID and never silently
   switches when missing.
5. Leave **Keep Meeting and Voice Note recordings** off unless local retention
   is an explicit choice.
6. Keep meeting and Voice Note AI disabled or select and test a local CLI
   provider. Brain discloses that transcript text goes to that provider and may
   consume its billing or credits.

## Start, finish, and review

Brain may suggest a meeting when a supported call app is active, but it never
starts or stops recording automatically.

1. Open **Meetings** and choose **Start Meeting**, or open the separate **Voice
   Notes** section and choose **Record Voice Note** for a solo dictated session.
   Confirm the microphone meter moves.
2. Brain automatically retries transient macOS microphone startup failures. If
   the selected input is missing or unusable, Brain stays open at **Choose
   microphone**; choose an available input, then start again. Other capture
   failures still end startup with an error. Once connected, Brain warns when
   no usable microphone signal arrives and keeps recording so a muted or
   temporarily quiet input does not discard the session.
3. Pause/resume explicitly. Dictation cannot take the microphone during either
   kind of recording.
4. Choose **End & Process**. Dismissing the prompt keeps recording.
5. Review the saved item in its own section. Meetings retain speaker editing and
   talk-time totals. Voice Notes show one selectable transcript split into
   readable paragraphs, with **Copy Full Transcript** for copying all text at
   once. Voice Notes remain in the Voice Notes list even after they are renamed.
6. Upload the finalized transcript. Later edits require an explicit revision.

With retention off, Brain removes local audio after final transcript
persistence. With retention on, local reveal/export/delete controls appear,
but the capture payload still contains no audio.

Recording and transcription work is bounded. A failing speech source stops
after repeated errors, partial transcripts remain reviewable, and interrupted
capture or processing is surfaced as a retryable saved recording at the next
launch.

## Delivery behavior

Local mode writes the transcript atomically to the local inbox.

Remote mode uses a stable revision key and succeeds after HTTP 202. Offline or
retryable failures retain the same final Markdown and idempotency key.
**Delivered** means the remote Agent wrote the capture into the canonical
remote inbox.

## Smoke test

Before relying on Meetings or Voice Notes:

1. Run one VoxType dictation.
2. Record a short meeting with audible microphone and system audio.
3. Record a short Voice Note and confirm it appears only in **Voice Notes**.
4. End, process, review, and correct Meeting speakers where applicable. Confirm
   the Voice Note is plain paragraph text and copies in full.
5. Confirm the default reports no retained recording.
6. Confirm both transcripts reach the selected local or remote inbox.
7. Inspect each capture and verify it contains text but no audio.

Retain the previous app artifact until this passes.

## Troubleshooting

- **No microphone:** use the **Choose microphone** recovery prompt described
  above. If no available input works, run the five-second Speech test and
  recheck macOS Microphone permission.
- **No system track:** recheck Screen & System Audio Recording permission.
- **VoxType missing:** choose **Enable Speech** in Speech Setup. If the bundled
  helper is unavailable, Brain links to the official installation guide.
- **Model missing:** use **Download** in Speech Setup or Speech settings; Brain
  downloads, activates, and verifies the catalog model in-app.
- **Remote upload queued:** inspect D1, Queue, Agent logs, and the remote inbox
  in that order.
- **AI unavailable:** raw transcript completion and upload still work; test
  the selected local CLI provider.
