# Processed Transcript Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After hangup, cluster distinct voices on the meeting system-audio track and persist `remote-N` on those utterances so Raw and Processed both show Speaker 2/3… instead of one Remote.

**Architecture:** A shared `MeetingSpeakerIdentity` resolver is the only place that maps mic/system/`remote-N`/manual edits to IDs and labels. A `MeetingSpeakerDiarizer` embeds each unsuppressed system utterance from the retained 16 kHz mono PCM track, agglomerative-clusters those vectors, and writes `remote-2+` onto `baseSpeakerID` before the transcript attempt is frozen. Processed keeps copying assembled speaker IDs. Live captions and Voice Notes never call the diarizer. Missing model/audio fails closed to Remote.

**Tech Stack:** Swift 6 / macOS 14, Swift Testing, existing `SpeechActivityGate`, optional Core ML `SpeakerEncoder.mlmodelc` in the app bundle (tests inject a fake embedder).

## Global Constraints

- Audio never leaves the Mac; embeddings and clustering are local.
- Live captions never run the diarizer; Voice Notes never run the diarizer.
- Whisper/VoxType `baseSpeakerID` strings are untrusted; only `^remote-[0-9]+$` written by us is honored.
- Cluster numbering starts at **2** in first-appearance order; 0–1 clusters write nothing (stay Remote).
- Manual speaker assignments still win.
- Processed still copies speaker IDs/labels; it does not invent names.
- One Whisper span is one speaker; do not split mashed overlap.
- Skip system spans shorter than 500 ms or not speech-bearing per `SpeechActivityGate`.
- Diarizer throw/missing audio/missing Core ML: empty map, meeting still succeeds.
- Tests never load Core ML. Fake embedder only.
- Do not change VoxType, the selected dictation/final model, or the Processed copy-speakers rule.
- No Python, WhisperX, or nested pyannote CLI.

## File structure

| File | Responsibility |
|---|---|
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerIdentity.swift` | Shared ID/label resolver used by assembler and talk time |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerClusterer.swift` | L2-normalize + agglomerative average-linkage cosine clustering |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSystemAudioSlicer.swift` | Read 16 kHz mono f32le PCM and slice by utterance timestamps |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerEmbeddingClient.swift` | `embed(pcm:sampleRate:) -> [Float]?` protocol |
| `apps/brain-menu/Sources/BrainMenu/Meetings/CoreMLSpeakerEmbeddingClient.swift` | Bundle Core ML loader; fail closed if missing/invalid |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerDiarizer.swift` | Skip/embed/cluster/map utterance IDs → `remote-N` |
| `apps/brain-menu/Sources/BrainMenu/Meetings/SpeakerEditor.swift` | `defaultDisplayName` for `remote-N` → `Speaker N` |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptTurnAssembler.swift` | Use shared resolver; stop forcing all system audio to Remote |
| `apps/brain-menu/Sources/BrainMenu/Meetings/TalkTimeCalculator.swift` | Use shared resolver instead of source-only You/Remote |
| `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptionCoordinator.swift` | Run diarizer after finals, before `makeAttempt` |
| `apps/brain-menu/fetch-speaker-encoder.sh` | Optional model fetch/copy with SHA-256; skip if unset |
| `apps/brain-menu/package.sh` | Copy `SpeakerEncoder.mlmodelc` into the app if present |
| `integrations/meetings.md`, `apps/brain-menu/README.md` | Owner-facing behavior |

---

### Task 1: Shared speaker identity resolver

**Files:**
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerIdentity.swift`
- Modify: `apps/brain-menu/Sources/BrainMenu/Meetings/SpeakerEditor.swift` (`defaultDisplayName`)
- Test: `apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerIdentityTests.swift`

**Interfaces:**
- Consumes: `SpeakerEditor.youSpeakerID`, `SpeakerEditor.remoteSpeakerID`, `SpeakerAssignmentProvenance`
- Produces: `MeetingSpeakerIdentity.isClusteredID(_:)`, `clusteredID(index:)`, `defaultDisplayName(for:)`, `resolved(source:baseSpeakerID:assignment:speakers:)`

- [ ] **Step 1: Write the failing test**

Create `MeetingSpeakerIdentityTests.swift`:

```swift
import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerIdentityTests {
    @Test
    func clusteredIDsStartAtTwoAndIgnoreJunk() {
        #expect(MeetingSpeakerIdentity.clusteredID(index: 2) == "remote-2")
        #expect(MeetingSpeakerIdentity.isClusteredID("remote-2"))
        #expect(MeetingSpeakerIdentity.isClusteredID("remote-10"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("untrusted-diarization"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("speaker-deadbeef"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("you"))
    }

    @Test
    func labelsAndResolverPreferManualThenMicThenClusterThenRemote() throws {
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "you") == "You")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote") == "Remote")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote-2") == "Speaker 2")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote-3") == "Speaker 3")
        #expect(SpeakerEditor.defaultDisplayName(for: "remote-2") == "Speaker 2")

        let utteranceID = UUID()
        let manual = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-2",
            assignment: SpeakerAssignment(speakerID: "alex", provenance: .manual),
            speakers: ["alex": MeetingSpeaker(id: "alex", displayName: "Alex")]
        )
        #expect(manual.id == "alex")
        #expect(manual.label == "Alex")
        #expect(manual.provenance == .manual)

        let mic = MeetingSpeakerIdentity.resolved(
            source: .microphone,
            baseSpeakerID: "untrusted",
            assignment: nil,
            speakers: [:]
        )
        #expect(mic.id == "you")
        #expect(mic.label == "You")

        let clustered = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-3",
            assignment: nil,
            speakers: [:]
        )
        #expect(clustered.id == "remote-3")
        #expect(clustered.label == "Speaker 3")

        let junk = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "untrusted-diarization",
            assignment: nil,
            speakers: [:]
        )
        #expect(junk.id == "remote")
        #expect(junk.label == "Remote")
        _ = utteranceID
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerIdentityTests`

Expected: FAIL because `MeetingSpeakerIdentity` is not defined.

- [ ] **Step 3: Write minimal implementation**

`MeetingSpeakerIdentity.swift`:

```swift
import Foundation

