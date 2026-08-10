import AVFoundation
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct MeetingTranscriptionCoordinatorTests {
    @Test
    func stagePersistsProcessingAttemptWithEmptyTranscriptAndPreservesAudio() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)

        let processing = try fixture.coordinator(client: CoordinatorSuccessClient())
            .stage(meeting: fixture.meeting, capture: capture)
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(processing.lifecycleState == .completed)
        #expect(processing.transcriptionState == .processing)
        #expect(processing.transcriptionAttemptCount == 1)
        #expect(processing.transcriptionErrorMessage == nil)
        #expect(processing.analysisState == .notRequested)
        #expect(processing.uploadState == .notUploaded)
        #expect(stored.meeting == processing)
        #expect(stored.utterances.isEmpty)
        #expect(rawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func finalizationKeepsShortAndEmptyRecordings() async throws {
        let shortEmpty = try MeetingTranscriptionCoordinatorFixture(duration: 29.999)
        let shortEmptyCapture = try shortEmpty.makeCapture()
        let shortEmptyRawURLs = shortEmpty.rawURLs(for: shortEmptyCapture)
        let shortEmptyClient = CoordinatorEmptyClient()
        let shortEmptyCoordinator = shortEmpty.coordinator(client: shortEmptyClient)
        let shortEmptyProcessing = try shortEmptyCoordinator.stage(
            meeting: shortEmpty.meeting,
            capture: shortEmptyCapture
        )

        let shortEmptyCompleted = await shortEmptyCoordinator.complete(
            meeting: shortEmptyProcessing,
            capture: shortEmptyCapture,
            transcript: try shortEmpty.transcript(
                client: shortEmptyClient,
                capture: shortEmptyCapture
            )
        )

        #expect(FileManager.default.fileExists(atPath: shortEmpty.meetingDirectory.path))
        #expect(shortEmptyCompleted.transcriptionState == .failed)
        #expect(shortEmptyCompleted.retainedAudio == nil)
        #expect(shortEmptyRawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(try shortEmpty.store.load(shortEmpty.meeting.id).utterances.isEmpty)

        let shortSpoken = try MeetingTranscriptionCoordinatorFixture(duration: 5)
        let shortSpokenCapture = try shortSpoken.makeCapture()
        let shortSpokenClient = CoordinatorSuccessClient()
        let shortSpokenCoordinator = shortSpoken.coordinator(client: shortSpokenClient)
        let shortSpokenProcessing = try shortSpokenCoordinator.stage(
            meeting: shortSpoken.meeting,
            capture: shortSpokenCapture
        )

        let completed = await shortSpokenCoordinator.complete(
            meeting: shortSpokenProcessing,
            capture: shortSpokenCapture,
            transcript: try shortSpoken.transcript(
                client: shortSpokenClient,
                capture: shortSpokenCapture
            )
        )

        #expect(completed.transcriptionState == .completed)
        #expect(completed.retainedAudio != nil)
        #expect(!(try shortSpoken.store.load(shortSpoken.meeting.id)).utterances.isEmpty)

        let boundaryEmpty = try MeetingTranscriptionCoordinatorFixture(duration: 30)
        let boundaryCapture = try boundaryEmpty.makeCapture()
        let boundaryRawURLs = boundaryEmpty.rawURLs(for: boundaryCapture)
        let boundaryClient = CoordinatorEmptyClient()
        let boundaryCoordinator = boundaryEmpty.coordinator(client: boundaryClient)
        let boundaryProcessing = try boundaryCoordinator.stage(
            meeting: boundaryEmpty.meeting,
            capture: boundaryCapture
        )

        _ = await boundaryCoordinator.complete(
            meeting: boundaryProcessing,
            capture: boundaryCapture,
            transcript: try boundaryEmpty.transcript(
                client: boundaryClient,
                capture: boundaryCapture
            )
        )

        #expect(FileManager.default.fileExists(atPath: boundaryEmpty.meetingDirectory.path))
        #expect(try boundaryEmpty.store.load(boundaryEmpty.meeting.id).meeting.retainedAudio == nil)
        #expect(boundaryRawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(try boundaryEmpty.store.load(boundaryEmpty.meeting.id).utterances.isEmpty)
    }

    @Test
    func unsupportedFinalPersistsFailureAndKeepsRawAudioRetryable() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        let client = CoordinatorUnsupportedClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)
        let transcript = try fixture.transcript(client: client, capture: capture)

        let failed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: transcript
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(await client.callCount > 0)
        #expect(failed.lifecycleState == .completed)
        #expect(failed.transcriptionState == .failed)
        #expect(failed.transcriptionAttemptCount == 1)
        #expect(failed.transcriptionErrorMessage?.contains(
            "does not support the parakeet engine"
        ) == true)
        #expect(failed.analysisState == .notRequested)
        #expect(failed.uploadState == .notUploaded)
        #expect(stored.meeting == failed)
        #expect(stored.utterances.isEmpty)
        #expect(rawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func isolatedInvalidSpanCompletesWithWarningAndUploadsSuccessfulUtterances() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorPartialInvalidClient()
        var scheduledUploads: [UUID] = []
        let coordinator = fixture.coordinator(
            client: client,
            uploadScheduler: { scheduledUploads.append($0) }
        )
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)

        let completed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(completed.transcriptionState == .completed)
        #expect(completed.transcriptionErrorMessage?.contains("1 skipped audio span") == true)
        #expect(stored.utterances.count == 1)
        #expect(stored.utterances.first?.source == .system)
        #expect(scheduledUploads == [fixture.meeting.id])
        #expect(await client.microphoneCallCount == 1)
    }

    @Test
    func successfulRetryCompletesTranscriptAndArchivesRecording() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        let unsupported = CoordinatorUnsupportedClient()
        let failingCoordinator = fixture.coordinator(client: unsupported)
        let processing = try failingCoordinator.stage(
            meeting: fixture.meeting,
            capture: capture
        )
        let failed = await failingCoordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: unsupported, capture: capture)
        )
        #expect(failed.transcriptionState == .failed)
        #expect(rawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })

        let success = CoordinatorSuccessClient()
        let completed = try await fixture.coordinator(client: success)
            .retry(meetingID: fixture.meeting.id)
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(await success.callCount > 0)
        #expect(completed.transcriptionState == .completed)
        #expect(completed.transcriptionAttemptCount == 2)
        #expect(completed.transcriptionErrorMessage == nil)
        #expect(completed.retainedAudio != nil)
        #expect(stored.meeting == completed)
        #expect(!stored.utterances.isEmpty)
        #expect(stored.utterances.allSatisfy { !$0.text.contains("unavailable") })
        #expect(rawURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(FileManager.default.fileExists(
            atPath: fixture.meetingDirectory
                .appendingPathComponent(AudioRetentionController.retainedFilename).path
        ))
    }

    @Test
    func separateCoordinatorsShareOneInFlightRetryForTheSameMeeting() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let unsupported = CoordinatorUnsupportedClient()
        let initial = fixture.coordinator(client: unsupported)
        let processing = try initial.stage(meeting: fixture.meeting, capture: capture)
        _ = await initial.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: unsupported, capture: capture)
        )

        let client = CoordinatorBlockingSuccessClient()
        let firstCoordinator = fixture.coordinator(client: client)
        let secondCoordinator = fixture.coordinator(client: client)
        let first = Task {
            try await firstCoordinator.retry(meetingID: fixture.meeting.id)
        }
        await client.waitUntilCallCount(atLeast: 1)
        let second = Task {
            try await secondCoordinator.retry(meetingID: fixture.meeting.id)
        }
        for _ in 0..<20 { await Task.yield() }

        let inFlight = try fixture.store.load(fixture.meeting.id).meeting
        await client.release()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(inFlight.transcriptionAttemptCount == 2)
        #expect(await client.callCount == 2)
        #expect(firstResult == secondResult)
        #expect(firstResult.transcriptionState == .completed)
    }

    @Test
    func explicitAudioDeletionCancelsRetryAndPreservesStableTranscript() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let originalTranscript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Keep this durable transcript.",
            baseSpeakerID: "you"
        )]
        var completed = fixture.meeting
        completed.transcriptionAttemptCount = 1
        completed.transcriptionState = .completed
        let archived = try fixture.retention.finalize(
            meeting: completed,
            utterances: originalTranscript,
            audio: fixture.makeCapture()
        )
        var failed = archived
        failed.transcriptionState = .failed
        failed.transcriptionErrorMessage = "Retry requested."
        try fixture.store.save(failed, utterances: originalTranscript)
        let client = CoordinatorCancellableClient()
        let coordinator = fixture.coordinator(client: client)
        let retry = Task {
            try await coordinator.retry(meetingID: fixture.meeting.id)
        }
        await client.waitUntilCallCount(atLeast: 1)

        let inFlight = try fixture.store.load(fixture.meeting.id)
        #expect(inFlight.meeting.transcriptionState == .processing)
        #expect(inFlight.utterances == originalTranscript)

        await coordinator.cancelAndWait(meetingID: fixture.meeting.id)
        _ = try await retry.value
        let deleted = try fixture.retention.deleteRecording(
            for: fixture.meeting.id,
            confirmed: true
        )
        let stored = try fixture.store.load(fixture.meeting.id)
        let launchReconciled = coordinator.reconcileInterruptedJobs(at: failed.startedAt)

        #expect(deleted.transcriptionState == .completed)
        #expect(deleted.transcriptionErrorMessage == nil)
        #expect(deleted.retainedAudio == nil)
        #expect(stored.meeting == deleted)
        #expect(stored.utterances == originalTranscript)
        #expect(launchReconciled.isEmpty)
    }

    @Test
    func staleCompletionCannotOverwriteANewerSuccessfulGeneration() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorBlockingSuccessClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)
        let completion = Task {
            await coordinator.complete(
                meeting: processing,
                capture: capture,
                transcript: try fixture.transcript(client: client, capture: capture)
            )
        }
        await client.waitUntilCallCount(atLeast: 1)

        var newer = processing
        newer.transcriptionAttemptCount += 1
        newer.transcriptionState = .completed
        newer.title = "Newer successful transcript"
        let newerUtterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "This newer generation must win.",
            baseSpeakerID: "you"
        )
        try fixture.store.save(newer, utterances: [newerUtterance])

        await client.release()
        _ = try await completion.value
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(stored.meeting == newer)
        #expect(stored.utterances == [newerUtterance])
    }

    @Test
    func completionAfterConfirmedStoreDeletionCannotRecreateMeeting() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorBlockingSuccessClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)
        let completion = Task {
            await coordinator.complete(
                meeting: processing,
                capture: capture,
                transcript: try fixture.transcript(client: client, capture: capture)
            )
        }
        await client.waitUntilCallCount(atLeast: 1)

        try fixture.store.delete(fixture.meeting.id, confirmed: true)
        await client.release()
        _ = try await completion.value

        #expect(!FileManager.default.fileExists(atPath: fixture.meetingDirectory.path))
        #expect(throws: MeetingStoreError.meetingNotFound(fixture.meeting.id)) {
            try fixture.store.load(fixture.meeting.id)
        }
    }

    @Test
    func editMadeWhileProcessingWinsOverStaleAutomaticTitle() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorBlockingSuccessClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)
        let completion = Task {
            await coordinator.complete(
                meeting: processing,
                capture: capture,
                transcript: try fixture.transcript(client: client, capture: capture)
            )
        }
        await client.waitUntilCallCount(atLeast: 1)

        var edited = try fixture.store.load(fixture.meeting.id).meeting
        edited.title = "My hand-edited meeting title"
        edited.titleSource = .manual
        try fixture.store.save(edited, utterances: [])

        await client.release()
        _ = try await completion.value
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(stored.meeting.title == "My hand-edited meeting title")
        #expect(stored.meeting.titleSource == .manual)
        #expect(stored.meeting.transcriptionState == .completed)
        #expect(!stored.utterances.isEmpty)
    }

    @Test
    func legacyRetainedCAFCanRetryAndFailedAttemptPreservesOriginalRecording() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let placeholder = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "[Transcript unavailable for this audio span.]",
            baseSpeakerID: "you"
        )
        let current = try fixture.retention.finalize(
            meeting: fixture.meeting,
            utterances: [placeholder],
            audio: capture
        )
        let retained = try fixture.replaceWithLegacyCAF(current)
        let retainedURL = fixture.meetingDirectory.appendingPathComponent("recording.caf")
        let originalCAF = try Data(contentsOf: retainedURL)
        try fixture.removeTranscriptionFields()

        let migrated = try fixture.store.load(fixture.meeting.id)
        #expect(migrated.meeting.transcriptionState == .failed)
        #expect(migrated.utterances.isEmpty)
        #expect(migrated.meeting.retainedAudio == retained.retainedAudio)

        let unsupported = CoordinatorUnsupportedClient()
        let failed = try await fixture.coordinator(client: unsupported)
            .retry(meetingID: fixture.meeting.id)
        #expect(failed.transcriptionState == .failed)
        #expect(try Data(contentsOf: retainedURL) == originalCAF)
        let recovered = try fixture.loadCaptureManifest()
        #expect(recovered.tracks.map(\.source) == [.microphone, .system])
        #expect(recovered.chunks.count == 2)
        #expect(recovered.chunks.allSatisfy {
            $0.timestampMilliseconds == 0 && $0.frameOffset == 0
        })

        let completed = try await fixture.coordinator(client: CoordinatorSuccessClient())
            .retry(meetingID: fixture.meeting.id)
        let stored = try fixture.store.load(fixture.meeting.id)
        #expect(completed.transcriptionState == .completed)
        #expect(completed.transcriptionAttemptCount == 2)
        #expect(stored.meeting == completed)
        #expect(!stored.utterances.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.meetingDirectory
                .appendingPathComponent(AudioRetentionController.retainedFilename).path
        ))
    }

    @Test
    func archiveFailureKeepsTranscriptAndSourceAudioRetryable() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        let retention = AudioRetentionController(
            store: fixture.store,
            fileSystem: CoordinatorRecordingWriteFailureFileSystem()
        )
        var scheduledUploads: [UUID] = []
        let client = CoordinatorSuccessClient()
        let coordinator = fixture.coordinator(
            client: client,
            retention: retention,
            uploadScheduler: { scheduledUploads.append($0) }
        )
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)

        let failed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(failed.transcriptionState == .failed)
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(stored.meeting.retainedAudio == nil)
        #expect(!stored.utterances.isEmpty)
        #expect(rawURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(scheduledUploads.isEmpty)

        let completed = try await fixture.coordinator(client: CoordinatorSuccessClient())
            .retry(meetingID: fixture.meeting.id)
        #expect(completed.transcriptionState == .completed)
        #expect(completed.retainedAudio != nil)
    }

    @Test
    func cleanupFailureAfterPersistenceStillCompletesAndSchedulesUpload() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let microphoneURL = try #require(
            capture.tracks.first(where: { $0.source == .microphone })?.fileURL
        )
        let systemURL = try #require(
            capture.tracks.first(where: { $0.source == .system })?.fileURL
        )
        let retention = AudioRetentionController(
            store: fixture.store,
            fileSystem: CoordinatorCleanupFailureFileSystem(
                failingFilename: microphoneURL.lastPathComponent
            )
        )
        var scheduledUploads: [UUID] = []
        let client = CoordinatorSuccessClient()
        let coordinator = fixture.coordinator(
            client: client,
            retention: retention,
            uploadScheduler: { scheduledUploads.append($0) }
        )
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)

        let completed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(completed.transcriptionState == .completed)
        #expect(completed.transcriptionErrorMessage == nil)
        #expect(stored.meeting == completed)
        #expect(!stored.utterances.isEmpty)
        #expect(scheduledUploads == [fixture.meeting.id])
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.meetingDirectory
                .appendingPathComponent(MeetingAudioWriter.manifestFilename).path
        ))
    }

    @Test
    func launchRecoverySchedulesUploadAfterCompletedTranscriptCrashWindow() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        var candidate = fixture.meeting
        candidate.transcriptionState = .completed
        candidate.transcriptionAttemptCount = 1
        candidate.uploadState = .notUploaded
        let completed = try fixture.retention.finalize(
            meeting: candidate,
            utterances: [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 500,
            text: "The transcript was already persisted.",
            baseSpeakerID: "you"
            )],
            audio: capture
        )

        var scheduledUploads: [UUID] = []
        let client = CoordinatorSuccessClient()
        let resumed = await fixture.coordinator(
            client: client,
            uploadScheduler: { scheduledUploads.append($0) }
        ).resumeInterruptedJobs()

        #expect(resumed.isEmpty)
        #expect(scheduledUploads == [completed.id])
        #expect(await client.callCount == 0)
        #expect(try fixture.store.load(completed.id).meeting == completed)
    }

    @Test
    func launchReconciliationMakesProcessingRetryableWithoutStartingSpeechWork() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorSuccessClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)
        let stoppedAt = processing.startedAt.addingTimeInterval(90)

        let reconciled = coordinator.reconcileInterruptedJobs(at: stoppedAt)
        let stored = try fixture.store.load(processing.id)

        #expect(reconciled.map(\.id) == [processing.id])
        #expect(stored.meeting.lifecycleState == .completed)
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(stored.meeting.transcriptionErrorMessage?.contains("Retry") == true)
        #expect(stored.meeting.endedAt == processing.endedAt)
        #expect(await client.callCount == 0)
    }

    @Test
    func launchReconciliationMakesIncompleteArchiveRetryable() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        var incomplete = fixture.meeting
        incomplete.transcriptionState = .completed
        incomplete.transcriptionAttemptCount = 1
        incomplete.retainedAudio = nil
        let transcript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "The transcript committed before archival.",
            baseSpeakerID: "you"
        )]
        try fixture.store.save(incomplete, utterances: transcript)

        let reconciled = fixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: incomplete.endedAt ?? incomplete.startedAt)
        let stored = try fixture.store.load(incomplete.id)

        #expect(reconciled.map(\.id) == [incomplete.id])
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(stored.meeting.transcriptionErrorMessage?.contains("archived") == true)
        #expect(stored.utterances == transcript)
        #expect(rawURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test
    func launchReconciliationLeavesDeletedAndLegacyNoAudioItemsCompleted() throws {
        let deletedFixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try deletedFixture.makeCapture()
        var completed = deletedFixture.meeting
        completed.transcriptionState = .completed
        completed.transcriptionAttemptCount = 1
        let archived = try deletedFixture.retention.finalize(
            meeting: completed,
            utterances: [],
            audio: capture
        )
        let deleted = try deletedFixture.retention.deleteRecording(
            for: archived.id,
            confirmed: true
        )

        let deletedReconciled = deletedFixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: deleted.startedAt)
        let deletedStored = try deletedFixture.store.load(deleted.id).meeting

        #expect(deletedReconciled.isEmpty)
        #expect(deletedStored == deleted)
        #expect(deletedStored.transcriptionState == .completed)
        #expect(deletedStored.retainedAudio == nil)

        let legacyFixture = try MeetingTranscriptionCoordinatorFixture()
        var legacy = legacyFixture.meeting
        legacy.transcriptionState = .completed
        legacy.transcriptionAttemptCount = 1
        legacy.retainedAudio = nil
        try legacyFixture.store.save(legacy, utterances: [])

        let legacyReconciled = legacyFixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: legacy.startedAt)
        let legacyStored = try legacyFixture.store.load(legacy.id).meeting

        #expect(legacyReconciled.isEmpty)
        #expect(legacyStored == legacy)
        #expect(legacyStored.transcriptionState == .completed)
        #expect(legacyStored.retainedAudio == nil)
    }

    @Test
    func retryReconstructsManifestlessRawTracks() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        _ = try fixture.makeCapture()
        var failed = fixture.meeting
        failed.transcriptionState = .failed
        failed.transcriptionErrorMessage = "Interrupted before the manifest was committed."
        try fixture.store.save(failed, utterances: [])
        try FileManager.default.removeItem(at: fixture.meetingDirectory.appendingPathComponent(
            MeetingAudioWriter.manifestFilename
        ))

        let completed = try await fixture.coordinator(client: CoordinatorSuccessClient())
            .retry(meetingID: failed.id)

        #expect(completed.transcriptionState == .completed)
        #expect(!(try fixture.store.load(failed.id)).utterances.isEmpty)
    }

    @Test
    func launchReconciliationImportsSafeOrphanedRawRecording() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let system = try #require(capture.tracks.first { $0.source == .system })
        try FileManager.default.removeItem(at: fixture.meetingDirectory.appendingPathComponent(
            MeetingAudioWriter.manifestFilename
        ))
        try FileManager.default.removeItem(at: system.fileURL)

        let recovered = fixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: fixture.meeting.startedAt)
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(recovered.map(\.id) == [fixture.meeting.id])
        #expect(stored.meeting.title == "Recovered recording")
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(FileManager.default.fileExists(atPath: system.fileURL.path))
    }
}

