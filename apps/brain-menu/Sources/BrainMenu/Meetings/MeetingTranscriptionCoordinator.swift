import AVFoundation
import Darwin
import Foundation

enum MeetingTranscriptionCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case voxTypeUnavailable
    case unsafeAudioManifest
    case transcriptionNotRetryable
    case transcriptionAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .voxTypeUnavailable:
            "Brain could not find the VoxType command-line tool."
        case .unsafeAudioManifest:
            "The private meeting audio needed for transcription is unavailable or unsafe."
        case .transcriptionNotRetryable:
            "This meeting does not have a failed or interrupted transcription to retry."
        case .transcriptionAlreadyRunning:
            "This meeting is already being transcribed."
        }
    }
}

private enum RetainedAudioRecoveryError: Error {
    case promotionFailed
}

@MainActor
protocol MeetingTranscriptionRetrying: AnyObject {
    func retry(meetingID: UUID) async throws -> MeetingRecord
    func isRunning(meetingID: UUID) -> Bool
    func cancelAndWait(meetingID: UUID) async
    func cancelAndWaitForDeletion(
        meetingID: UUID,
        operation: @MainActor () throws -> Void
    ) async throws
}

extension MeetingTranscriptionRetrying {
    func isRunning(meetingID: UUID) -> Bool { false }
    func cancelAndWait(meetingID: UUID) async {}
}

/// Owns the post-recording transcript job. The captured source tracks and
/// manifest remain private and durable until a final transcript replaces them
/// with a private recording or the user explicitly deletes the audio. Failed
/// or cancelled attempts keep their source audio retryable.
@MainActor
final class MeetingTranscriptionCoordinator: MeetingTranscriptionRetrying {
    typealias ClientFactory = @Sendable () throws -> any LiveTranscriptionClient
    typealias UploadScheduler = @MainActor (UUID) -> Void

    private static let registry = MeetingTranscriptionJobRegistry.shared
    private let store: MeetingStore
    private let retention: AudioRetentionController
    private let scheduleUpload: UploadScheduler
    private let clientFactory: ClientFactory
    private let fileManagerBox: MeetingTranscriptionFileManagerBox

    init(
        store: MeetingStore = MeetingStore(),
        retention: AudioRetentionController = AudioRetentionController(),
        uploader: MeetingUploadController = MeetingUploadController(),
        uploadScheduler: UploadScheduler? = nil,
        fileManager: FileManager = .default,
        clientFactory: @escaping ClientFactory = {
            guard let client = try VoxTypeClient.discover() else {
                throw MeetingTranscriptionCoordinatorError.voxTypeUnavailable
            }
            return client
        }
    ) {
        self.store = store
        self.retention = retention
        scheduleUpload = uploadScheduler ?? { [uploader] meetingID in
            Task {
                await uploader.uploadAfterFinalTranscriptPersistence(meetingID: meetingID)
            }
        }
        fileManagerBox = MeetingTranscriptionFileManagerBox(fileManager)
        self.clientFactory = clientFactory
    }

    /// Atomically exposes a completed recording as a processing job before any
    /// final speech command starts. A crash after this point is recovered from
    /// `audio-capture.json` into a saved item that waits for explicit retry.
    func stage(
        meeting: MeetingRecord,
        capture: MeetingAudioCaptureSummary,
        utterances: [MeetingUtterance] = []
    ) throws -> MeetingRecord {
        guard !Self.registry.contains(key(for: meeting.id)) else {
            throw MeetingTranscriptionCoordinatorError.transcriptionAlreadyRunning
        }
        _ = try validatedManifest(capture, meetingID: meeting.id)
        var processing = meeting
        processing.lifecycleState = .completed
        processing.transcriptionState = .processing
        processing.transcriptionAttemptCount += 1
        processing.transcriptionErrorMessage = nil
        processing.analysisState = .notRequested
        processing.uploadState = .notUploaded
        try store.save(processing, utterances: utterances)
        return processing
    }

    private func stageOwned(
        meeting: MeetingRecord,
        capture: MeetingAudioCaptureSummary,
        key: MeetingTranscriptionJobKey,
        token: UUID,
        generation: Int
    ) throws -> MeetingRecord {
        guard Self.registry.isCurrent(
            key: key,
            token: token,
            generation: generation
        ) else {
            throw MeetingTranscriptionCoordinatorError.transcriptionAlreadyRunning
        }
        _ = try validatedManifest(capture, meetingID: meeting.id)
        let current = try store.load(meeting.id)
        guard current.meeting.transcriptionAttemptCount + 1 == generation,
              current.meeting.audioRetentionState != .deleted,
              !retention.hasInterruptedDeletion(for: meeting.id),
              [.pending, .processing, .failed].contains(
                  current.meeting.transcriptionState
              ) else {
            throw MeetingTranscriptionCoordinatorError.transcriptionNotRetryable
        }
        var processing = current.meeting
        processing.lifecycleState = .completed
        processing.transcriptionState = .processing
        processing.transcriptionAttemptCount = generation
        try store.save(processing, utterances: current.utterances)
        return processing
    }

    /// Completes an already-staged job using the live controller's final pass.
    /// Final-span failures are metadata, never synthetic transcript text.
    func complete(
        meeting: MeetingRecord,
        capture: MeetingAudioCaptureSummary,
        transcript: LiveTranscriptController
    ) async -> MeetingRecord {
        let key = key(for: meeting.id)
        if let existing = Self.registry.entry(for: key) {
            guard existing.generation == meeting.transcriptionAttemptCount else {
                return currentRecord(for: meeting.id, fallback: meeting)
            }
            return await existing.task.value
        }

        guard isCurrentProcessingGeneration(meeting) else {
            return currentRecord(for: meeting.id, fallback: meeting)
        }

        let token = UUID()
        let cancellation = MeetingTranscriptionCancellationRelay()
        let task = Task { @MainActor [self] in
            await cancellation.set {
                await transcript.cancel()
            }
            return await executeCompletion(
                meeting: meeting,
                capture: capture,
                transcript: transcript,
                key: key,
                token: token
            )
        }
        let entry = MeetingTranscriptionJobRegistry.Entry(
            token: token,
            generation: meeting.transcriptionAttemptCount,
            retrySnapshot: nil,
            task: task,
            cancel: {
                await cancellation.cancel()
            }
        )
        guard Self.registry.install(entry, for: key) else {
            task.cancel()
            await transcript.cancel()
            if let existing = Self.registry.entry(for: key) {
                return await existing.task.value
            }
            return currentRecord(for: meeting.id, fallback: meeting)
        }

        let result = await task.value
        Self.registry.remove(key: key, token: token)
        return result
    }

