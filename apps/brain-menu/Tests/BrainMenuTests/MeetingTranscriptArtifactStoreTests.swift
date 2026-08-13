import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingTranscriptArtifactStoreTests {
    @Test
    func appendsAttemptsSelectsSuccessfulAttemptAndPersistsDiagnostics() throws {
        let fixture = try ArtifactStoreFixture()
        let failed = try fixture.attempt(text: "partial", successful: false)
        let successful = try fixture.attempt(text: "final", successful: true)

        _ = try fixture.store.append(failed, meetingID: fixture.meetingID)
        _ = try fixture.store.append(
            successful,
            meetingID: fixture.meetingID
        )
        let artifact = try fixture.store.select(
            attemptID: successful.id,
            meetingID: fixture.meetingID
        )
        let relaunched = try MeetingTranscriptArtifactStore(rootURL: fixture.root)
            .load(meetingID: fixture.meetingID)

        #expect(artifact.attempts.map(\.id) == [failed.id, successful.id])
        #expect(artifact.selectedAttemptID == successful.id)
        #expect(relaunched == artifact)
        #expect(relaunched?.attempts.first?.failures.first?.message == "failure partial")
        #expect(relaunched?.attempts.first?.failureTotals.total == 1)
    }

    @Test
    func rejectsRemovalMutationAndDuplicateUUID() throws {
        let fixture = try ArtifactStoreFixture()
        let first = try fixture.attempt(text: "one", successful: false)
        let second = try fixture.attempt(text: "two", successful: true)
        _ = try fixture.store.append(first, meetingID: fixture.meetingID)
        let complete = try fixture.store.append(
            second,
            meetingID: fixture.meetingID,
            selecting: true
        )

        var removed = complete
        removed.attempts.removeFirst()
        #expect(throws: MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly) {
            try fixture.store.save(removed)
        }
        #expect(throws: MeetingTranscriptArtifactStoreError.duplicateAttempt(first.id)) {
            try fixture.store.append(first, meetingID: fixture.meetingID)
        }
    }

    @Test
    func failedAtomicReplacementPreservesPriorDocument() throws {
        let fixture = try ArtifactStoreFixture()
        let first = try fixture.attempt(text: "one", successful: false)
        _ = try fixture.store.append(first, meetingID: fixture.meetingID)
        let failing = MeetingTranscriptArtifactStore(
            rootURL: fixture.root,
            failureInjector: { event in
                if event == .beforeAtomicReplacement { throw InjectedArtifactFailure() }
            }
        )

        #expect(throws: MeetingTranscriptArtifactStoreError.atomicWriteFailed) {
            try failing.append(
                fixture.attempt(text: "two", successful: true),
                meetingID: fixture.meetingID,
                selecting: true
            )
        }
        #expect(try fixture.store.load(meetingID: fixture.meetingID)?.attempts == [first])
    }

    @Test
    func writesOwnerOnlyFileAndDirectories() throws {
        let fixture = try ArtifactStoreFixture()
        _ = try fixture.store.append(
            fixture.attempt(text: "secure", successful: true),
            meetingID: fixture.meetingID,
            selecting: true
        )
        let directory = fixture.root.appendingPathComponent(fixture.meetingID.uuidString)
        let file = directory.appendingPathComponent(MeetingTranscriptArtifactStore.filename)

        #expect(try fixture.permissions(fixture.root) == 0o700)
        #expect(try fixture.permissions(directory) == 0o700)
        #expect(try fixture.permissions(file) == 0o600)
    }

    @Test
    func rejectsLinksNonregularFilesAndOversizeEncoding() throws {
        let fixture = try ArtifactStoreFixture()
        let directory = fixture.root.appendingPathComponent(fixture.meetingID.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(MeetingTranscriptArtifactStore.filename),
            withDestinationURL: outside
        )

        #expect(throws: MeetingTranscriptArtifactStoreError.self) {
            try fixture.store.load(meetingID: fixture.meetingID)
        }

        let oversizedFixture = try ArtifactStoreFixture()
        let large = try oversizedFixture.attempt(
            text: String(repeating: "x", count: MeetingTranscriptArtifactStore.maximumEncodedSize),
            successful: true
        )
        #expect(throws: MeetingTranscriptArtifactStoreError.artifactTooLarge) {
            try oversizedFixture.store.append(
                large,
                meetingID: oversizedFixture.meetingID,
                selecting: true
            )
        }
    }
}

private struct InjectedArtifactFailure: Error {}

private struct ArtifactStoreFixture {
    let root: URL
    let meetingID = UUID()
    let store: MeetingTranscriptArtifactStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-artifact-store-tests-\(UUID().uuidString)")
        store = MeetingTranscriptArtifactStore(rootURL: root)
    }

    func attempt(text: String, successful: Bool) throws -> MeetingTranscriptAttempt {
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: text,
            baseSpeakerID: "you"
        )
        let selection = SpeechEngineSelection(engine: .whisper, modelID: "model")
        let record = MeetingRecord(
            id: meetingID,
            title: "Artifact",
            startedAt: Date(timeIntervalSince1970: 100),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model",
            transcriptionState: successful ? .completed : .failed
        )
        _ = selection
        return MeetingTranscriptAttempt(
            createdAt: Date(timeIntervalSince1970: successful ? 200 : 100),
            modelAttestation: MeetingTranscriptModelAttestation(meeting: record),
            retainedPreviews: successful ? [] : [utterance],
            utterances: [utterance],
            failures: successful ? [] : [MeetingTranscriptFailureDiagnostic(
                message: "failure \(text)"
            )],
            isSuccessful: successful
        )
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