private final class MeetingTranscriptionCoordinatorFixture {
    let rootURL: URL
    let store: MeetingStore
    let retention: AudioRetentionController
    let meeting: MeetingRecord

    var meetingDirectory: URL {
        store.directoryURL(for: meeting.id)
    }

    init(duration: TimeInterval = 60) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrainMeetingTranscriptionCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        store = MeetingStore(rootURL: rootURL)
        retention = AudioRetentionController(store: store)
        meeting = MeetingRecord(
            title: "Meeting",
            detectedApplication: "Test Call",
            startedAt: Date(timeIntervalSince1970: 1_784_200_000),
            endedAt: Date(timeIntervalSince1970: 1_784_200_000 + duration),
            lifecycleState: .completed,
            speechEngine: SpeechEngineID.parakeet.rawValue,
            speechModel: "parakeet-tdt-0.6b-v3",
            analysisState: .completed,
            uploadState: .delivered
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func coordinator(
        client: any LiveTranscriptionClient,
        retention selectedRetention: AudioRetentionController? = nil,
        uploadScheduler: @escaping MeetingTranscriptionCoordinator.UploadScheduler = { _ in }
    ) -> MeetingTranscriptionCoordinator {
        MeetingTranscriptionCoordinator(
            store: store,
            retention: selectedRetention ?? retention,
            uploadScheduler: uploadScheduler,
            clientFactory: { client }
        )
    }

    @MainActor
    func transcript(
        client: any LiveTranscriptionClient,
        capture: MeetingAudioCaptureSummary
    ) throws -> LiveTranscriptController {
        LiveTranscriptController(service: try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: capture.originHostTimestamp,
            wavDirectory: meetingDirectory.appendingPathComponent(
                ".transcription",
                isDirectory: true
            )
        ))
    }