    private func executeCompletion(
        meeting: MeetingRecord,
        capture: MeetingAudioCaptureSummary,
        transcript: LiveTranscriptController,
        key: MeetingTranscriptionJobKey,
        token: UUID
    ) async -> MeetingRecord {
        if let qualityIssue = MeetingAudioCaptureQuality.issue(in: capture) {
            let partialUtterances = transcript.utterances
            await transcript.cancel()
            let outcome = await Task.detached(priority: .utility) { [store] in
                MeetingTranscriptionPersistenceOutcome(
                    meeting: Self.persistFailureIfCurrent(
                        meeting: meeting,
                        attemptUtterances: partialUtterances,
                        message: qualityIssue.message,
                        store: store
                    ),
                    shouldScheduleUpload: false
                )
            }.value
            return currentRecord(for: meeting.id, fallback: outcome.meeting)
        }
        await transcript.stop(capture: capture)
        guard !Task.isCancelled,
              Self.registry.isCurrent(
                  key: key,
                  token: token,
                  generation: meeting.transcriptionAttemptCount
              ),
              isCurrentProcessingGeneration(meeting) else {
            return currentRecord(for: meeting.id, fallback: meeting)
        }

        let resolvedMeeting = meeting
        let utterances = transcript.utterances
        let failures = transcript.errors.filter { $0.phase == .final }
        let outcome = await Task.detached(priority: .utility) { [store, retention] in
            Self.persistFinalResult(
                meeting: resolvedMeeting,
                capture: capture,
                utterances: utterances,
                failures: failures,
                store: store,
                retention: retention
            )
        }.value

        guard !Task.isCancelled,
              Self.registry.isCurrent(
                  key: key,
                  token: token,
                  generation: meeting.transcriptionAttemptCount
              ) else {
            return currentRecord(for: meeting.id, fallback: outcome.meeting)
        }
        let current = currentRecord(for: meeting.id, fallback: outcome.meeting)
        if outcome.shouldScheduleUpload,
           current.transcriptionState == .completed,
           current.transcriptionAttemptCount == meeting.transcriptionAttemptCount {
            scheduleUpload(current.id)
        }
        return current
    }

    func retry(meetingID: UUID) async throws -> MeetingRecord {
        let jobKey = key(for: meetingID)
        if let existing = Self.registry.entry(for: jobKey) {
            return await existing.task.value
        }
        let stored = try store.load(meetingID)
        guard [.pending, .processing, .failed].contains(stored.meeting.transcriptionState),
              stored.meeting.audioRetentionState != .deleted,
              !retention.hasInterruptedDeletion(for: meetingID) else {
            throw MeetingTranscriptionCoordinatorError.transcriptionNotRetryable
        }

        let token = UUID()
        let generation = stored.meeting.transcriptionAttemptCount + 1
        let cancellation = MeetingTranscriptionCancellationRelay()
        let task = Task { @MainActor [self] in
            guard !Task.isCancelled,
                  Self.registry.isCurrent(
                      key: jobKey,
                      token: token,
                      generation: generation
                  ) else {
                return currentRecord(for: meetingID, fallback: stored.meeting)
            }
            let capture: MeetingAudioCaptureSummary
            do {
                capture = try await Task.detached(
                    priority: .utility
                ) { [store, fileManagerBox] in
                    try Self.loadOrRecoverCapture(
                        meeting: stored.meeting,
                        directory: store.directoryURL(for: meetingID),
                        fileManager: fileManagerBox.value
                    )
                }.value
            } catch {
                return persistUnrecoverableRetry(
                    meeting: stored.meeting,
                    key: jobKey,
                    token: token,
                    generation: generation,
                    message: Self.bounded(error),
                    store: store
                )
            }
            guard !Task.isCancelled,
                  Self.registry.isCurrent(
                      key: jobKey,
                      token: token,
                      generation: generation
                  ) else {
                return currentRecord(for: meetingID, fallback: stored.meeting)
            }

            let processing: MeetingRecord
            do {
                processing = try stageOwned(
                    meeting: stored.meeting,
                    capture: capture,
                    key: jobKey,
                    token: token,
                    generation: generation
                )
                let client = try clientFactory()
                let requestedEngine =
                    SpeechEngineID(rawValue: processing.speechEngine) ?? .parakeet
                let service = try LiveTranscriptionService(
                    client: client,
                    engine: requestedEngine,
                    attestedModel: processing.speechModel,
                    originHostTimestamp: capture.originHostTimestamp,
                    wavDirectory: store.directoryURL(for: meetingID)
                        .appendingPathComponent(".transcription", isDirectory: true)
                )
                let transcript = LiveTranscriptController(service: service)
                await cancellation.set {
                    await transcript.cancel()
                }
                return await executeCompletion(
                    meeting: processing,
                    capture: capture,
                    transcript: transcript,
                    key: jobKey,
                    token: token
                )
            } catch {
                let candidate = currentRecord(for: meetingID, fallback: stored.meeting)
                return Self.persistFailureIfCurrent(
                    meeting: candidate,
                    message: Self.bounded(error),
                    store: store
                )
            }
        }
        let entry = MeetingTranscriptionJobRegistry.Entry(
            token: token,
            generation: generation,
            retrySnapshot: stored.meeting,
            task: task,
            cancel: {
                await cancellation.cancel()
            }
        )
        guard Self.registry.install(entry, for: jobKey) else {
            task.cancel()
            await cancellation.cancel()
            if let existing = Self.registry.entry(for: jobKey) {
                return await existing.task.value
            }
            throw MeetingTranscriptionCoordinatorError.transcriptionAlreadyRunning
        }
        let result = await task.value
        Self.registry.remove(key: jobKey, token: token)
        return result
    }