enum MeetingSpeakerIdentity {
    static func clusteredID(index: Int) -> String { "remote-\(index)" }

    static func isClusteredID(_ id: String) -> Bool {
        guard id.hasPrefix("remote-") else { return false }
        let digits = id.dropFirst("remote-".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func defaultDisplayName(for speakerID: String) -> String {
        SpeakerEditor.defaultDisplayName(for: speakerID)
    }

    static func resolved(
        source: MeetingUtteranceSource,
        baseSpeakerID: String,
        assignment: SpeakerAssignment?,
        speakers: [String: MeetingSpeaker]
    ) -> (id: String, label: String, provenance: SpeakerAssignmentProvenance) {
        if let assignment, assignment.provenance == .manual {
            return (
                assignment.speakerID,
                speakers[assignment.speakerID]?.displayName
                    ?? defaultDisplayName(for: assignment.speakerID),
                assignment.provenance
            )
        }
        let speakerID: String
        if source == .microphone {
            speakerID = SpeakerEditor.youSpeakerID
        } else if isClusteredID(baseSpeakerID) {
            speakerID = baseSpeakerID
        } else {
            speakerID = SpeakerEditor.remoteSpeakerID
        }
        return (
            speakerID,
            speakers[speakerID]?.displayName ?? defaultDisplayName(for: speakerID),
            .sourceDefault
        )
    }
}
```

`SpeakerEditor.defaultDisplayName` is the single label table:

```swift
static func defaultDisplayName(for speakerID: String) -> String {
    switch speakerID {
    case youSpeakerID:
        "You"
    case remoteSpeakerID:
        "Remote"
    default:
        if MeetingSpeakerIdentity.isClusteredID(speakerID),
           let number = Int(speakerID.dropFirst("remote-".count)) {
            return "Speaker \(number)"
        }
        return "Speaker"
    }
}
```

Do **not** use transcriber `humanName` in this resolver.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerIdentityTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerIdentity.swift \
  apps/brain-menu/Sources/BrainMenu/Meetings/SpeakerEditor.swift \
  apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerIdentityTests.swift
git commit -m "Add a shared resolver for clustered remote speaker IDs."
```

---

### Task 2: Assembler honors `remote-N` only

**Files:**
- Modify: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptTurnAssembler.swift` (`resolvedSpeaker`)
- Test: `apps/brain-menu/Tests/BrainMenuTests/MeetingTranscriptTurnAssemblerTests.swift`

**Interfaces:**
- Consumes: `MeetingSpeakerIdentity.resolved(source:baseSpeakerID:assignment:speakers:)`
- Produces: assembled turns whose system utterances with `baseSpeakerID == remote-N` keep that ID; junk IDs still collapse to Remote

- [ ] **Step 1: Write the failing test**

Add to `MeetingTranscriptTurnAssemblerTests.swift` (keep `manualAssignmentWinsAndSystemAudioStaysOneRemoteSpeaker` — junk IDs must still become Remote):

```swift
@Test
func clusteredRemoteIDsSplitTurnsAndJunkStillCollapses() throws {
    let first = try utterance(.system, 0, 1_000, "hello", base: "remote-2")
    let same = try utterance(.system, 1_100, 2_000, "again", base: "remote-2")
    let other = try utterance(.system, 2_100, 3_000, "other", base: "remote-3")
    let junk = try utterance(.system, 3_100, 4_000, "junk", base: "untrusted-diarization")
    let mic = try utterance(.microphone, 4_100, 5_000, "me", base: "you")
    let turns = MeetingTranscriptTurnAssembler.assemble(
        utterances: [mic, junk, other, same, first]
    )
    #expect(turns.map(\.speakerID) == ["remote-2", "remote-3", "remote", "you"])
    #expect(turns.map(\.speakerLabel) == ["Speaker 2", "Speaker 3", "Remote", "You"])
    #expect(turns[0].text == "hello again")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter MeetingTranscriptTurnAssemblerTests`

Expected: FAIL — current assembler forces all system audio to `remote`, so `turns.map(\.speakerID)` will not be `["remote-2", "remote-3", "remote", "you"]`.

- [ ] **Step 3: Write minimal implementation**

Replace `resolvedSpeaker` with:

```swift
private static func resolvedSpeaker(
    for utterance: MeetingUtterance,
    assignment: SpeakerAssignment?,
    speakers: [String: MeetingSpeaker]
) -> (id: String, label: String, provenance: SpeakerAssignmentProvenance) {
    MeetingSpeakerIdentity.resolved(
        source: utterance.source,
        baseSpeakerID: utterance.baseSpeakerID,
        assignment: assignment,
        speakers: speakers
    )
}
```

Delete the comment that says system audio stays one remote participant / does not infer diarized speakers.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingTranscriptTurnAssemblerTests --filter MeetingViewsTests`

Expected: PASS. `liveAndCompletedTranscriptShareTurnAssembly` still expects Remote for junk `baseSpeakerID`s.

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptTurnAssembler.swift \
  apps/brain-menu/Tests/BrainMenuTests/MeetingTranscriptTurnAssemblerTests.swift
git commit -m "Honor clustered remote speaker IDs in transcript turn assembly."
```

---

### Task 3: Talk time uses the same resolver

**Files:**
- Modify: `apps/brain-menu/Sources/BrainMenu/Meetings/TalkTimeCalculator.swift` (`calculate`, remove source-only `defaultSpeakerID`)
- Test: `apps/brain-menu/Tests/BrainMenuTests/SpeakerEditorTests.swift` (existing talk-time tests plus one new)

**Interfaces:**
- Consumes: `MeetingSpeakerIdentity.resolved(...)`
- Produces: talk-time rows keyed by `remote-2` / `remote-3` when those IDs are on system utterances

- [ ] **Step 1: Write the failing test**

Add to `SpeakerEditorTests.swift`:

```swift
@Test
func talkTimeSplitsClusteredRemoteSpeakers() throws {
    let you = try utterance(
        id: "00000000-0000-0000-0000-000000000071",
        source: .microphone,
        start: 0,
        end: 1_000,
        text: "me"
    )
    let remoteTwo = try utterance(
        id: "00000000-0000-0000-0000-000000000072",
        source: .system,
        start: 0,
        end: 2_000,
        text: "a",
        base: "remote-2"
    )
    let remoteThree = try utterance(
        id: "00000000-0000-0000-0000-000000000073",
        source: .system,
        start: 2_000,
        end: 3_000,
        text: "b",
        base: "remote-3"
    )
    let chart = TalkTimeCalculator().calculate(utterances: [you, remoteTwo, remoteThree])
    #expect(Set(chart.data.map(\.speakerID)) == ["you", "remote-2", "remote-3"])
    #expect(chart.data.first { $0.speakerID == "remote-2" }?.displayName == "Speaker 2")
    #expect(chart.data.first { $0.speakerID == "remote-3" }?.displayName == "Speaker 3")
    #expect(chart.data.contains { $0.speakerID == "remote" } == false)
}
```

Extend the private `utterance(...)` helper in that file with `base: String = source == .microphone ? "you" : "remote"` if it does not already pass `baseSpeakerID` through. If the helper always sets `you`/`remote` from source, add a `base:` parameter and pass it to `MeetingUtterance(baseSpeakerID:)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter talkTimeSplitsClusteredRemoteSpeakers`

Expected: FAIL — calculator currently attributes all system audio to `remote`.

- [ ] **Step 3: Write minimal implementation**

In `TalkTimeCalculator.calculate(utterances:assignments:speakers:)` replace:

```swift
let speakerID = assignments[utterance.id]?.speakerID
    ?? defaultSpeakerID(for: utterance.source)
```

with:

```swift
let speakerID = MeetingSpeakerIdentity.resolved(
    source: utterance.source,
    baseSpeakerID: utterance.baseSpeakerID,
    assignment: assignments[utterance.id],
    speakers: speakers
).id
```

Delete `defaultSpeakerID(for:)`. Keep unioning intervals as they are. Existing `talkTimeUnionsSameSpeakerAndKeepsSimultaneousSpeakers` still uses default `you`/`remote` IDs and must keep passing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter SpeakerEditorTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/TalkTimeCalculator.swift \
  apps/brain-menu/Tests/BrainMenuTests/SpeakerEditorTests.swift
git commit -m "Attribute talk time with the clustered speaker resolver."
```

---

### Task 4: Deterministic embedding clusterer

**Files:**
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerClusterer.swift`
- Test: `apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerClustererTests.swift`

**Interfaces:**
- Consumes: labeled embeddings `(id: UUID, startMilliseconds: Int64, vector: [Float])`
- Produces: `[UUID: String]` mapping to `remote-N`, or `[:]` when fewer than 2 clusters
- Constant: `MeetingSpeakerClusterer.sameSpeakerCosineThreshold = Float(0.65)`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerClustererTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test
    func twoOrthogonalVoicesBecomeRemote2And3InFirstAppearanceOrder() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: c, startMilliseconds: 2_000, vector: [0, 1]),
            .init(id: a, startMilliseconds: 0, vector: [1, 0]),
            .init(id: b, startMilliseconds: 1_000, vector: [1, 0]),
        ])
        #expect(map[a] == "remote-2")
        #expect(map[b] == "remote-2")
        #expect(map[c] == "remote-3")
    }

    @Test
    func identicalVectorsStayOneClusterAndWriteNothing() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: a, startMilliseconds: 0, vector: [1, 1]),
            .init(id: b, startMilliseconds: 1_000, vector: [2, 2]),
        ])
        #expect(map.isEmpty)
    }

    @Test
    func oneEmbeddingWritesNothing() {
        let map = MeetingSpeakerClusterer().cluster([
            .init(id: a, startMilliseconds: 0, vector: [1, 0]),
        ])
        #expect(map.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerClustererTests`

Expected: FAIL because `MeetingSpeakerClusterer` is not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct MeetingSpeakerClusterer: Sendable {
    static let sameSpeakerCosineThreshold: Float = 0.65

    struct Point: Sendable {
        let id: UUID
        let startMilliseconds: Int64
        let vector: [Float]
    }

    func cluster(_ points: [Point]) -> [UUID: String] {
        let normalized = points.compactMap { point -> Point? in
            guard let vector = Self.l2Normalize(point.vector) else { return nil }
            return Point(id: point.id, startMilliseconds: point.startMilliseconds, vector: vector)
        }
        guard normalized.count >= 2 else { return [:] }

        var parent = Array(normalized.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func union(_ i: Int, _ j: Int) {
            let a = find(i), b = find(j)
            if a != b { parent[b] = a }
        }

        for i in normalized.indices {
            for j in normalized.indices where j > i {
                if Self.cosine(normalized[i].vector, normalized[j].vector)
                    >= Self.sameSpeakerCosineThreshold {
                    union(i, j)
                }
            }
        }

        var members: [Int: [Point]] = [:]
        for (index, point) in normalized.enumerated() {
            members[find(index), default: []].append(point)
        }
        guard members.count >= 2 else { return [:] }

        let ordered = members.values.sorted { lhs, rhs in
            let l = lhs.map(\.startMilliseconds).min() ?? 0
            let r = rhs.map(\.startMilliseconds).min() ?? 0
            if l != r { return l < r }
            return (lhs.map(\.id.uuidString).min() ?? "") < (rhs.map(\.id.uuidString).min() ?? "")
        }

        var map: [UUID: String] = [:]
        for (offset, group) in ordered.enumerated() {
            let id = MeetingSpeakerIdentity.clusteredID(index: offset + 2)
            for point in group { map[point.id] = id }
        }
        return map
    }

    private static func l2Normalize(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
```

This pairwise-threshold union is average-linkage-equivalent for the test vectors (identical vs orthogonal). Keep it; do not add a Python-style scipy dendrogram.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerClustererTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerClusterer.swift \
  apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerClustererTests.swift
git commit -m "Cluster speaker embeddings into remote-N IDs."
```

---

### Task 5: Diarizer slices, gates, embeds, clusters

**Files:**
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerEmbeddingClient.swift`
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSystemAudioSlicer.swift`
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerDiarizer.swift`
- Test: `apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerDiarizerTests.swift`

**Interfaces:**
- Consumes: `MeetingAudioTrack` (16 kHz mono f32le), `SpeechActivityGate`, `MeetingSpeakerClusterer`, embedder
- Produces: `MeetingSpeakerDiarizing.assign(utterances:systemTrack:) -> [UUID: String]`; mic IDs never appear; empty map on skip/failure

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerDiarizerTests {
    @Test
    func assignsRemoteClustersFromSystemEmbeddingsAndSkipsMic() throws {
        let mic = try MeetingUtterance(
            source: .microphone, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "me", baseSpeakerID: "you"
        )
        let first = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let second = try MeetingUtterance(
            source: .system, startMilliseconds: 1_000, endMilliseconds: 2_000,
            text: "b", baseSpeakerID: "remote"
        )
        let short = try MeetingUtterance(
            source: .system, startMilliseconds: 2_000, endMilliseconds: 2_200,
            text: "x", baseSpeakerID: "remote"
        )
        let embedder = StubSpeakerEmbeddingClient(vectors: [
            first.id: [1, 0],
            second.id: [0, 1],
        ])
        let track = try Self.writeTrack(seconds: 3, voiced: true)
        let map = MeetingSpeakerDiarizer(embedder: embedder).assign(
            utterances: [mic, first, second, short],
            systemTrack: track
        )
        #expect(map[mic.id] == nil)
        #expect(map[short.id] == nil)
        #expect(map[first.id] == "remote-2")
        #expect(map[second.id] == "remote-3")
    }

    @Test
    func missingTrackOrFailedEmbedReturnsEmpty() throws {
        let remote = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let empty = MeetingSpeakerDiarizer(embedder: StubSpeakerEmbeddingClient(vectors: [:]))
            .assign(utterances: [remote], systemTrack: nil)
        #expect(empty.isEmpty)

        let track = try Self.writeTrack(seconds: 1, voiced: true)
        let failed = MeetingSpeakerDiarizer(embedder: ThrowingSpeakerEmbeddingClient())
            .assign(utterances: [remote], systemTrack: track)
        #expect(failed.isEmpty)
    }

    private static func writeTrack(seconds: Int, voiced: Bool) throws -> MeetingAudioTrack {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).f32le.pcm")
        let frames = seconds * MeetingAudioWriter.sampleRate
        let sample: Float = voiced ? 0.25 : 0
        var data = Data(count: frames * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            for i in 0..<frames { buffer[i] = sample }
        }
        try data.write(to: url)
        return MeetingAudioTrack(
            source: .system,
            fileURL: url,
            sampleRate: MeetingAudioWriter.sampleRate,
            channelCount: 1,
            frameCount: Int64(frames)
        )
    }
}

struct StubSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    var vectors: [UUID: [Float]]
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
    func embed(utteranceID: UUID, pcm: [Float], sampleRate: Int) -> [Float]? {
        vectors[utteranceID]
    }
}

struct ThrowingSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
    func embed(utteranceID: UUID, pcm: [Float], sampleRate: Int) -> [Float]? {
        nil
    }
}
```

The production protocol is **only** `embed(pcm:sampleRate:)`. The stub should key off a side channel: have the diarizer call `embed(pcm:sampleRate:)` and make the stub return vectors by **call order** or by hashing pcm energy. Simpler and matching the spec:

```swift
protocol SpeakerEmbeddingClient: Sendable {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]?
}

struct SequenceSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    var vectors: [[Float]]
    private let lock = NSLock()
    private var index = 0
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        lock.withLock {
            guard index < vectors.count else { return nil }
            defer { index += 1 }
            return vectors[index]
        }
    }
}
```

Rewrite the first test to use `SequenceSpeakerEmbeddingClient(vectors: [[1, 0], [0, 1]])` — short span is skipped before embed, so only two calls. Do not add `embed(utteranceID:)`.

`ThrowingSpeakerEmbeddingClient` is unnecessary: a client that always returns `nil` is the fail-closed embedder.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerDiarizerTests`

Expected: FAIL because `MeetingSpeakerDiarizer` is not defined.

- [ ] **Step 3: Write minimal implementation**

`MeetingSpeakerEmbeddingClient.swift`:

```swift
protocol SpeakerEmbeddingClient: Sendable {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]?
}
```

`MeetingSystemAudioSlicer.swift`:

```swift
enum MeetingSystemAudioSlicer {
    static func samples(
        track: MeetingAudioTrack,
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) -> [Float]? {
        guard track.sampleRate == MeetingAudioWriter.sampleRate,
              track.channelCount == 1,
              endMilliseconds > startMilliseconds else { return nil }
        let start = Int(startMilliseconds) * track.sampleRate / 1_000
        let end = Int(endMilliseconds) * track.sampleRate / 1_000
        guard start >= 0, end > start else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: track.fileURL) else { return nil }
        defer { try? handle.close() }
        let byteStart = UInt64(start * MemoryLayout<Float>.size)
        let byteCount = (end - start) * MemoryLayout<Float>.size
        do {
            try handle.seek(toOffset: byteStart)
            guard let data = try handle.read(upToCount: byteCount),
                  data.count == byteCount else { return nil }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } catch {
            return nil
        }
    }
}
```

`MeetingSpeakerDiarizer.swift`:

```swift
protocol MeetingSpeakerDiarizing: Sendable {
    func assign(utterances: [MeetingUtterance], systemTrack: MeetingAudioTrack?) -> [UUID: String]
}

struct MeetingSpeakerDiarizer: MeetingSpeakerDiarizing {
    static let minimumSpanMilliseconds: Int64 = 500
    private let embedder: any SpeakerEmbeddingClient
    private let gate = SpeechActivityGate()
    private let clusterer = MeetingSpeakerClusterer()

    init(embedder: any SpeakerEmbeddingClient) {
        self.embedder = embedder
    }

    func assign(
        utterances: [MeetingUtterance],
        systemTrack: MeetingAudioTrack?
    ) -> [UUID: String] {
        guard let systemTrack else { return [:] }
        let candidates = utterances
            .filter { !$0.suppressed && $0.source == .system }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
            .filter { $0.endMilliseconds - $0.startMilliseconds >= Self.minimumSpanMilliseconds }
        var points: [MeetingSpeakerClusterer.Point] = []
        for utterance in candidates {
            guard let pcm = MeetingSystemAudioSlicer.samples(
                track: systemTrack,
                startMilliseconds: utterance.startMilliseconds,
                endMilliseconds: utterance.endMilliseconds
            ), gate.evaluate(pcm).isSpeechBearing,
               let vector = embedder.embed(pcm: pcm, sampleRate: systemTrack.sampleRate)
            else { continue }
            points.append(.init(
                id: utterance.id,
                startMilliseconds: utterance.startMilliseconds,
                vector: vector
            ))
        }
        return clusterer.cluster(points)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingSpeakerDiarizerTests --filter MeetingSpeakerClustererTests`

Expected: PASS. Quiet PCM (`voiced: false`) must not produce embeddings; if the 0.25 RMS fixture is used, `SpeechActivityGate` will accept it.

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerEmbeddingClient.swift \
  apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSystemAudioSlicer.swift \
  apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerDiarizer.swift \
  apps/brain-menu/Tests/BrainMenuTests/MeetingSpeakerDiarizerTests.swift
git commit -m "Diarize system-audio utterances with injected embeddings."
```

---

### Task 6: Coordinator writes clusters before the attempt is frozen

**Files:**
- Modify: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptionCoordinator.swift` (init + `executeCompletion` before `makeAttempt`)
- Modify: `apps/brain-menu/Tests/BrainMenuTests/MeetingTranscriptionCoordinatorTests.swift` (`coordinator(...)` helper + new tests)
- Test: same file, plus a processing test that assembled turns already contain `remote-N`

**Interfaces:**
- Consumes: `MeetingSpeakerDiarizing.assign(utterances:systemTrack:)`
- Produces: persisted meeting utterances **and** `MeetingTranscriptAttempt.utterances` with `baseSpeakerID` rewritten **before** `makeAttempt` / `persistFinalResult`

- [ ] **Step 1: Write the failing test**

Add a `FixedMapDiarizer`:

```swift
struct FixedMapDiarizer: MeetingSpeakerDiarizing {
    var map: [UUID: String]
    func assign(utterances: [MeetingUtterance], systemTrack: MeetingAudioTrack?) -> [UUID: String] {
        map
    }
}
```

Extend `MeetingTranscriptionCoordinatorFixture.coordinator` with `diarizer: (any MeetingSpeakerDiarizing)? = nil` and pass it through.

In a new test `completePersistsClusteredSpeakersOnUtterancesAndAttempt`:

1. `makeCapture()` as existing tests do (has a `.system` track).
2. Stage + complete with a `LiveTranscriptController` that already has two system finals and one mic final. If the live controller overwrites utterances during `stop(capture:)`, seed them the same way other coordinator tests seed transcript text (`CoordinatorSuccessClient`). After complete, load store utterances and the selected attempt from `MeetingTranscriptArtifactStore`.
3. Inject `FixedMapDiarizer` mapping the two system utterance IDs to `remote-2` / `remote-3`.

If `stop(capture:)` replaces utterance IDs, apply clusters **after** `transcript.stop` / `transcript.utterances` is read (that is the real hook). Assert:

```swift
#expect(stored.utterances.filter { $0.source == .system }.map(\.baseSpeakerID).contains("remote-2"))
#expect(attempt.utterances.filter { $0.source == .system }.map(\.baseSpeakerID).contains("remote-2"))
#expect(stored.utterances.contains { $0.source == .microphone && $0.baseSpeakerID == "you" })
#expect(completed.transcriptionState == .completed)
```

Second test `voiceNoteAndMissingDiarizerLeaveRemote`:

- `recordingKind: .voiceNote` → do not call diarizer (use a `RecordingDiarizer` with `called` flag).
- Meeting with diarizer that would return IDs but `systemTrack` missing: still `.completed`, system `baseSpeakerID` stays `remote`.

Look at how `CoordinatorSuccessClient` creates utterances in existing tests and reuse that client. Read `LiveTranscriptController.stop` — clusters must run on the **final** `transcript.utterances` array, then pass that array into `makeAttempt` and `persistFinalResult`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter completePersistsClusteredSpeakersOnUtterancesAndAttempt`

Expected: FAIL — coordinator does not rewrite `baseSpeakerID`.

- [ ] **Step 3: Write minimal implementation**

Add to `MeetingTranscriptionCoordinator`:

```swift
private let diarizer: any MeetingSpeakerDiarizing

init(..., diarizer: (any MeetingSpeakerDiarizing)? = nil) {
    ...
    self.diarizer = diarizer ?? MeetingSpeakerDiarizer(embedder: CoreMLSpeakerEmbeddingClient())
}
```

If Task 7 has not landed `CoreMLSpeakerEmbeddingClient` yet, default to a client whose `embed` always returns `nil` (fail closed). Name it `MissingSpeakerEmbeddingClient` in `MeetingSpeakerEmbeddingClient.swift`:

```swift
struct MissingSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
}
```

Use that as the default until Task 7.

In `executeCompletion`, after `let utterances = transcript.utterances` and before `makeAttempt`:

```swift
let clusteredUtterances = Self.applyingClusters(
    utterances,
    capture: capture,
    isVoiceNote: resolvedMeeting.isVoiceNote,
    diarizer: diarizer
)
```

```swift
private func applyingClusters(
    _ utterances: [MeetingUtterance],
    capture: MeetingAudioCaptureSummary,
    isVoiceNote: Bool,
    diarizer: any MeetingSpeakerDiarizing
) -> [MeetingUtterance] {
    guard !isVoiceNote else { return utterances }
    let track = capture.tracks.first { $0.source == .system }
    let map = diarizer.assign(utterances: utterances, systemTrack: track)
    guard !map.isEmpty else { return utterances }
    return utterances.map { utterance in
        guard utterance.source == .system,
              let clustered = map[utterance.id],
              MeetingSpeakerIdentity.isClusteredID(clustered) else {
            return utterance
        }
        var updated = utterance
        updated.baseSpeakerID = clustered
        return updated
    }
}
```

Pass `clusteredUtterances` into `makeAttempt` and `persistFinalResult`. Do not fail the meeting if `assign` is empty. Wrap `assign` in no extra throws; the protocol does not throw.

Use `clusteredUtterances` for title generation in `persistFinalResult` as well (it already receives `utterances`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingTranscriptionCoordinatorTests --filter MeetingTranscriptTurnAssemblerTests --filter MeetingSpeakerDiarizerTests`

Expected: PASS. Existing coordinator tests keep succeeding because default embedder returns nil → no ID rewrite.

Add a small processing assertion in `MeetingTranscriptProcessingServiceTests` or a focused test: given an attempt whose utterances already have `remote-2`/`remote-3`, `MeetingTranscriptTurnAssembler.assemble` (which processing calls) yields those labels. No prompt change.

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptionCoordinator.swift \
  apps/brain-menu/Sources/BrainMenu/Meetings/MeetingSpeakerEmbeddingClient.swift \
  apps/brain-menu/Tests/BrainMenuTests/MeetingTranscriptionCoordinatorTests.swift
git commit -m "Cluster remote speakers before freezing the final transcript attempt."
```

---

### Task 7: Fail-closed Core ML embedder and optional bundle copy

**Files:**
- Create: `apps/brain-menu/Sources/BrainMenu/Meetings/CoreMLSpeakerEmbeddingClient.swift`
- Create: `apps/brain-menu/fetch-speaker-encoder.sh`
- Modify: `apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptionCoordinator.swift` (default diarizer uses Core ML client)
- Modify: `apps/brain-menu/package.sh` (copy model into `.app` if present)
- Modify: `.github/workflows/ci.yml` only if you add `bash -n apps/brain-menu/fetch-speaker-encoder.sh` next to the other script syntax checks
- Test: `apps/brain-menu/Tests/BrainMenuTests/CoreMLSpeakerEmbeddingClientTests.swift`

**Interfaces:**
- Consumes: `SpeakerEncoder.mlmodelc` from `Bundle.main` (packaged app). Input name `audio` (`MLMultiArray` Float32, 16 kHz mono). Output name `embedding` (length ≥ 1).
- Produces: `embed(pcm:sampleRate:) -> [Float]?` — `nil` if the model is missing, input rank is wrong, or prediction throws

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import BrainMenu

struct CoreMLSpeakerEmbeddingClientTests {
    @Test
    func missingBundleModelReturnsNil() {
        let client = CoreMLSpeakerEmbeddingClient(bundle: Bundle(for: MeetingSpeakerIdentity.self))
        let pcm = [Float](repeating: 0.25, count: 16_000)
        #expect(client.embed(pcm: pcm, sampleRate: 16_000) == nil)
    }
}
```

`MeetingSpeakerIdentity` is an enum, so it cannot be used with `Bundle(for:)`. Pass `Bundle.main` and/or add `init(modelURL: URL?)`. Test `CoreMLSpeakerEmbeddingClient(modelURL: nil)` returns nil. That does not require a class.

```swift
#expect(CoreMLSpeakerEmbeddingClient(modelURL: nil).embed(pcm: [0.25], sampleRate: 16_000) == nil)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter CoreMLSpeakerEmbeddingClientTests`

Expected: FAIL because `CoreMLSpeakerEmbeddingClient` is not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import CoreML
import Foundation

struct CoreMLSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    var modelURL: URL?

    init(modelURL: URL? = Bundle.main.url(forResource: "SpeakerEncoder", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == MeetingAudioWriter.sampleRate, !pcm.isEmpty else { return nil }
        guard let modelURL,
              let model = try? MLModel(contentsOf: modelURL) else { return nil }
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: pcm.count)], dataType: .float32) else {
            return nil
        }
        for (index, sample) in pcm.enumerated() {
            array[index] = NSNumber(value: sample)
        }
        let input = try? MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)])
        guard let input,
              let out = try? model.prediction(from: input),
              let embedding = out.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }
        return (0..<embedding.count).map { embedding[$0].floatValue }
    }
}
```

Default coordinator embedder: `CoreMLSpeakerEmbeddingClient()`. Unit tests keep injecting stubs. `swift test` uses `Bundle.main` without the model → nil → diarizer no-op.

`fetch-speaker-encoder.sh` (modeled on `fetch-voxtype.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
destination="${1:-}"
if [ -z "$destination" ] || [ "${destination#/}" = "$destination" ]; then
  echo "usage: $0 /absolute/output/dir/SpeakerEncoder.mlmodelc" >&2
  exit 64
