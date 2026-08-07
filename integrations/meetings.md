# Native meeting capture

Brain.app records microphone plus system audio on the Mac where the meeting
occurs. Its included VoxType speech engine transcribes locally; a compatible
standalone VoxType installation can be used instead and takes precedence. The
user reviews the transcript before Brain sends finalized text to the active
local or remote vault.

```text
Brain.app audio capture
  → local VoxType transcription
  → local review, speakers, talk time, and optional AI analysis
  → This Mac: local inbox
     Remote Brain: paired /v1 capture → Queue → Agent → remote inbox
```

Audio never enters either capture request.

## Onboarding and permissions

1. In Brain's Speech Setup, choose **Enable Speech**. Brain prepares the
   recommended model, enables its included speech engine, and starts it without
   leaving the app. If macOS has disabled background items, approve it in the
   Login Items settings page Brain opens.
2. Complete Brain onboarding for **Microphone**, **Screen & System Audio
   Recording**, and **Accessibility**. Accessibility supports selected-text
   context and paste-related features; Brain does not monitor global keys.
3. Download and activate the recommended model in Brain's Speech Setup. Brain
   defaults English meetings to Parakeet TDT 0.6B v3; Whisper large-v3-turbo is
   the multilingual fallback. Additional catalog models remain available in
   Speech settings. See the
   [VoxType model guide](https://voxtype.io/docs/MODEL_SELECTION_GUIDE).
4. In **Audio Tests**, speak for the full microphone test and require visible
   input. A pinned input uses its persistent Core Audio UID and never silently
   switches when missing.
5. Leave **Keep meeting recordings** off unless local retention is an explicit
   choice.
6. Keep meeting AI disabled or select and test a local CLI provider. Brain
   discloses that transcript text goes to that provider and may consume its
   billing or credits.

## Start, finish, and review

Brain may suggest a meeting when a supported call app is active, but it never
starts or stops recording automatically.

1. Choose **Start Meeting**, or **Record Voice Note** for a solo dictated
   session, and confirm the microphone meter moves.
2. Brain warns when no usable microphone signal arrives during startup and
   keeps recording so a muted or temporarily quiet input does not discard the
   session.
3. Pause/resume explicitly. Dictation cannot take the microphone during a
   meeting.
4. Choose **End & Process**. Dismissing the prompt keeps recording.
5. Review transcript, speakers, talk-time totals, summary, action items, and
   any email draft.
6. Upload the finalized transcript. Later edits require an explicit revision.

With retention off, Brain removes local audio after final transcript
persistence. With retention on, local reveal/export/delete controls appear,
but the capture payload still contains no audio.

Recording and transcription work is bounded. A failing speech source stops
after repeated errors, partial transcripts remain reviewable, and interrupted
capture or processing is surfaced as a retryable meeting at the next launch.

## Delivery behavior

Local mode writes the transcript atomically to the local inbox.

Remote mode uses a stable revision key and succeeds after HTTP 202. Offline or
retryable failures retain the same final Markdown and idempotency key.
**Delivered** means the remote Agent wrote the capture into the canonical
remote inbox.

## Smoke test

Before relying on meeting capture:

1. Run one VoxType dictation.
2. Record a short meeting with audible microphone and system audio.
3. End, process, review, and correct speakers.
4. Confirm the default reports no retained recording.
5. Confirm the transcript reaches the selected local or remote inbox.
6. Inspect the capture and verify it contains text but no audio.

Retain the previous app artifact until this passes.

## Troubleshooting

- **No microphone:** run the five-second Speech test, reconnect a pinned input,
  or choose System Default; recheck macOS Microphone permission.
- **No system track:** recheck Screen & System Audio Recording permission.
- **VoxType missing:** choose **Enable Speech** in Speech Setup. If the bundled
  helper is unavailable, Brain links to the official installation guide.
- **Model missing:** use **Download** in Speech Setup or Speech settings; Brain
  downloads, activates, and verifies the catalog model in-app.
- **Remote upload queued:** inspect D1, Queue, Agent logs, and the remote inbox
  in that order.
- **AI unavailable:** raw transcript completion and upload still work; test
  the selected local CLI provider.