    private func persistUnrecoverableRetry(
        meeting: MeetingRecord,
        key: MeetingTranscriptionJobKey,
        token: UUID,
        generation: Int,
        message: String,
        store: MeetingStore
    ) -> MeetingRecord {
        guard Self.registry.isCurrent(
            key: key,
            token: token,
            generation: generation
        ), let current = try? store.load(meeting.id),
           current.meeting.transcriptionAttemptCount + 1 == generation,
           current.meeting.audioRetentionState != .deleted else {
            return currentRecord(for: meeting.id, fallback: meeting)
        }
        var failed = current.meeting
        failed.lifecycleState = .completed
        failed.transcriptionState = .failed
        failed.transcriptionAttemptCount = generation
        failed.transcriptionErrorMessage = String(message.prefix(720))
        do {
            try store.save(failed, utterances: current.utterances)
            return failed
        } catch {
            return currentRecord(for: meeting.id, fallback: failed)
        }
    }

    func isRunning(meetingID: UUID) -> Bool {
        Self.registry.contains(key(for: meetingID))
    }

    func cancelAndWait(meetingID: UUID) async {
        let jobKey = key(for: meetingID)
        guard let entry = Self.registry.entry(for: jobKey) else { return }
        entry.task.cancel()
        await entry.cancel()
        _ = await entry.task.value
        Self.registry.remove(key: jobKey, token: entry.token)
    }

    func cancelAndWaitForDeletion(
        meetingID: UUID,
        operation: @MainActor () throws -> Void
    ) async throws {
        let jobKey = key(for: meetingID)
        let reservationToken: UUID
        var cancelledRetrySnapshot: MeetingRecord?
        while true {
            if let entry = Self.registry.entry(for: jobKey) {
                entry.task.cancel()
                await entry.cancel()
                let result = await entry.task.value
                if result.transcriptionState == .processing {
                    cancelledRetrySnapshot = entry.retrySnapshot
                }
                if let token = Self.registry.reserveDeletion(
                    jobKey,
                    replacingEntryWithToken: entry.token
                ) {
                    reservationToken = token
                    break
                }
                guard !Self.registry.hasDeletionReservation(jobKey) else {
                    throw MeetingTranscriptionCoordinatorError.transcriptionAlreadyRunning
                }
                continue
            }
            guard let token = Self.registry.reserveDeletion(
                jobKey,
                replacingEntryWithToken: nil
            ) else {
                throw MeetingTranscriptionCoordinatorError.transcriptionAlreadyRunning
            }
            reservationToken = token
            break
        }

        defer {
            Self.registry.releaseDeletion(jobKey, token: reservationToken)
        }
        if let cancelledRetrySnapshot {
            try restoreCancelledRetry(
                cancelledRetrySnapshot,
                meetingID: meetingID
            )
        }
        try operation()
    }

    private func restoreCancelledRetry(
        _ snapshot: MeetingRecord,
        meetingID: UUID
    ) throws {
        let stored = try store.load(meetingID)
        guard stored.meeting.transcriptionState == .processing,
              stored.meeting.transcriptionAttemptCount
                == snapshot.transcriptionAttemptCount + 1 else { return }
        var restored = stored.meeting
        restored.transcriptionState = snapshot.transcriptionState
        restored.transcriptionAttemptCount = snapshot.transcriptionAttemptCount
        restored.transcriptionErrorMessage = snapshot.transcriptionErrorMessage
        restored.analysisState = snapshot.analysisState
        restored.uploadState = snapshot.uploadState
        try store.save(restored, utterances: stored.utterances)
    }

    /// Resumes jobs interrupted while pending/processing. It also closes the
    /// narrow crash window after a new-pipeline transcript became durable but
    /// before its idempotent upload was scheduled. Failed transcription attempts
    /// still wait for the user's explicit Retry action.
    func resumeInterruptedJobs() async -> [MeetingRecord] {
        guard let entries = try? store.list() else { return [] }
        var results = retention.reconcileInterruptedDeletions(in: entries)
        for entry in entries {
            guard case .available(let meeting) = entry,
                  !retention.hasInterruptedDeletion(for: meeting.id) else { continue }
            if [.pending, .processing].contains(meeting.transcriptionState),
               let retried = try? await retry(meetingID: meeting.id) {
                results.append(retried)
            } else if meeting.transcriptionState == .completed,
                      meeting.transcriptionAttemptCount > 0,
                      meeting.retainedAudio != nil,
                      meeting.uploadState == .notUploaded {
                scheduleUpload(meeting.id)
            }
        }
        return results
    }

