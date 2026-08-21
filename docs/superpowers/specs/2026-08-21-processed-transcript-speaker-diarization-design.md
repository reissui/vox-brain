# Processed transcript speaker diarization

**Date:** 2026-08-21  
**Status:** approved design  
**Scope:** On-device voice clustering of meeting *system audio* after hangup, so Raw and Processed transcripts show distinct remote speakers. Live captions and Voice Notes are unchanged.

## Problem

Meetings already split **mic → You** and **system audio → Remote**. Everyone on Zoom/Meet is one Remote speaker. The turn assembler *intentionally* ignores `baseSpeakerID` on system utterances because that field is untrusted transcriber output. Processed copies those resolved speaker IDs exactly and is forbidden from inventing names.

The owner wants the **final** Raw + Processed views to split different people on the call. Live preview stays You/Remote. Names stay generic until the owner (or later AI rename) edits them.

## Non-goals

- Live-caption diarization
- Voice Notes
- Sending audio off-box
- Splitting a single Whisper span that mixed two people
- Auto-naming people from conversation (“that’s Alex”)
- Changing VoxType, the selected dictation/final model, or the copy-speakers Processed rule
- Python / WhisperX / nested pyannote CLI

## Pipeline

```text
hangup → final Large v3 utterances → cluster system spans → persist remote-N
       → assemble turns → Processed copies speakers as today
```

Diarization runs **after** successful final transcription and **before** the first Processed assembly. GPU is free. The meeting is not failed if clustering no-ops.

## Data flow

1. Persist final utterances as today (mic `you`, system `remote` or empty).
2. If the item is a meeting, has a retained system track, and has at least two unsuppressed system utterances, run the diarizer.
3. Diarizer writes **only** `baseSpeakerID = remote-N` on system utterances it clustered. Mic utterances are never in the map.
4. Turn assembly and talk time share one resolver (below).
5. Processed still copies `speakerID` / `speakerLabel` from assembled turns. No prompt change.

Live captions never call the diarizer, so they keep resolving to Remote.

## Speaker IDs and labels

| ID | Label | Who writes it |
|---|---|---|
| `you` | You | mic default |
| `remote` | Remote | system default, or fail-closed cluster |
| `remote-2`, `remote-3`, … | Speaker 2, Speaker 3, … | diarizer only |

- IDs match `^remote-[0-9]+$`. Numbering starts at **2** and is assigned in **first-appearance** order (earliest `startMilliseconds`, then existing utterance order for ties).
- **0 or 1 cluster** → write nothing; system stays `Remote`. No fake split.
- Whisper / VoxType / leftover `baseSpeakerID` strings (`untrusted-diarization`, names, hashes) stay **ignored**.
- Manual speaker assignments still win over defaults and over `remote-N`.
- Owner split IDs (`speaker-<hex>`) remain a separate namespace.

## Shared resolver

Used by `MeetingTranscriptTurnAssembler` and `TalkTimeCalculator`:

1. If a **manual** assignment exists for the utterance, use it.
2. Else if source is **microphone**, use `you`.
3. Else if `baseSpeakerID` matches `^remote-[0-9]+$`, use that ID (label `Speaker N`).
4. Else `remote` / Remote.

Do not use `humanName` from the transcriber as a label.

## Components

### `MeetingSpeakerDiarizer`

```text
assign(utterances:systemTrack:) -> [UUID: String]
```

- Input: final utterances + retained system audio (PCM or decoded AAC at known sample rate).
- Output: map of **system** utterance IDs → `remote-N`. Empty map is a valid no-op.
- Mic IDs must never appear.

### Embedder

```text
embed(pcm:sampleRate:) -> [Float]   // L2-normalizable, fixed dimension
```

- Production: Core ML speaker encoder (ECAPA / WeSpeaker class) in app Resources, loaded on-device. Pin filename, vector dimension, input sample rate (16 kHz mono), and SHA-256. Fetch-at-package like VoxType; do not require CI to load the model.
- Tests: inject a fake. Never call Core ML in unit tests.
- If the model file is missing or load fails: return no embeddings (fail closed).

### Cluster

- One embedding per **unsuppressed system** utterance whose span is long enough and not silent.
- Skip spans shorter than 500 ms or below the existing speech-activity gate. Skipped utterances stay Remote.
- L2-normalize. Agglomerative clustering, average linkage, cosine similarity. Same-speaker merge when cosine ≥ `sameSpeakerCosineThreshold` (named constant; tests use identical vs orthogonal vectors so the exact float can be chosen in implementation without changing behavior).
- 2+ clusters → `remote-2`… in first-appearance order. Each included utterance gets exactly one cluster. A mashed Whisper span is **not** split.
- 0–1 cluster → empty map.

### Coordinator

After finals are stored, before Processed:

1. Run diarizer.
2. Apply `remote-N` onto those utterances’ `baseSpeakerID`.
3. Persist. Then Processed runs as today.

Voice Notes: skip. Missing system track: skip. Diarizer throw/crash: catch, leave utterances unchanged, meeting still succeeds.

## Fail closed

| Case | Result |
|---|---|
| No system audio / deleted audio | Remote, meeting succeeds |
| Embed/model failure | Remote, meeting succeeds |
| One cluster or all spans skipped | Remote |
| Two people in one Whisper span | Whole utterance → one cluster |
| Live captions | Never run |
| Voice Notes | Never run |
| Re-transcribe | Re-cluster new utterance IDs; manuals on surviving IDs still win |
| Processed AI | Copies speakers; does not invent names |

## Tests (fake embedder)

- Two distinct system embeddings → `remote-2` / `remote-3`; mic stays You; both Raw assembly and first Processed build see them.
- Identical embeddings / single cluster → still Remote.
- Junk `baseSpeakerID` ignored until we write `remote-N`.
- Manual rename/merge still wins.
- Assembler and talk time share the resolver (talk time rows for Speaker 2 / Speaker 3, not one Remote blob).
- Live snapshot without `remote-N` still shows Remote.
- Missing audio / embed failure: coordinator does not fail the meeting.

## Privacy

Audio never leaves the Mac. Embeddings and clustering are local. Only finalized transcript text may go to an optional AI provider, same as today.

## Docs

Update `integrations/meetings.md` and `apps/brain-menu/README.md`: after hangup, distinct remote voices become Speaker 2/3…; live captions stay You/Remote; owner can still rename/merge.
