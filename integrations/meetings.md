# Native Meetings and Voice Notes capture

Brain.app records Meetings with microphone plus system audio and Voice Notes
with microphone only. VoxType transcribes on the recording Mac. Audio is never
written to the vault; only the text you finalize is ingested locally.

Meetings and Voice Notes share the recording pipeline but have separate saved
lists. A saved Voice Note remains in Voice Notes after it is renamed. Older,
ambiguous recordings are kept conservatively until you choose their section.

```text
Brain.app capture → local VoxType transcription → local review and optional AI
analysis → finalized text → local inbox
```

## Onboarding and permissions

1. In **Speech Setup**, choose **Enable Speech**. Brain prepares its recommended
   model, enables the included VoxType speech engine, and starts it. Approve the
   Login Items setting if macOS has disabled the background item.
2. Allow **Microphone** and **Accessibility** when prompted. Meetings also need
   **Screen & System Audio Recording**. Accessibility supports selected-text
   context and paste-related features; Brain does not monitor global keys.
3. Choose a model in Speech Setup. Whisper Large v3 is Brain's single verified
   default for dictation, live preview, and final meeting transcription. Other
   approved models, including Whisper Large v3 Turbo, remain explicit
   fallbacks. Brain blocks recording if VoxType reports a different effective
   model from the one requested.
4. In **Audio Tests**, confirm microphone input. A pinned input uses its
   persistent Core Audio UID and never silently switches when missing.
5. Optionally configure and test an AI provider. Brain discloses that finalized
   transcript text goes to that provider and may consume billing or credits.

## Start, finish, and review

Brain may suggest a meeting when a supported call app is active, but never
starts or stops recording automatically.

1. Open **Meetings** and choose **Start Meeting**, or choose **Record Voice
   Note** for a solo session. Confirm the microphone meter moves.
2. If the selected input is unavailable, choose an available microphone and
   start again. Brain retains partial recordings and transcript text when a
   capture interruption cannot recover.
3. Pause and resume explicitly. Dictation cannot use the microphone during a
   recording.
4. Choose **End & Process**. Dismissing the prompt keeps recording.
5. Review the saved item. **Processed** is selected automatically when a
   current processed transcript exists; **Raw** remains the immutable fallback
   with preserved previews, failed-span diagnostics, and verified model
   metadata. Same-speaker utterances separated by less than eight seconds are
   one readable turn; eight seconds or a speaker change starts a new turn.
   Meetings support speaker editing and talk-time totals; Voice Notes show
   readable paragraphs and **Copy Full Transcript**.
6. Finalize the transcript to write it to the local inbox. Later edits create
   an explicit revision.

The floating **Transcript / Notes** panel stays attached to an in-progress
meeting. Closing it hides it rather than stopping the meeting; reopen it to
return to the same session. Notes autosave atomically after edits and are
available after relaunch recovery.

After transcription, Brain retains compact AAC audio locally and exposes
reveal, export, playback, timestamp seek, and explicit delete controls. Pause,
resume, seek, and audio deletion leave both transcript versions readable.
Failed or interrupted attempts keep private source audio for recovery. Deleting
a recording removes its audio; deleting its entire item removes all of that
item’s data. Brain never automatically deletes a saved recording.

Processed text is a separate, replaceable projection of the immutable raw
attempt. Private terminology can correct supported spellings while every change
keeps an audit record; unsupported invented content is rejected. Optional
analysis uses the current processed transcript and falls back to raw evidence
when processing is unavailable. A stale or failed processed transcript stays
retryable from review and never hides the raw transcript. **Create Improvement
Prompt** runs only when pressed and produces bounded quality diagnostics for
copying—no transcript content and no automatic follow-up generation, rendering,
or export.

## Smoke test

1. Run one VoxType dictation.
2. Record a short meeting with audible microphone and system audio.
3. Record a short Voice Note and confirm it appears only in **Voice Notes**.
4. End, process, review, and correct the Meeting speakers where needed.
5. Confirm both items have local reveal, export, and delete controls after
   transcription completes.
6. Finalize both transcripts and confirm they appear in the local inbox.
7. Inspect each capture and verify it contains text but no audio.

Keep the previous app artifact until this passes.

## Troubleshooting

- **No microphone:** choose a microphone in the recovery prompt, run the
  five-second Speech test, and recheck macOS Microphone permission.
- **Recording interrupted:** reconnect the microphone, run the Speech test,
  and start a new recording. The partial transcript and source audio remain
  available for review and transcription retry.
- **Processed transcript unavailable:** switch to **Raw** to keep reviewing the
  immutable transcript, then choose **Retry Processing**. A failed retry does
  not replace the last valid analysis or alter the raw attempt.
- **No system track:** recheck Screen & System Audio Recording permission.
- **VoxType or a model is missing:** use **Enable Speech** or **Download** in
  Speech Setup.
- **AI unavailable:** final transcript ingestion still works; test the selected
  provider before requesting optional analysis.