    /// Launch recovery is intentionally cheap and finite. Interrupted jobs are
    /// made visible and retryable, but expensive speech work never resumes
    /// without the user's explicit Retry action.
    @discardableResult
    func reconcileInterruptedJobs(at date: Date = Date()) -> [MeetingRecord] {
        guard let entries = try? store.list() else { return [] }
        var reconciled = retention.reconcileInterruptedDeletions(in: entries)
        for entry in entries {
            if let meetingID = entry.id,
               retention.hasInterruptedDeletion(for: meetingID) {
                continue
            }
            if case .unavailable(let unavailable) = entry,
               unavailable.reason == .missingMeeting,
               let id = unavailable.id,
               let recovered = recoverOrphanedRecording(id: id, fallbackDate: date) {
                reconciled.append(recovered)
                continue
            }
            guard case .available(let listed) = entry,
                  !Self.registry.contains(key(for: listed.id)),
                  listed.audioRetentionState != .deleted else { continue }
            let interruptedCapture = [
                MeetingLifecycleState.starting,
                .recording,
                .paused,
                .stopSuggested,
                .finalizing,
            ].contains(listed.lifecycleState)
            let interruptedTranscript = [.pending, .processing]
                .contains(listed.transcriptionState)
            let missingArchive = listed.transcriptionState == .completed
                && listed.transcriptionAttemptCount > 0
                && listed.retainedAudio == nil
                && listed.audioRetentionState == .pending
            let interruptedArchive = missingArchive
                && Self.hasRecoverableSourceAudio(
                    in: store.directoryURL(for: listed.id),
                    fileManager: fileManagerBox.value
                )

            if interruptedCapture || interruptedTranscript || interruptedArchive {
                guard let stored = try? store.load(listed.id),
                      stored.meeting.audioRetentionState != .deleted else { continue }
                var meeting = stored.meeting
                meeting.endedAt = meeting.endedAt ?? date
                meeting.lifecycleState = interruptedCapture ? .failed : .completed
                meeting.transcriptionState = .failed
                meeting.transcriptionErrorMessage = if interruptedCapture {
                    "Brain stopped before this recording finished. Its local audio was preserved; retry the transcript when ready."
                } else if interruptedArchive {
                    "Brain stopped before this recording was archived. Its transcript and source audio were preserved; retry when ready."
                } else {
                    "Brain stopped before this transcript finished. Retry it when ready."
                }
                if (try? store.save(meeting, utterances: stored.utterances)) != nil {
                    reconciled.append(meeting)
                }
            } else if listed.transcriptionState == .completed,
                      listed.transcriptionAttemptCount > 0,
                      listed.retainedAudio != nil,
                      listed.uploadState == .notUploaded {
                scheduleUpload(listed.id)
            }
        }
        return reconciled
    }

    private func recoverOrphanedRecording(
        id: UUID,
        fallbackDate: Date
    ) -> MeetingRecord? {
        let directory = store.directoryURL(for: id)
        let attributes = try? fileManagerBox.value.attributesOfItem(atPath: directory.path)
        let recoveredAt = attributes?[.modificationDate] as? Date ?? fallbackDate
        let recovered = MeetingRecord(
            id: id,
            title: "Recovered recording",
            titleSource: .application,
            startedAt: recoveredAt,
            endedAt: recoveredAt,
            lifecycleState: .failed,
            speechEngine: SpeechEngineID.whisper.rawValue,
            speechModel: OnboardingController.defaultMeetingModelID,
            transcriptionState: .failed,
            transcriptionErrorMessage: "Brain recovered local audio from an interrupted recording. Retry the transcript when ready."
        )
        guard (try? Self.recoverCaptureFromRawPCM(
            meeting: recovered,
            directory: directory,
            fileManager: fileManagerBox.value
        )) != nil,
        (try? store.save(recovered, utterances: [])) != nil else {
            return nil
        }
        return recovered
    }

    private nonisolated static func persistFinalResult(
        meeting: MeetingRecord,
        capture: MeetingAudioCaptureSummary,
        utterances: [MeetingUtterance],
        failures: [LiveTranscriptFailure],
        store: MeetingStore,
        retention: AudioRetentionController
    ) -> MeetingTranscriptionPersistenceOutcome {
        guard let currentStored = currentProcessingGeneration(meeting, store: store) else {
            return MeetingTranscriptionPersistenceOutcome(
                meeting: currentRecord(for: meeting.id, fallback: meeting, store: store),
                shouldScheduleUpload: false
            )
        }
        var currentMeeting = currentStored.meeting
        currentMeeting.speechEngine = meeting.speechEngine
        currentMeeting.speechModel = meeting.speechModel
        let systemicFailures = failures.filter(\.isSystemic)
        guard systemicFailures.isEmpty && (utterances.isEmpty ? failures.isEmpty : true) else {
            let blockingFailures = systemicFailures.isEmpty ? failures : systemicFailures
            let message = blockingFailures.prefix(3)
                .map(Self.failureDescription)
                .joined(separator: " ")
            return MeetingTranscriptionPersistenceOutcome(
                meeting: persistFailureIfCurrent(
                    meeting: currentMeeting,
                    attemptUtterances: utterances,
                    message: message,
                    store: store
                ),
                shouldScheduleUpload: false
            )
        }

        var completed = currentMeeting
        completed.transcriptionState = .completed
        completed.transcriptionErrorMessage = failures.isEmpty
            ? nil
            : "Transcript completed with \(failures.count) skipped audio span\(failures.count == 1 ? "" : "s")."
        // A retry keeps the last durable analysis/upload state while it is in
        // flight. Only a newly committed transcript invalidates those results.
        completed.analysisState = .notRequested
        completed.uploadState = .notUploaded
        if currentMeeting.titleSource != .manual {
            completed.title = MeetingContextTitle.make(
                utterances: utterances,
                applicationName: currentMeeting.detectedApplication
            )
            completed.titleSource = utterances.isEmpty ? .application : .transcript
        }

        do {
            guard isCurrentProcessingGeneration(meeting, store: store) else {
                return MeetingTranscriptionPersistenceOutcome(
                    meeting: currentRecord(for: meeting.id, fallback: meeting, store: store),
                    shouldScheduleUpload: false
                )
            }
            let persisted = try retention.finalize(
                meeting: completed,
                utterances: utterances,
                audio: capture
            )
            return MeetingTranscriptionPersistenceOutcome(
                meeting: persisted,
                shouldScheduleUpload: true
            )
        } catch {
            if let committed = try? store.load(meeting.id),
               committed.meeting.transcriptionAttemptCount
                == meeting.transcriptionAttemptCount,
               committed.meeting.transcriptionState == .completed,
               committed.meeting.retainedAudio != nil {
                return MeetingTranscriptionPersistenceOutcome(
                    meeting: committed.meeting,
                    shouldScheduleUpload: true
                )
            }
            return MeetingTranscriptionPersistenceOutcome(
                meeting: persistFailureIfCurrent(
                    meeting: completed,
                    attemptUtterances: utterances,
                    message: Self.bounded(error),
                    store: store
                ),
                shouldScheduleUpload: false
            )
        }
    }