    func makeCapture() throws -> MeetingAudioCaptureSummary {
        let writer = try MeetingAudioWriter(
            meetingDirectory: meetingDirectory,
            origin: meeting.startedAt
        )
        let voicedFrames = [Float](repeating: 0.25, count: 3_200)
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 10,
            hostTimestamp: 100,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: voicedFrames
        ))
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .system,
            sourceTimestamp: 20,
            hostTimestamp: 100.5,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: voicedFrames
        ))
        return try writer.finalize()
    }

    func rawURLs(for capture: MeetingAudioCaptureSummary) -> [URL] {
        capture.tracks.map(\.fileURL) + [
            meetingDirectory.appendingPathComponent(MeetingAudioWriter.manifestFilename),
        ]
    }

    func removeTranscriptionFields() throws {
        let meetingURL = meetingDirectory.appendingPathComponent(MeetingStore.meetingFilename)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL)) as? [String: Any]
        )
        object.removeValue(forKey: "transcriptionState")
        object.removeValue(forKey: "transcriptionAttemptCount")
        object.removeValue(forKey: "transcriptionErrorMessage")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: meetingURL)
    }

    func loadCaptureManifest() throws -> MeetingAudioCaptureSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            MeetingAudioCaptureSummary.self,
            from: Data(contentsOf: meetingDirectory.appendingPathComponent(
                MeetingAudioWriter.manifestFilename
            ))
        )
    }

    func replaceWithLegacyCAF(_ meeting: MeetingRecord) throws -> MeetingRecord {
        let currentURL = meetingDirectory.appendingPathComponent(
            AudioRetentionController.retainedFilename
        )
        let legacyURL = meetingDirectory.appendingPathComponent("recording.caf")
        let input = try AVAudioFile(
            forReading: currentURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channels: AVAudioChannelCount(AudioRetentionController.channelCount),
            interleaved: false
        ) else {
            throw CoordinatorFixtureError.legacyConversionFailed
        }
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: legacyURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        while input.framePosition < input.length {
            let count = AVAudioFrameCount(min(Int64(8_192), input.length - input.framePosition))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: count
            ) else {
                throw CoordinatorFixtureError.legacyConversionFailed
            }
            try input.read(into: buffer, frameCount: count)
            try output?.write(from: buffer)
        }
        output = nil
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: legacyURL.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
        let size = try #require((attributes[.size] as? NSNumber)?.int64Value)
        var legacy = meeting
        legacy.retainedAudio = RetainedAudioMetadata(
            filename: "recording.caf",
            format: "CAF/Linear PCM",
            sizeBytes: size,
            durationMilliseconds: meeting.retainedAudio?.durationMilliseconds ?? 0,
            channelCount: AudioRetentionController.channelCount
        )
        let utterances = try store.load(meeting.id).utterances
        try store.save(legacy, utterances: utterances)
        try FileManager.default.removeItem(at: currentURL)
        return legacy
    }
}