fi
source_model="${BRAIN_SPEAKER_ENCODER_SOURCE:-}"
if [ -z "$source_model" ]; then
  echo "speaker encoder skipped: set BRAIN_SPEAKER_ENCODER_SOURCE to a SpeakerEncoder.mlmodelc directory" >&2
  exit 0
fi
if [ ! -d "$source_model" ]; then
  echo "error: BRAIN_SPEAKER_ENCODER_SOURCE is not a directory: $source_model" >&2
  exit 66
fi
rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
cp -R "$source_model" "$destination"
```

If `BRAIN_SPEAKER_ENCODER_SHA256` is set, hash a `tar -C "$destination" -cf - . | shasum -a 256` and require a match; if unset, skip the hash (local drop-in).

In `package.sh`, after other Resources copies:

```sh
speaker_encoder="$app_dir/Resources/SpeakerEncoder.mlmodelc"
if [ -d "$speaker_encoder" ]; then
  cp -R "$speaker_encoder" "$bundle/Contents/Resources/SpeakerEncoder.mlmodelc"
fi
```

Find the existing destination variable for `Brain.icns` in `package.sh` and copy next to it — do not invent a new bundle layout.

Add `bash -n apps/brain-menu/fetch-speaker-encoder.sh` in `.github/workflows/ci.yml` beside `install.sh` / `package.sh` / `fetch-voxtype.sh`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter CoreMLSpeakerEmbeddingClientTests --filter MeetingTranscriptionCoordinatorTests`