    private nonisolated static func persistFailureIfCurrent(
        meeting: MeetingRecord,
        attemptUtterances: [MeetingUtterance] = [],
        message: String,
        store: MeetingStore
    ) -> MeetingRecord {
        guard let current = try? store.load(meeting.id),
              current.meeting.transcriptionAttemptCount
                == meeting.transcriptionAttemptCount,
              current.meeting.transcriptionState == .processing
                || (
                    current.meeting.transcriptionState == .completed
                        && current.meeting.retainedAudio == nil
                        && current.meeting.audioRetentionState == .pending
                ) else {
            return currentRecord(for: meeting.id, fallback: meeting, store: store)
        }
        var failed = current.meeting
        failed.speechEngine = meeting.speechEngine
        failed.speechModel = meeting.speechModel
        failed.lifecycleState = .completed
        failed.transcriptionState = .failed
        failed.transcriptionErrorMessage = String(message.prefix(720))
        // A retry cannot replace a durable transcript until it succeeds. On an
        // initial attempt there is no prior transcript, so keep any successful
        // spans that were produced before a systemic failure.
        let durableUtterances = if meeting.transcriptionAttemptCount <= 1 {
            attemptUtterances.isEmpty ? current.utterances : attemptUtterances
        } else {
            current.utterances
        }
        do {
            try store.save(failed, utterances: durableUtterances)
            return failed
        } catch {
            return currentRecord(for: meeting.id, fallback: failed, store: store)
        }
    }

    private func isCurrentProcessingGeneration(_ meeting: MeetingRecord) -> Bool {
        Self.isCurrentProcessingGeneration(meeting, store: store)
    }

    private nonisolated static func isCurrentProcessingGeneration(
        _ meeting: MeetingRecord,
        store: MeetingStore
    ) -> Bool {
        currentProcessingGeneration(meeting, store: store) != nil
    }

    private nonisolated static func currentProcessingGeneration(
        _ meeting: MeetingRecord,
        store: MeetingStore
    ) -> StoredMeeting? {
        guard let stored = try? store.load(meeting.id) else { return nil }
        guard stored.meeting.transcriptionState == .processing,
              stored.meeting.transcriptionAttemptCount
                == meeting.transcriptionAttemptCount else {
            return nil
        }
        return stored
    }

    private func currentRecord(for id: UUID, fallback: MeetingRecord) -> MeetingRecord {
        Self.currentRecord(for: id, fallback: fallback, store: store)
    }

    private nonisolated static func currentRecord(
        for id: UUID,
        fallback: MeetingRecord,
        store: MeetingStore
    ) -> MeetingRecord {
        (try? store.load(id).meeting) ?? fallback
    }

    private func key(for meetingID: UUID) -> MeetingTranscriptionJobKey {
        MeetingTranscriptionJobKey(rootPath: store.rootURL.path, meetingID: meetingID)
    }

    private nonisolated static func loadOrRecoverCapture(
        meeting: MeetingRecord,
        directory: URL,
        fileManager: FileManager
    ) throws -> MeetingAudioCaptureSummary {
        do {
            return try loadCapture(directory: directory, fileManager: fileManager)
        } catch {
            do {
                return try recoverCaptureFromRetainedAudio(
                    meeting: meeting,
                    directory: directory,
                    fileManager: fileManager
                )
            } catch RetainedAudioRecoveryError.promotionFailed {
                // Canonical recovery files may have been replaced already.
                // Never reinterpret that partial transaction as authoritative
                // raw capture; the intact retained archive remains the source
                // for the next retry.
                throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
            } catch {
                return try recoverCaptureFromRawPCM(
                    meeting: meeting,
                    directory: directory,
                    fileManager: fileManager
                )
            }
        }
    }