private actor CoordinatorUnsupportedClient: LiveTranscriptionClient {
    private(set) var callCount = 0

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        callCount += 1
        throw VoxTypeUnsupportedEngineError(engine: engine)
    }
}

private actor CoordinatorSuccessClient: LiveTranscriptionClient {
    private(set) var callCount = 0

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        callCount += 1
        return wavURL.lastPathComponent.contains("microphone")
            ? "The microphone transcript succeeded."
            : "The computer transcript succeeded."
    }
}

private actor CoordinatorPartialInvalidClient: LiveTranscriptionClient {
    private(set) var microphoneCallCount = 0

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        if wavURL.lastPathComponent.contains("microphone") {
            microphoneCallCount += 1
            throw VoxTypeClientError.invalidTranscript
        }
        return "The computer transcript succeeded."
    }
}

private actor CoordinatorEmptyClient: LiveTranscriptionClient {
    func transcribe(wavURL: URL, engine: String) async throws -> String {
        " \n "
    }
}

private actor CoordinatorBlockingSuccessClient: LiveTranscriptionClient {
    private(set) var callCount = 0
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var countContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        callCount += 1
        let ready = countContinuations.filter { callCount >= $0.0 }
        countContinuations.removeAll { callCount >= $0.0 }
        for value in ready { value.1.resume() }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return wavURL.lastPathComponent.contains("microphone")
            ? "The blocked microphone transcript succeeded."
            : "The blocked computer transcript succeeded."
    }

    func waitUntilCallCount(atLeast expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            countContinuations.append((expected, continuation))
        }
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor CoordinatorCancellableClient: LiveTranscriptionClient {
    private(set) var callCount = 0
    private var countContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        callCount += 1
        let ready = countContinuations.filter { callCount >= $0.0 }
        countContinuations.removeAll { callCount >= $0.0 }
        for value in ready { value.1.resume() }
        try await Task.sleep(for: .seconds(30))
        return "This retry should be cancelled."
    }

    func waitUntilCallCount(atLeast expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            countContinuations.append((expected, continuation))
        }
    }
}

private final class CoordinatorCleanupFailureFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let failingFilename: String
    private let base = LocalAudioRetentionFileSystem()

    init(failingFilename: String) {
        self.failingFilename = failingFilename
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingFilename {
            throw CoordinatorFixtureError.injectedCleanupFailure
        }
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private final class CoordinatorRecordingWriteFailureFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let base = LocalAudioRetentionFileSystem()

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        if url.pathExtension == "m4a" {
            throw CoordinatorFixtureError.injectedCAFWriteFailure
        }
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private enum CoordinatorFixtureError: Error {
    case injectedCleanupFailure
    case injectedCAFWriteFailure
    case legacyConversionFailed
}
