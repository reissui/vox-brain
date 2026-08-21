import AVFoundation
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct MeetingTranscriptionCoordinatorTests {
    @Test
    func severelySparseMicrophoneCaptureSkipsFinalSpeechAndRemainsRetryable() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture(duration: 10)
        let writer = try MeetingAudioWriter(
            meetingDirectory: fixture.meetingDirectory,
            origin: fixture.meeting.startedAt
        )
        let frames = [Float](repeating: 0.25, count: 320) // 20 ms at 16 kHz
        for second in 0..<10 {
            for callback in 0..<10 {
                let timestamp = 100 + Double(second) + Double(callback) * 0.02
                _ = try writer.append(MeetingAudioSampleBuffer(
                    source: .microphone,
                    sourceTimestamp: timestamp,
                    hostTimestamp: timestamp,
                    sampleRate: 16_000,
                    channelCount: 1,
                    interleavedSamples: frames
                ))
            }
        }
        let capture = try writer.finalize()
        let microphoneDiagnostics = try #require(
            capture.diagnostics?.sources.first { $0.source == .microphone }
        )
        #expect(microphoneDiagnostics.detectedDropoutCount == 9)
        #expect(microphoneDiagnostics.coverageRatio < 0.25)

        let partial = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 700,
            text: "Keep this trustworthy partial transcript.",
            baseSpeakerID: "you"
        )]
        let client = CoordinatorSuccessClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(
            meeting: fixture.meeting,
            capture: capture,
            utterances: partial
        )
        let failed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(await client.callCount == 0)
        #expect(failed.transcriptionState == .failed)
        #expect(failed.transcriptionErrorMessage?.contains("severely incomplete") == true)
        #expect(stored.utterances == partial)
        #expect(failed.retainedAudio == nil)
        #expect(fixture.rawURLs(for: capture).allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func continuousQuietCallbacksPassCaptureCoverageGate() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture(duration: 10)
        let writer = try MeetingAudioWriter(
            meetingDirectory: fixture.meetingDirectory,
            origin: fixture.meeting.startedAt
        )
        for callback in 0..<500 {
            var frames = [Float](repeating: 0, count: 320)
            if callback == 0 { frames[0] = 0.01 }
            let timestamp = 100 + Double(callback) * 0.02
            _ = try writer.append(MeetingAudioSampleBuffer(
                source: .microphone,
                sourceTimestamp: timestamp,
                hostTimestamp: timestamp,
                sampleRate: 16_000,
                channelCount: 1,
                interleavedSamples: frames
            ))
        }
        let capture = try writer.finalize()
        let diagnostics = try #require(
            capture.diagnostics?.sources.first { $0.source == .microphone }
        )

        #expect(diagnostics.callbackCount == 500)
        #expect(diagnostics.coverageRatio > 0.99)
        #expect(diagnostics.detectedDropoutCount == 0)
        #expect(MeetingAudioCaptureQuality.issue(in: capture) == nil)
    }

    @Test
    func terminalMicrophoneInterruptionRejectsEvenOtherwiseCompleteCoverage() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture(duration: 1)
        let writer = try MeetingAudioWriter(
            meetingDirectory: fixture.meetingDirectory,
            origin: fixture.meeting.startedAt
        )
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 100,
            hostTimestamp: 100,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: [Float](repeating: 0.2, count: 16_000)
        ))
        _ = try writer.recordFailure(
            source: .microphone,
            reason: .interrupted,
            hostTimestamp: 101,
            message: "Callback delivery failed after one rebuild."
        )
        let capture = try writer.finalize()

        #expect(capture.diagnostics?.sources.first?.coverageRatio == 1)
        #expect(MeetingAudioCaptureQuality.issue(in: capture)?.message.contains(
            "bounded recovery attempt"
        ) == true)
    }

    @Test
    func stagePersistsProcessingAttemptWithPartialTranscriptAndPreservesAudio() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        let partialTranscript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 800,
            text: "Keep this live preview.",
            baseSpeakerID: "you"
        )]

        let processing = try fixture.coordinator(client: CoordinatorSuccessClient())
            .stage(
                meeting: fixture.meeting,
                capture: capture,
                utterances: partialTranscript
            )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(processing.lifecycleState == .completed)
        #expect(processing.transcriptionState == .processing)
        #expect(processing.transcriptionAttemptCount == 1)
        #expect(processing.transcriptionErrorMessage == nil)
        #expect(processing.analysisState == .notRequested)
        #expect(processing.uploadState == .notUploaded)
        #expect(stored.meeting == processing)
        #expect(stored.utterances == partialTranscript)
        #expect(rawURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test
    func cancellationPreservesStagedPartialTranscript() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let partialTranscript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 800,
            text: "Keep this preview after cancellation.",
            baseSpeakerID: "you"
        )]
        let client = CoordinatorCancellableClient()
        let coordinator = fixture.coordinator(client: client)
        let processing = try coordinator.stage(
            meeting: fixture.meeting,
            capture: capture,
            utterances: partialTranscript
        )
        let completion = Task {
            await coordinator.complete(
                meeting: processing,
                capture: capture,
                transcript: try fixture.transcript(client: client, capture: capture)
            )
        }
        await client.waitUntilCallCount(atLeast: 1)

        try await coordinator.cancelAndWaitForDeletion(meetingID: processing.id) {}
        _ = try await completion.value

        #expect(try fixture.store.load(processing.id).utterances == partialTranscript)
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

        let shortEmptyStored = try shortEmpty.store.load(shortEmpty.meeting.id)
        let shortSpokenStored = try shortSpoken.store.load(shortSpoken.meeting.id)
        let boundaryStored = try boundaryEmpty.store.load(boundaryEmpty.meeting.id)
        try writeEvidence([
            "scenario": "Short and empty recordings are retained instead of auto-deleted",
            "under30SecondsEmpty": [
                "durationMilliseconds": 29_999,
                "meetingDirectoryExists": FileManager.default.fileExists(
                    atPath: shortEmpty.meetingDirectory.path
                ),
                "terminalTranscriptionState": shortEmptyStored.meeting.transcriptionState.rawValue,
                "sourceAudioFilesExist": shortEmptyRawURLs.allSatisfy {
                    FileManager.default.fileExists(atPath: $0.path)
                },
                "durableTranscriptUtteranceCount": shortEmptyStored.utterances.count,
            ],
            "fiveSecondsSpoken": [
                "durationMilliseconds": 5_000,
                "terminalTranscriptionState": shortSpokenStored.meeting.transcriptionState.rawValue,
                "audioRetentionState": shortSpokenStored.meeting.audioRetentionState.rawValue,
                "retainedFilename": shortSpokenStored.meeting.retainedAudio?.filename ?? "missing",
                "durableTranscriptUtteranceCount": shortSpokenStored.utterances.count,
            ],
            "exactly30SecondsEmpty": [
                "durationMilliseconds": 30_000,
                "meetingDirectoryExists": FileManager.default.fileExists(
                    atPath: boundaryEmpty.meetingDirectory.path
                ),
                "terminalTranscriptionState": boundaryStored.meeting.transcriptionState.rawValue,
                "sourceAudioFilesExist": boundaryRawURLs.allSatisfy {
                    FileManager.default.fileExists(atPath: $0.path)
                },
                "durableTranscriptUtteranceCount": boundaryStored.utterances.count,
            ],
        ], named: "short-recording-retention.json")
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
    func artifactFailureLeavesProcessingRetryableAndNeverCommitsCompletion() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let client = CoordinatorSuccessClient()
        let artifactStore = MeetingTranscriptArtifactStore(
            rootURL: fixture.rootURL,
            failureInjector: { event in
                if event == .beforeAtomicReplacement { throw CoordinatorArtifactFailure() }
            }
        )
        let coordinator = fixture.coordinator(
            client: client,
            transcriptArtifactStore: artifactStore
        )
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)

        let result = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(result.transcriptionState == .processing)
        #expect(stored.meeting.transcriptionState == .processing)
        #expect(stored.meeting.selectedRawTranscriptAttemptID == nil)
        #expect(stored.rawTranscriptArtifacts == nil)
        #expect(stored.meeting.retainedAudio == nil)
        #expect(fixture.rawURLs(for: capture).allSatisfy {
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
        #expect(await client.microphoneCallCount == 2)
    }

    @Test
    func initialSystemicFailurePreservesSuccessfulPartialTranscript() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        let client = CoordinatorPartialSystemicClient()
        let coordinator = fixture.coordinator(client: client)
        let preview = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10,
            text: "Earlier live preview.",
            baseSpeakerID: "you"
        )
        let processing = try coordinator.stage(
            meeting: fixture.meeting,
            capture: capture,
            utterances: [preview]
        )

        let failed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(failed.transcriptionState == .failed)
        #expect(stored.meeting == failed)
        #expect(stored.utterances.count == 1)
        #expect(stored.utterances.first?.source == .microphone)
        #expect(stored.utterances.first?.text == "Keep this successful partial transcript.")
        #expect(stored.rawTranscriptArtifacts?.attempts.count == 1)
        #expect(stored.rawTranscriptArtifacts?.selectedAttemptID == nil)
        #expect(stored.rawTranscriptArtifacts?.attempts.first?.failureTotals.systemic == 1)
        try writeEvidence([
            "scenario": "Systemic transcription failure preserves partial transcript and source audio",
            "lifecycleState": stored.meeting.lifecycleState.rawValue,
            "terminalTranscriptionState": stored.meeting.transcriptionState.rawValue,
            "transcriptionAttemptCount": stored.meeting.transcriptionAttemptCount,
            "transcriptionErrorMessage": stored.meeting.transcriptionErrorMessage ?? "missing",
            "partialTranscript": stored.utterances.map(\.text),
            "partialTranscriptSources": stored.utterances.map(\.source.rawValue),
            "sourceAudioFilesExist": rawURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            },
            "audioRetentionState": stored.meeting.audioRetentionState.rawValue,
        ], named: "transcription-failure-preservation.json")
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
        #expect(stored.rawTranscriptArtifacts?.attempts.count == 2)
        #expect(stored.rawTranscriptArtifacts?.selectedAttemptID
            == completed.selectedRawTranscriptAttemptID)
        #expect(stored.rawTranscriptArtifacts?.selectedAttempt?.utterances == stored.utterances)
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
        failed.analysisState = .completed
        failed.uploadState = .delivered
        try fixture.store.save(failed, utterances: originalTranscript)
        let client = CoordinatorCancellableClient()
        let coordinator = fixture.coordinator(client: client)
        let retry = Task {
            try await coordinator.retry(meetingID: fixture.meeting.id)
        }
        await client.waitUntilCallCount(atLeast: 1)

        let inFlight = try fixture.store.load(fixture.meeting.id)
        #expect(inFlight.meeting.transcriptionState == .processing)
        #expect(inFlight.meeting.transcriptionErrorMessage == "Retry requested.")
        #expect(inFlight.meeting.analysisState == .completed)
        #expect(inFlight.meeting.uploadState == .delivered)
        #expect(inFlight.utterances == originalTranscript)

        var deletionResult: MeetingRecord?
        try await coordinator.cancelAndWaitForDeletion(
            meetingID: fixture.meeting.id
        ) {
            #expect(coordinator.isRunning(meetingID: fixture.meeting.id))
            deletionResult = try fixture.retention.deleteRecording(
                for: fixture.meeting.id,
                confirmed: true
            )
        }
        _ = try await retry.value
        let deleted = try #require(deletionResult)
        let stored = try fixture.store.load(fixture.meeting.id)
        let launchReconciled = coordinator.reconcileInterruptedJobs(at: failed.startedAt)

        #expect(deleted.transcriptionState == .failed)
        #expect(deleted.transcriptionAttemptCount == 1)
        #expect(deleted.transcriptionErrorMessage == "Retry requested.")
        #expect(deleted.retainedAudio == nil)
        #expect(deleted.audioRetentionState == .deleted)
        #expect(deleted.analysisState == .completed)
        #expect(deleted.uploadState == .delivered)
        #expect(stored.meeting == deleted)
        #expect(stored.utterances == originalTranscript)
        #expect(launchReconciled.isEmpty)
        let retryRejectedAfterDeletion: Bool
        do {
            _ = try await coordinator.retry(meetingID: fixture.meeting.id)
            retryRejectedAfterDeletion = false
        } catch MeetingTranscriptionCoordinatorError.transcriptionNotRetryable {
            retryRejectedAfterDeletion = true
        } catch {
            retryRejectedAfterDeletion = false
        }
        #expect(retryRejectedAfterDeletion)

        let remainingFiles = try FileManager.default.contentsOfDirectory(
            atPath: fixture.meetingDirectory.path
        ).sorted()
        try writeEvidence([
            "scenario": "Explicit audio deletion atomically wins over retry and launch recovery",
            "inFlightTranscriptionState": inFlight.meeting.transcriptionState.rawValue,
            "terminalTranscriptionState": stored.meeting.transcriptionState.rawValue,
            "terminalAttemptCount": stored.meeting.transcriptionAttemptCount,
            "terminalErrorMessage": stored.meeting.transcriptionErrorMessage ?? "missing",
            "audioRetentionState": stored.meeting.audioRetentionState.rawValue,
            "retainedMetadataCleared": stored.meeting.retainedAudio == nil,
            "recordingFileExists": FileManager.default.fileExists(
                atPath: fixture.meetingDirectory
                    .appendingPathComponent(AudioRetentionController.retainedFilename).path
            ),
            "durableTranscript": stored.utterances.map(\.text),
            "analysisState": stored.meeting.analysisState.rawValue,
            "uploadState": stored.meeting.uploadState.rawValue,
            "retryRejectedAfterDeletion": retryRejectedAfterDeletion,
            "launchRecoveryChangedDeletedItem": !launchReconciled.isEmpty,
            "retryStillRunning": coordinator.isRunning(meetingID: fixture.meeting.id),
            "directoryFilesAfterDeletion": remainingFiles,
        ], named: "deletion-wins-over-retry-recovery.json")
    }

    @Test
    func failedRetryPreservesDurableTranscriptAndDerivedMetadata() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let originalTranscript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Keep the previous durable transcript.",
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
        failed.transcriptionErrorMessage = "Previous transcription failure."
        failed.analysisState = .completed
        failed.uploadState = .delivered
        try fixture.store.save(failed, utterances: originalTranscript)

        let result = try await fixture.coordinator(client: CoordinatorUnsupportedClient())
            .retry(meetingID: failed.id)
        let stored = try fixture.store.load(failed.id)

        #expect(result.transcriptionState == .failed)
        #expect(result.analysisState == .completed)
        #expect(result.uploadState == .delivered)
        #expect(stored.utterances == originalTranscript)
        #expect(stored.meeting.retainedAudio == archived.retainedAudio)
        #expect(stored.meeting.transcriptionErrorMessage != failed.transcriptionErrorMessage)
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
    func legacyStyleFirstRetryArchiveFailurePreservesDurableMetadata() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        var completed = fixture.meeting
        completed.transcriptionState = .completed
        completed.transcriptionAttemptCount = 1
        let retained = try fixture.retention.finalize(
            meeting: completed,
            utterances: [],
            audio: fixture.makeCapture()
        )
        var legacy = retained
        legacy.title = "Durable legacy title"
        legacy.titleSource = .manual
        legacy.transcriptionState = .failed
        legacy.transcriptionAttemptCount = 0
        legacy.transcriptionErrorMessage = "Durable legacy retry detail."
        legacy.analysisState = .completed
        legacy.uploadState = .delivered
        try fixture.store.save(legacy, utterances: [])
        let failingRetention = AudioRetentionController(
            store: fixture.store,
            fileSystem: CoordinatorRecordingWriteFailureFileSystem()
        )

        let result = try await fixture.coordinator(
            client: CoordinatorSuccessClient(),
            retention: failingRetention
        ).retry(meetingID: legacy.id)
        let stored = try fixture.store.load(legacy.id)

        #expect(result.transcriptionState == .failed)
        #expect(stored.meeting.title == legacy.title)
        #expect(stored.meeting.titleSource == legacy.titleSource)
        #expect(stored.meeting.analysisState == legacy.analysisState)
        #expect(stored.meeting.uploadState == legacy.uploadState)
        #expect(stored.meeting.retainedAudio == legacy.retainedAudio)
        #expect(FileManager.default.fileExists(atPath: fixture.meetingDirectory
            .appendingPathComponent(AudioRetentionController.retainedFilename).path))
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
    func launchReconciliationReusesThePrimaryStoreListing() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        try fixture.store.save(fixture.meeting, utterances: [])
        let countingStore = CoordinatorCountingRetentionStore(store: fixture.store)
        let retention = AudioRetentionController(store: countingStore)

        _ = fixture.coordinator(
            client: CoordinatorSuccessClient(),
            retention: retention
        ).reconcileInterruptedJobs(at: fixture.meeting.startedAt)

        #expect(countingStore.listCallCount == 0)
    }

    @Test
    func launchReconciliationPreservesDurableRetryMetadata() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let transcript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Keep the durable transcript and derived state.",
            baseSpeakerID: "you"
        )]
        var completed = fixture.meeting
        completed.transcriptionState = .completed
        completed.transcriptionAttemptCount = 1
        let archived = try fixture.retention.finalize(
            meeting: completed,
            utterances: transcript,
            audio: fixture.makeCapture()
        )
        var interruptedRetry = archived
        interruptedRetry.transcriptionState = .processing
        interruptedRetry.transcriptionAttemptCount = 2
        interruptedRetry.transcriptionErrorMessage = "Previous retry detail."
        interruptedRetry.analysisState = .completed
        interruptedRetry.uploadState = .delivered
        try fixture.store.save(interruptedRetry, utterances: transcript)

        let reconciled = fixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: interruptedRetry.startedAt)
        let stored = try fixture.store.load(interruptedRetry.id)

        #expect(reconciled.map(\.id) == [interruptedRetry.id])
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(stored.meeting.analysisState == .completed)
        #expect(stored.meeting.uploadState == .delivered)
        #expect(stored.meeting.retainedAudio == archived.retainedAudio)
        #expect(stored.utterances == transcript)
        try writeEvidence([
            "scenario": "Launch recovery preserves durable retry state",
            "terminalTranscriptionState": stored.meeting.transcriptionState.rawValue,
            "transcriptionAttemptCount": stored.meeting.transcriptionAttemptCount,
            "transcriptionErrorMessage": stored.meeting.transcriptionErrorMessage ?? "missing",
            "retainedFilename": stored.meeting.retainedAudio?.filename ?? "missing",
            "audioRetentionState": stored.meeting.audioRetentionState.rawValue,
            "durableTranscript": stored.utterances.map(\.text),
            "analysisState": stored.meeting.analysisState.rawValue,
            "uploadState": stored.meeting.uploadState.rawValue,
        ], named: "launch-recovery-durable-state.json")
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
    func launchReconciliationPreservesAmbiguousLegacyRawAudioWithoutRetrying() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeCapture()
        let rawURLs = fixture.rawURLs(for: capture)
        var legacyDeleted = fixture.meeting
        legacyDeleted.transcriptionState = .completed
        legacyDeleted.transcriptionAttemptCount = 1
        legacyDeleted.retainedAudio = nil
        let transcript = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Keep the legacy transcript.",
            baseSpeakerID: "you"
        )]
        try fixture.store.save(legacyDeleted, utterances: transcript)
        try fixture.removeAudioRetentionState()

        let reconciled = fixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: legacyDeleted.startedAt)
        let stored = try fixture.store.load(legacyDeleted.id)

        #expect(reconciled.isEmpty)
        #expect(stored.meeting.transcriptionState == .completed)
        #expect(stored.meeting.audioRetentionState == .unresolvedLegacy)
        #expect(stored.meeting.retainedAudio == nil)
        #expect(stored.utterances == transcript)
        #expect(rawURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try writeEvidence([
            "scenario": "Ambiguous legacy recording remains conservative and compatible",
            "terminalTranscriptionState": stored.meeting.transcriptionState.rawValue,
            "audioRetentionState": stored.meeting.audioRetentionState.rawValue,
            "retainedMetadataPresent": stored.meeting.retainedAudio != nil,
            "durableTranscript": stored.utterances.map(\.text),
            "sourceAudioFilesExist": rawURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            },
            "launchRecoveryStartedRetry": !reconciled.isEmpty,
        ], named: "legacy-recording-conservative-recovery.json")
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
    func retryPrefersRetainedArchiveOverIncompleteRawRecovery() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        var completed = fixture.meeting
        completed.transcriptionState = .completed
        completed.transcriptionAttemptCount = 1
        let archived = try fixture.retention.finalize(
            meeting: completed,
            utterances: [try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                text: "Keep the complete archived transcript.",
                baseSpeakerID: "you"
            )],
            audio: fixture.makeCapture()
        )
        var failed = archived
        failed.transcriptionState = .failed
        failed.transcriptionErrorMessage = "Retry the archived recording."
        let durableTranscript = try fixture.store.load(failed.id).utterances
        try fixture.store.save(failed, utterances: durableTranscript)

        let microphoneURL = fixture.meetingDirectory.appendingPathComponent(
            "microphone.f32le.pcm"
        )
        let partialSamples = [Float](repeating: 0.75, count: 4)
        let partialData = partialSamples.withUnsafeBytes { Data($0) }
        #expect(FileManager.default.createFile(
            atPath: microphoneURL.path,
            contents: partialData,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ))

        let retried = try await fixture.coordinator(client: CoordinatorUnsupportedClient())
            .retry(meetingID: failed.id)
        let recovered = try fixture.loadCaptureManifest()
        let frameCounts = recovered.tracks.map(\.frameCount)

        #expect(retried.transcriptionState == .failed)
        #expect(frameCounts.count == 2)
        #expect(Set(frameCounts).count == 1)
        #expect(frameCounts.allSatisfy { $0 > Int64(partialSamples.count) })
        #expect(try fixture.store.load(failed.id).utterances == durableTranscript)
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

    @Test
    func launchReconciliationDoesNotRecoverCommittedWholeItemDeletion() throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        _ = try fixture.makeCapture()
        let tombstone = fixture.rootURL.appendingPathComponent(
            ".\(fixture.meeting.id.uuidString).\(UUID().uuidString).deleting",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.meetingDirectory, to: tombstone)

        let recovered = fixture.coordinator(client: CoordinatorSuccessClient())
            .reconcileInterruptedJobs(at: fixture.meeting.startedAt)

        #expect(recovered.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.meetingDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
    }

    @Test
    func completePersistsClusteredSpeakersOnUtterancesAndAttempt() async throws {
        let fixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try fixture.makeTwoRemoteTurnCapture()
        let client = CoordinatorSuccessClient()
        let diarizer = SequentialSystemClusterDiarizer(speakerIDs: ["remote-2", "remote-3"])
        let coordinator = fixture.coordinator(client: client, diarizer: diarizer)
        let processing = try coordinator.stage(meeting: fixture.meeting, capture: capture)

        let completed = await coordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try fixture.transcript(client: client, capture: capture)
        )
        let stored = try fixture.store.load(fixture.meeting.id)
        let attempt = try #require(stored.rawTranscriptArtifacts?.selectedAttempt)
        let storedSystem = stored.utterances.filter { $0.source == .system }
        let attemptSystem = attempt.utterances.filter { $0.source == .system }

        #expect(storedSystem.map(\.baseSpeakerID) == ["remote-2", "remote-3"])
        #expect(attemptSystem.map(\.baseSpeakerID) == ["remote-2", "remote-3"])
        #expect(storedSystem.allSatisfy { $0.humanName == nil })
        #expect(stored.utterances.contains { $0.source == .microphone && $0.baseSpeakerID == "you" })
        #expect(completed.transcriptionState == .completed)
    }

    @Test
    func voiceNoteAndMissingDiarizerLeaveRemote() async throws {
        let voiceFixture = try MeetingTranscriptionCoordinatorFixture()
        let voiceCapture = try voiceFixture.makeCapture()
        let client = CoordinatorSuccessClient()
        let voiceNoteFlag = RecordingDiarizerFlag()
        var voiceNoteMeeting = voiceFixture.meeting
        voiceNoteMeeting.recordingKind = .voiceNote
        let voiceNoteCoordinator = voiceFixture.coordinator(
            client: client,
            diarizer: RecordingDiarizer(
                flag: voiceNoteFlag,
                speakerIDs: ["remote-2", "remote-3"]
            )
        )
        let voiceNoteProcessing = try voiceNoteCoordinator.stage(
            meeting: voiceNoteMeeting,
            capture: voiceCapture
        )
        let voiceNoteCompleted = await voiceNoteCoordinator.complete(
            meeting: voiceNoteProcessing,
            capture: voiceCapture,
            transcript: try voiceFixture.transcript(client: client, capture: voiceCapture)
        )

        #expect(voiceNoteFlag.called == false)
        #expect(voiceNoteCompleted.transcriptionState == .completed)

        let meetingFixture = try MeetingTranscriptionCoordinatorFixture()
        let capture = try meetingFixture.makeCapture()
        let missingTrackFlag = RecordingDiarizerFlag()
        let meetingCoordinator = meetingFixture.coordinator(
            client: client,
            diarizer: RecordingDiarizer(
                flag: missingTrackFlag,
                speakerIDs: ["remote-2", "remote-3"],
                simulateMissingSystemTrack: true
            )
        )
        let processing = try meetingCoordinator.stage(meeting: meetingFixture.meeting, capture: capture)
        let completed = await meetingCoordinator.complete(
            meeting: processing,
            capture: capture,
            transcript: try meetingFixture.transcript(client: client, capture: capture)
        )
        let stored = try meetingFixture.store.load(meetingFixture.meeting.id)

        #expect(missingTrackFlag.called == true)
        #expect(completed.transcriptionState == .completed)
        #expect(stored.utterances.contains { $0.source == .system && $0.baseSpeakerID == "remote" })
    }

    private func writeEvidence(_ object: [String: Any], named filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BRAIN_TEST_EVIDENCE_DIR"] else {
            return
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(filename),
            options: .atomic
        )
    }
}