    /// A process can disappear before the normal manifest commit. The writer's
    /// compact PCM tracks are still useful; reconstructing one conservative
    /// chunk per source makes that audio retryable without a checkpoint format.
    private nonisolated static func recoverCaptureFromRawPCM(
        meeting: MeetingRecord,
        directory: URL,
        fileManager: FileManager
    ) throws -> MeetingAudioCaptureSummary {
        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory,
              let directoryAttributes = try? fileManager.attributesOfItem(atPath: directory.path),
              directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == Darwin.geteuid(),
              ((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }

        var tracks: [MeetingAudioTrack] = []
        var chunks: [MeetingAudioChunk] = []
        for source in MeetingAudioSource.allCases {
            let url = directory.appendingPathComponent("\(source.rawValue).f32le.pcm")
                .standardizedFileURL
            if !fileManager.fileExists(atPath: url.path) {
                let empty = try createOwnerOnlyFile(at: url, fileManager: fileManager)
                try empty.close()
            }
            guard url.deletingLastPathComponent() == directory,
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == Darwin.geteuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size >= 0,
                  size % Int64(MemoryLayout<Float>.size) == 0 else {
                throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
            }
            let frames = size / Int64(MemoryLayout<Float>.size)
            tracks.append(MeetingAudioTrack(
                source: source,
                fileURL: url,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: frames
            ))
            if frames > 0, frames <= Int64(Int.max) {
                chunks.append(MeetingAudioChunk(
                    source: source,
                    timestampMilliseconds: 0,
                    sourceTimestamp: 0,
                    frameOffset: 0,
                    frameCount: Int(frames)
                ))
            }
        }
        guard !chunks.isEmpty else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        return try validatedManifest(
            MeetingAudioCaptureSummary(
                origin: meeting.startedAt,
                originHostTimestamp: 0,
                tracks: tracks,
                chunks: chunks,
                discontinuities: [],
                failures: []
            ),
            directory: directory,
            fileManager: fileManager
        )
    }

    private nonisolated static func loadCapture(
        directory: URL,
        fileManager: FileManager
    ) throws -> MeetingAudioCaptureSummary {
        let directory = directory.standardizedFileURL
        let manifest = directory.appendingPathComponent(MeetingAudioWriter.manifestFilename)
            .standardizedFileURL
        guard manifest.deletingLastPathComponent() == directory,
              manifest.resolvingSymlinksInPath().standardizedFileURL == manifest,
              let attributes = try? fileManager.attributesOfItem(atPath: manifest.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let capture = try decoder.decode(
                MeetingAudioCaptureSummary.self,
                from: Data(contentsOf: manifest)
            )
            return try validatedManifest(capture, directory: directory, fileManager: fileManager)
        } catch let error as MeetingTranscriptionCoordinatorError {
            throw error
        } catch {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
    }

    /// Distinguishes a recoverable archive crash from a legacy item or a
    /// recording the user explicitly deleted. This check is read-only: launch
    /// reconciliation must never manufacture recovery files for an item that
    /// intentionally has no audio.
    private nonisolated static func hasRecoverableSourceAudio(
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory,
              let directoryAttributes = try? fileManager.attributesOfItem(
                  atPath: directory.path
              ),
              directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value
                == Darwin.geteuid(),
              ((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                ?? 0o777) & 0o077 == 0 else {
            return false
        }

        if (try? loadCapture(directory: directory, fileManager: fileManager)) != nil {
            return true
        }

        return MeetingAudioSource.allCases.contains { source in
            let url = directory.appendingPathComponent("\(source.rawValue).f32le.pcm")
                .standardizedFileURL
            guard url.deletingLastPathComponent() == directory,
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
                    == Darwin.geteuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue
                    ?? 0o777) & 0o077 == 0,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                return false
            }
            return size > 0 && size % Int64(MemoryLayout<Float>.size) == 0
        }
    }

    @discardableResult
    private func validatedManifest(
        _ capture: MeetingAudioCaptureSummary,
        meetingID: UUID
    ) throws -> MeetingAudioCaptureSummary {
        try Self.validatedManifest(
            capture,
            directory: store.directoryURL(for: meetingID),
            fileManager: fileManagerBox.value
        )
    }

    private nonisolated static func validatedManifest(
        _ capture: MeetingAudioCaptureSummary,
        directory: URL,
        fileManager: FileManager
    ) throws -> MeetingAudioCaptureSummary {
        let directory = directory.standardizedFileURL
        guard capture.tracks.count == MeetingAudioSource.allCases.count,
              Set(capture.tracks.map(\.source)) == Set(MeetingAudioSource.allCases),
              !capture.chunks.isEmpty,
              capture.tracks.allSatisfy({ track in
                  let url = track.fileURL.standardizedFileURL
                  guard url.deletingLastPathComponent() == directory,
                        url.lastPathComponent == "\(track.source.rawValue).f32le.pcm",
                        url.resolvingSymlinksInPath().standardizedFileURL == url,
                        track.sampleRate == MeetingAudioWriter.sampleRate,
                        track.channelCount == MeetingAudioWriter.channelCount,
                        track.frameCount >= 0,
                        track.frameCount <= Int64.max / Int64(MemoryLayout<Float>.size),
                        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                  else { return false }
                  return attributes[.type] as? FileAttributeType == .typeRegular
                      && (attributes[.size] as? NSNumber)?.int64Value
                          == track.frameCount * Int64(MemoryLayout<Float>.size)
              }) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        let tracks = Dictionary(uniqueKeysWithValues: capture.tracks.map { ($0.source, $0) })
        guard capture.chunks.allSatisfy({ chunk in
            guard chunk.timestampMilliseconds >= 0,
                  chunk.frameOffset >= 0,
                  chunk.frameCount > 0,
                  let track = tracks[chunk.source] else {
                return false
            }
            return chunk.frameOffset <= track.frameCount
                && Int64(chunk.frameCount) <= track.frameCount - chunk.frameOffset
        }) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        return capture
    }

    private nonisolated static func recoverCaptureFromRetainedAudio(
        meeting: MeetingRecord,
        directory: URL,
        fileManager: FileManager
    ) throws -> MeetingAudioCaptureSummary {
        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory,
              let directoryAttributes = try? fileManager.attributesOfItem(
                  atPath: directory.path
              ),
              directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              let metadata = meeting.retainedAudio,
              AudioRetentionController.supports(metadata) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }

        let retainedURL = directory.appendingPathComponent(metadata.filename)
            .standardizedFileURL
        guard retainedURL.deletingLastPathComponent() == directory,
              retainedURL.resolvingSymlinksInPath().standardizedFileURL == retainedURL,
              let attributes = try? fileManager.attributesOfItem(atPath: retainedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == metadata.sizeBytes,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == Darwin.geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }

        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(
                forReading: retainedURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        let frameCount = audio.length
        guard audio.fileFormat.channelCount
                == AVAudioChannelCount(AudioRetentionController.channelCount),
              Int(audio.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate,
              audio.processingFormat.commonFormat == .pcmFormatFloat32,
              !audio.processingFormat.isInterleaved,
              frameCount > 0,
              frameCount <= AVAudioFramePosition(Int.max) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        let duration = Int64(
            (Double(frameCount) * 1_000 / Double(MeetingAudioWriter.sampleRate)).rounded()
        )
        guard abs(duration - metadata.durationMilliseconds) <= 1 else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }

        let recoveryID = UUID().uuidString
        let microphoneTemporary = directory.appendingPathComponent(
            ".recovery-\(recoveryID)-microphone.pcm"
        )
        let systemTemporary = directory.appendingPathComponent(
            ".recovery-\(recoveryID)-system.pcm"
        )
        let manifestTemporary = directory.appendingPathComponent(
            ".recovery-\(recoveryID)-manifest.json"
        )
        let temporaryURLs = [microphoneTemporary, systemTemporary, manifestTemporary]
        defer {
            for url in temporaryURLs where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }

        let microphone = try createOwnerOnlyFile(
            at: microphoneTemporary,
            fileManager: fileManager
        )
        let system: FileHandle
        do {
            system = try createOwnerOnlyFile(
                at: systemTemporary,
                fileManager: fileManager
            )
        } catch {
            try? microphone.close()
            throw error
        }
        var wroteNonzeroAudio = false
        do {
            var remaining = frameCount
            while remaining > 0 {
                let requested = AVAudioFrameCount(min(Int64(8_192), remaining))
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: audio.processingFormat,
                    frameCapacity: requested
                ) else {
                    throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
                }
                try audio.read(into: buffer, frameCount: requested)
                let count = Int(buffer.frameLength)
                guard count > 0,
                      let channels = buffer.floatChannelData else {
                    throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
                }
                for channel in 0..<AudioRetentionController.channelCount {
                    let values = UnsafeBufferPointer(start: channels[channel], count: count)
                    guard values.allSatisfy(\.isFinite) else {
                        throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
                    }
                    wroteNonzeroAudio = wroteNonzeroAudio || values.contains { $0 != 0 }
                    let data = Data(
                        bytes: channels[channel],
                        count: count * MemoryLayout<Float>.size
                    )
                    if channel == AudioRetentionController.microphoneChannel - 1 {
                        try microphone.write(contentsOf: data)
                    } else {
                        try system.write(contentsOf: data)
                    }
                }
                remaining -= AVAudioFramePosition(count)
            }
            guard wroteNonzeroAudio else {
                throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
            }
            try microphone.synchronize()
            try system.synchronize()
            try microphone.close()
            try system.close()
        } catch let error as MeetingTranscriptionCoordinatorError {
            try? microphone.close()
            try? system.close()
            throw error
        } catch {
            try? microphone.close()
            try? system.close()
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }

        let microphoneURL = directory.appendingPathComponent("microphone.f32le.pcm")
        let systemURL = directory.appendingPathComponent("system.f32le.pcm")
        let publicFrameCount = Int64(frameCount)
        let capture = MeetingAudioCaptureSummary(
            origin: meeting.startedAt,
            originHostTimestamp: 0,
            tracks: [
                MeetingAudioTrack(
                    source: .microphone,
                    fileURL: microphoneURL,
                    sampleRate: MeetingAudioWriter.sampleRate,
                    channelCount: MeetingAudioWriter.channelCount,
                    frameCount: publicFrameCount
                ),
                MeetingAudioTrack(
                    source: .system,
                    fileURL: systemURL,
                    sampleRate: MeetingAudioWriter.sampleRate,
                    channelCount: MeetingAudioWriter.channelCount,
                    frameCount: publicFrameCount
                ),
            ],
            chunks: [
                MeetingAudioChunk(
                    source: .microphone,
                    timestampMilliseconds: 0,
                    sourceTimestamp: 0,
                    frameOffset: 0,
                    frameCount: Int(publicFrameCount)
                ),
                MeetingAudioChunk(
                    source: .system,
                    timestampMilliseconds: 0,
                    sourceTimestamp: 0,
                    frameOffset: 0,
                    frameCount: Int(publicFrameCount)
                ),
            ],
            discontinuities: [],
            failures: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(capture)
        } catch {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        guard fileManager.createFile(
            atPath: manifestTemporary.path,
            contents: manifestData,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        do {
            let manifestHandle = try FileHandle(forWritingTo: manifestTemporary)
            try manifestHandle.synchronize()
            try manifestHandle.close()
            try replaceKnownRecoveryFile(
                microphoneTemporary,
                at: microphoneURL,
                fileManager: fileManager
            )
            try replaceKnownRecoveryFile(
                systemTemporary,
                at: systemURL,
                fileManager: fileManager
            )
            try replaceKnownRecoveryFile(
                manifestTemporary,
                at: directory.appendingPathComponent(MeetingAudioWriter.manifestFilename),
                fileManager: fileManager
            )
            return try validatedManifest(
                capture,
                directory: directory,
                fileManager: fileManager
            )
        } catch {
            throw RetainedAudioRecoveryError.promotionFailed
        }
    }

    private nonisolated static func createOwnerOnlyFile(
        at url: URL,
        fileManager: FileManager
    ) throws -> FileHandle {
        guard !fileManager.fileExists(atPath: url.path),
              fileManager.createFile(
                  atPath: url.path,
                  contents: nil,
                  attributes: [.posixPermissions: NSNumber(value: 0o600)]
              ) else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            return try FileHandle(forWritingTo: url)
        } catch {
            try? fileManager.removeItem(at: url)
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
    }

    private nonisolated static func replaceKnownRecoveryFile(
        _ source: URL,
        at destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  destination.resolvingSymlinksInPath().standardizedFileURL
                    == destination.standardizedFileURL else {
                throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
            }
        }
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw MeetingTranscriptionCoordinatorError.unsafeAudioManifest
        }
    }