Expected: PASS. `bash -n apps/brain-menu/fetch-speaker-encoder.sh` exits 0.

- [ ] **Step 5: Commit**

```bash
git add apps/brain-menu/Sources/BrainMenu/Meetings/CoreMLSpeakerEmbeddingClient.swift \
  apps/brain-menu/Sources/BrainMenu/Meetings/MeetingTranscriptionCoordinator.swift \
  apps/brain-menu/fetch-speaker-encoder.sh \
  apps/brain-menu/package.sh \
  .github/workflows/ci.yml \
  apps/brain-menu/Tests/BrainMenuTests/CoreMLSpeakerEmbeddingClientTests.swift
git commit -m "Load an optional on-device speaker encoder and fail closed without it."
```

---

### Task 8: Docs and live-caption regression

**Files:**
- Modify: `integrations/meetings.md` (review bullets after hangup)
- Modify: `apps/brain-menu/README.md` (turn grouping / speakers)
- Test: existing `MeetingViewsTests.liveAndCompletedTranscriptShareTurnAssembly` must still expect Remote for junk IDs; add a completed-detail assertion with `remote-2`

**Interfaces:**
- Consumes: Task 2 assembler behavior
- Produces: owner-facing copy that live captions stay You/Remote; after hangup, distinct remote voices become Speaker 2/3… and can be renamed/merged