private struct CoordinatorArtifactFailure: Error {}

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
        transcriptArtifactStore: MeetingTranscriptArtifactStore? = nil,
        uploadScheduler: @escaping MeetingTranscriptionCoordinator.UploadScheduler = { _ in },
        diarizer: (any MeetingSpeakerDiarizing)? = nil
    ) -> MeetingTranscriptionCoordinator {
        MeetingTranscriptionCoordinator(
            store: store,
            transcriptArtifactStore: transcriptArtifactStore,
            retention: selectedRetention ?? retention,
            uploadScheduler: uploadScheduler,
            clientFactory: { client },
            diarizer: diarizer
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
        // Final transcription's speech evidence gate requires at least 300 ms
        // of voiced audio; keep the shared fixture unambiguously speech-bearing.
        let voicedFrames = [Float](repeating: 0.25, count: 8_000)
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

    /// Two voiced system callbacks separated by more than the span merge
    /// window, so final transcription plans one utterance per remote turn.
    func makeTwoRemoteTurnCapture() throws -> MeetingAudioCaptureSummary {
        let writer = try MeetingAudioWriter(
            meetingDirectory: meetingDirectory,
            origin: meeting.startedAt
        )
        let voicedFrames = [Float](repeating: 0.25, count: 8_000)
        for (source, hostTimestamp) in [
            (MeetingAudioSource.microphone, 100.0),
            (.system, 100.5),
            (.system, 103.0),
        ] {
            _ = try writer.append(MeetingAudioSampleBuffer(
                source: source,
                sourceTimestamp: hostTimestamp - 90,
                hostTimestamp: hostTimestamp,
                sampleRate: 16_000,
                channelCount: 1,
                interleavedSamples: voicedFrames
            ))
        }
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

    func removeAudioRetentionState() throws {
        let meetingURL = meetingDirectory.appendingPathComponent(MeetingStore.meetingFilename)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL)) as? [String: Any]
        )
        object.removeValue(forKey: "audioRetentionState")
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

private final class RecordingDiarizerFlag: @unchecked Sendable {
    var called = false
}

private struct RecordingDiarizer: MeetingSpeakerDiarizing {
    let flag: RecordingDiarizerFlag
    let speakerIDs: [String]
    var simulateMissingSystemTrack = false

    func assign(
        utterances: [MeetingUtterance],
        capture: MeetingAudioCaptureSummary?
    ) -> [UUID: String] {
        flag.called = true
        guard !simulateMissingSystemTrack, capture != nil else { return [:] }
        let system = utterances
            .filter { $0.source == .system }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
        var map: [UUID: String] = [:]
        for (index, utterance) in system.prefix(speakerIDs.count).enumerated() {
            map[utterance.id] = speakerIDs[index]
        }
        return map
    }
}

private struct SequentialSystemClusterDiarizer: MeetingSpeakerDiarizing {
    let speakerIDs: [String]

    func assign(
        utterances: [MeetingUtterance],
        capture: MeetingAudioCaptureSummary?
    ) -> [UUID: String] {
        let system = utterances
            .filter { $0.source == .system }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
        var map: [UUID: String] = [:]
        for (index, utterance) in system.prefix(speakerIDs.count).enumerated() {
            map[utterance.id] = speakerIDs[index]
        }
        return map
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

private actor CoordinatorPartialSystemicClient: LiveTranscriptionClient {
    func transcribe(wavURL: URL, engine: String) async throws -> String {
        if wavURL.lastPathComponent.contains("microphone") {
            return "Keep this successful partial transcript."
        }
        throw VoxTypeUnsupportedEngineError(engine: engine)
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

private final class CoordinatorCountingRetentionStore: AudioRetentionMeetingStoring {
    let store: MeetingStore
    private(set) var listCallCount = 0

    init(store: MeetingStore) {
        self.store = store
    }

    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws {
        try store.save(meeting, utterances: utterances)
    }

    func load(_ id: UUID) throws -> StoredMeeting {
        try store.load(id)
    }

    func list() throws -> [MeetingListEntry] {
        listCallCount += 1
        return try store.list()
    }

    func directoryURL(for id: UUID) -> URL {
        store.directoryURL(for: id)
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