    private nonisolated static func failureDescription(
        _ failure: LiveTranscriptFailure
    ) -> String {
        let source = failure.source == .microphone ? "Microphone" : "Computer audio"
        if let start = failure.startMilliseconds {
            return "\(source) transcription failed near \(start / 1_000)s: \(failure.message)"
        }
        return "\(source) transcription failed: \(failure.message)"
    }

    private nonisolated static func bounded(_ error: Error) -> String {
        String(error.localizedDescription.prefix(720))
    }
}

enum MeetingAudioCaptureQuality {
    struct Issue: Equatable, Sendable {
        let message: String
    }

    private static let minimumObservedDurationMilliseconds: Int64 = 8_000
    private static let maximumSparseCoverageRatio = 0.60
    private static let minimumRepeatedDropouts = 5
    private static let largeGapMilliseconds = Int64(
        (MeetingAudioDeliveryPolicy.largeGapThreshold * 1_000).rounded()
    )

    static func issue(in capture: MeetingAudioCaptureSummary) -> Issue? {
        if capture.failures.contains(where: {
            $0.source == .microphone && $0.reason == .interrupted
        }) {
            return Issue(message: interruptedMessage)
        }

        guard let microphone = diagnostics(for: .microphone, in: capture),
              microphone.observedDurationMilliseconds
                >= minimumObservedDurationMilliseconds,
              microphone.detectedDropoutCount >= minimumRepeatedDropouts,
              microphone.maximumInterBufferGapMilliseconds >= largeGapMilliseconds,
              microphone.coverageRatio < maximumSparseCoverageRatio else {
            return nil
        }
        let percent = Int((microphone.coverageRatio * 100).rounded())
        return Issue(message:
            "Microphone callback delivery was severely incomplete (about \(percent)% coverage with \(microphone.detectedDropoutCount) large gaps). Brain preserved the partial transcript and local audio instead of running final transcription over missing audio. Reconnect or power-cycle the microphone, then retry with a healthy recording."
        )
    }