- [ ] **Step 1: Write the failing test**

In `MeetingViewsTests.swift` add:

```swift
@Test
func completedTranscriptShowsClusteredRemoteSpeakers() throws {
    let first = try MeetingUtterance(
        source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
        text: "First remote", baseSpeakerID: "remote-2"
    )
    let second = try MeetingUtterance(
        source: .system, startMilliseconds: 1_100, endMilliseconds: 2_000,
        text: "Second remote", baseSpeakerID: "remote-3"
    )
    let id = UUID()
    let record = meeting(id: id, title: "Clustered", start: .now)
    let detail = MeetingDetailController(
        meetingID: id,
        store: MemoryMeetingViewStore(values: [id: StoredMeeting(meeting: record, utterances: [first, second])]),
        analysisStore: MemoryMeetingViewAnalysisStore(),
        uploadController: MeetingDetailUploadSpy(),
        audioController: MeetingDetailAudioSpy(meeting: record),
        audioChecker: FixedAudioChecker(value: false),
        clipboard: MeetingClipboardSpy()
    )
    detail.load()
    #expect(detail.viewModel.transcript.map(\.speakerName) == ["Speaker 2", "Speaker 3"])
}
```

Reuse the same `meeting(...)` / spy helpers as `liveAndCompletedTranscriptShareTurnAssembly`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/brain-menu --filter completedTranscriptShowsClusteredRemoteSpeakers`

Expected: FAIL only if Task 2 was skipped; if Task 2 landed, this may already PASS. If it passes, still do the doc edits.

- [ ] **Step 3: Update docs**

In `integrations/meetings.md` after the turn-grouping sentence, add: after hangup, distinct voices on system audio become Speaker 2, Speaker 3, …; live captions stay You vs Remote; rename/merge in review still works. Clustering is local and fail-closed.

In `apps/brain-menu/README.md` next to the eight-second turn sentence, add the same one-liner.

Do not mention Core ML, embeddings, or model filenames in owner docs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path apps/brain-menu --filter MeetingViewsTests --filter MeetingSpeakerIdentityTests --filter MeetingSpeakerDiarizerTests --filter MeetingTranscriptionCoordinatorTests`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add integrations/meetings.md apps/brain-menu/README.md \
  apps/brain-menu/Tests/BrainMenuTests/MeetingViewsTests.swift
git commit -m "Document clustered remote speakers on the final meeting transcript."
```

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| After hangup, before Processed | 6 |
| Mic stays You | 1, 2, 5, 6 |
| `remote-N` IDs, labels Speaker N, start at 2 | 1, 4 |
| 0–1 cluster → Remote | 4, 5 |
| Ignore Whisper junk IDs | 1, 2 |
| Manual wins | 1, 2 |
| Shared assembler + talk time resolver | 2, 3 |
| No transcriber `humanName` | 1 |
| Skip <500 ms / non-speech | 5 |
| One span = one cluster | 5 |
| Voice Notes / live captions skip | 6, 8 |
| Fail closed missing audio/model | 5, 6, 7 |
| Processed copies speakers | 6 (attempt frozen with IDs) |
| Privacy / on-device | 7 |
| Docs | 8 |
| Tests use fake embedder | 5, 6 |
| Optional Core ML in bundle | 7 |

## Placeholder scan

No TBD. Core ML artifact is optional: without `Resources/SpeakerEncoder.mlmodelc` or `BRAIN_SPEAKER_ENCODER_SOURCE`, production behaves as today (Remote). Clustering is fully tested via injected embeddings.