    private static var interruptedMessage: String {
        "Microphone callback delivery was interrupted after its bounded recovery attempt. Brain preserved the partial transcript and local audio; reconnect or power-cycle the microphone before retrying."
    }

    private static func diagnostics(
        for source: MeetingAudioSource,
        in capture: MeetingAudioCaptureSummary
    ) -> MeetingAudioSourceDiagnostics? {
        if let persisted = capture.diagnostics?.sources.first(where: { $0.source == source }) {
            return persisted
        }

        let chunks = capture.chunks
            .filter { $0.source == source }
            .sorted { $0.timestampMilliseconds < $1.timestampMilliseconds }
        guard !chunks.isEmpty else { return nil }
        let delivered = chunks.reduce(Int64(0)) {
            $0 + Int64((Double($1.frameCount) * 1_000
                / Double(MeetingAudioWriter.sampleRate)).rounded())
        }
        let firstStart = chunks[0].timestampMilliseconds
        var priorEnd = firstStart
        var maximumGap: Int64 = 0
        var dropoutCount = 0
        for chunk in chunks {
            let gap = max(0, chunk.timestampMilliseconds - priorEnd)
            maximumGap = max(maximumGap, gap)
            if gap >= largeGapMilliseconds { dropoutCount += 1 }
            let duration = Int64((Double(chunk.frameCount) * 1_000
                / Double(MeetingAudioWriter.sampleRate)).rounded())
            priorEnd = max(priorEnd, chunk.timestampMilliseconds + duration)
        }
        let observed = max(delivered, priorEnd - firstStart)
        return MeetingAudioSourceDiagnostics(
            source: source,
            callbackCount: chunks.count,
            deliveredDurationMilliseconds: delivered,
            observedDurationMilliseconds: observed,
            coverageRatio: observed > 0 ? Double(delivered) / Double(observed) : 1,
            maximumInterBufferGapMilliseconds: maximumGap,
            detectedDropoutCount: dropoutCount,
            nativeSampleRate: nil,
            nativeChannelCount: nil
        )
    }
}

private struct MeetingTranscriptionPersistenceOutcome: Sendable {
    let meeting: MeetingRecord
    let shouldScheduleUpload: Bool
}

private final class MeetingTranscriptionFileManagerBox: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

private struct MeetingTranscriptionJobKey: Hashable {
    let rootPath: String
    let meetingID: UUID
}

@MainActor
private final class MeetingTranscriptionJobRegistry {
    struct Entry {
        let token: UUID
        let generation: Int
        let retrySnapshot: MeetingRecord?
        let task: Task<MeetingRecord, Never>
        let cancel: @MainActor () async -> Void
    }

    static let shared = MeetingTranscriptionJobRegistry()
    private var entries: [MeetingTranscriptionJobKey: Entry] = [:]
    private var deletionReservations: [MeetingTranscriptionJobKey: UUID] = [:]

    func contains(_ key: MeetingTranscriptionJobKey) -> Bool {
        entries[key] != nil || deletionReservations[key] != nil
    }

    func entry(for key: MeetingTranscriptionJobKey) -> Entry? {
        entries[key]
    }

    func install(_ entry: Entry, for key: MeetingTranscriptionJobKey) -> Bool {
        guard entries[key] == nil, deletionReservations[key] == nil else { return false }
        entries[key] = entry
        return true
    }

    func isCurrent(
        key: MeetingTranscriptionJobKey,
        token: UUID,
        generation: Int
    ) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.token == token && entry.generation == generation
    }

    func remove(key: MeetingTranscriptionJobKey, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries.removeValue(forKey: key)
    }

    func reserveDeletion(
        _ key: MeetingTranscriptionJobKey,
        replacingEntryWithToken entryToken: UUID?
    ) -> UUID? {
        guard deletionReservations[key] == nil else { return nil }
        if let entryToken {
            guard entries[key]?.token == entryToken else { return nil }
            entries.removeValue(forKey: key)
        } else {
            guard entries[key] == nil else { return nil }
        }
        let token = UUID()
        deletionReservations[key] = token
        return token
    }

    func hasDeletionReservation(_ key: MeetingTranscriptionJobKey) -> Bool {
        deletionReservations[key] != nil
    }

    func releaseDeletion(_ key: MeetingTranscriptionJobKey, token: UUID) {
        guard deletionReservations[key] == token else { return }
        deletionReservations.removeValue(forKey: key)
    }
}

@MainActor
private final class MeetingTranscriptionCancellationRelay {
    private var isCancelled = false
    private var action: (@MainActor () async -> Void)?

    func set(_ action: @escaping @MainActor () async -> Void) async {
        if isCancelled {
            await action()
        } else {
            self.action = action
        }
    }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        let action = action
        self.action = nil
        await action?()
    }
}
