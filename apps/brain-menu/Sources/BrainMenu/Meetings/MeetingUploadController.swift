import Foundation

enum MeetingUploadRetryMode: String, Codable, Equatable, Sendable {
    case post
    case poll
    case none
}

/// The exact durable revision used for delivery. Keeping the request itself,
/// rather than regenerating it for retry, prevents analysis or speaker edits
/// from silently changing an in-flight capture.
struct MeetingUploadRevision: Codable, Equatable, Sendable {
    let meetingID: UUID
    let revision: Int
    let transcriptDigest: String
    let idempotencyKey: UUID
    let request: BrainCaptureRequest
    var state: MeetingUploadState
    var captureID: String?
    var retryable: Bool
    var retryMode: MeetingUploadRetryMode
    var lastError: String?
    var updatedAt: Date
}

protocol MeetingUploadStoring: Sendable {
    func load(meetingID: UUID) throws -> MeetingUploadRevision?
    func save(_ revision: MeetingUploadRevision) throws
}

enum MeetingUploadStoreError: Error, Equatable, Sendable {
    case unsafePath
    case corruptState
    case mismatchedMeeting
    case writeFailed
}

/// Persists upload state beside `meeting.json`, `transcript.json`, and the
/// optional analysis. It stores Markdown only and never reads retained audio.
final class FileMeetingUploadStore: MeetingUploadStoring, @unchecked Sendable {
    static let filename = "upload.json"

    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(meetingID: UUID) throws -> MeetingUploadRevision? {
        try withLock {
            let url = stateURL(for: meetingID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            guard isRegularFile(url) else { throw MeetingUploadStoreError.unsafePath }
            let revision: MeetingUploadRevision
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                revision = try decoder.decode(
                    MeetingUploadRevision.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw MeetingUploadStoreError.corruptState
            }
            guard revision.meetingID == meetingID else {
                throw MeetingUploadStoreError.mismatchedMeeting
            }
            return revision
        }
    }

    func save(_ revision: MeetingUploadRevision) throws {
        do {
            try MeetingStore.withDeletionPrecedence(
                rootURL: rootURL,
                meetingID: revision.meetingID,
                fileManager: fileManager
            ) {
                try withLock {
                    let directory = rootURL
                        .appendingPathComponent(revision.meetingID.uuidString, isDirectory: true)
                    try ensurePrivateDirectory(rootURL)
                    try ensurePrivateDirectory(directory)
                    let destination = stateURL(for: revision.meetingID)
                    if fileManager.fileExists(atPath: destination.path), !isRegularFile(destination) {
                        throw MeetingUploadStoreError.unsafePath
                    }

                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .millisecondsSince1970
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data: Data
                    do {
                        data = try encoder.encode(revision)
                    } catch {
                        throw MeetingUploadStoreError.writeFailed
                    }

                    do {
                        try data.write(to: destination, options: .atomic)
                        try fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: 0o600)],
                            ofItemAtPath: destination.path
                        )
                    } catch {
                        throw MeetingUploadStoreError.writeFailed
                    }
                }
            }
        } catch let error as MeetingUploadStoreError {
            throw error
        } catch {
            throw MeetingUploadStoreError.writeFailed
        }
    }

    private func stateURL(for meetingID: UUID) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.filename, isDirectory: false)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MeetingUploadStoreError.unsafePath
            }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw MeetingUploadStoreError.writeFailed
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            throw MeetingUploadStoreError.writeFailed
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

enum MeetingUploadError: Error, Equatable, LocalizedError, Sendable {
    case transcriptNotFinal
    case oversizedTranscript
    case responseNotQueued
    case noRetryAvailable
    case noNewRevision

    var errorDescription: String? {
        switch self {
        case .transcriptNotFinal:
            "The meeting transcript is not final."
        case .oversizedTranscript:
            "Transcript must be 6 MiB or smaller."
        case .responseNotQueued:
            "Brain did not confirm that the meeting transcript was queued."
        case .noRetryAvailable:
            "This meeting upload cannot be retried."
        case .noNewRevision:
            "There is no changed meeting transcript to re-upload."
        }
    }
}

/// Coordinates final-transcript handoff to the durable capture API. The first
/// input is always reloaded from MeetingStore, proving final persistence before
/// rendering; callers cannot pass an in-memory partial transcript here.
@MainActor
final class MeetingUploadController {
    static let maximumRenderedBytes = 6 * 1_024 * 1_024
    static let pollingBackoff: [Duration] = [
        .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ]
    static let maximumPollAttempts = 8
    static let automaticRepublishAttempts = 1

    private(set) var currentRevision: MeetingUploadRevision?
    private(set) var uploadState: MeetingUploadState = .notUploaded
    private(set) var errorMessage: String?
    private(set) var hasPendingRevision = false

    var canRetry: Bool {
        currentRevision?.state == .failed && currentRevision?.retryable == true
    }

    var canReupload: Bool { hasPendingRevision }

    private let meetingStore: MeetingStore
    private let analysisStore: any MeetingAnalysisStoring
    private let uploadStore: any MeetingUploadStoring
    private let renderer: MeetingMarkdownRenderer
    private let apiProvider: @MainActor () -> (any BrainCaptureAPI)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    init(
        meetingStore: MeetingStore = MeetingStore(),
        analysisStore: any MeetingAnalysisStoring = FileMeetingAnalysisStore(),
        uploadStore: any MeetingUploadStoring = FileMeetingUploadStore(),
        renderer: MeetingMarkdownRenderer = MeetingMarkdownRenderer(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.meetingStore = meetingStore
        self.analysisStore = analysisStore
        self.uploadStore = uploadStore
        self.renderer = renderer
        self.sleep = sleep
        self.now = now
        apiProvider = { BrainRuntime.captureClient() }
    }

    init(
        meetingStore: MeetingStore,
        analysisStore: any MeetingAnalysisStoring,
        uploadStore: any MeetingUploadStoring,
        api: any BrainCaptureAPI,
        renderer: MeetingMarkdownRenderer = MeetingMarkdownRenderer(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.meetingStore = meetingStore
        self.analysisStore = analysisStore
        self.uploadStore = uploadStore
        self.renderer = renderer
        self.sleep = sleep
        self.now = now
        apiProvider = { api }
    }

    init(
        meetingStore: MeetingStore,
        analysisStore: any MeetingAnalysisStoring,
        uploadStore: any MeetingUploadStoring,
        apiProvider: @escaping @MainActor () -> (any BrainCaptureAPI)?,
        renderer: MeetingMarkdownRenderer = MeetingMarkdownRenderer(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.meetingStore = meetingStore
        self.analysisStore = analysisStore
        self.uploadStore = uploadStore
        self.apiProvider = apiProvider
        self.renderer = renderer
        self.sleep = sleep
        self.now = now
    }

    /// Creates and submits the first revision only after loading the completed
    /// transcript from its atomic MeetingStore persistence. A changed document
    /// is detected but never replaces a prior revision through this automatic
    /// path; it waits for `reupload(meetingID:)`.
    func uploadAfterFinalTranscriptPersistence(meetingID: UUID) async {
        do {
            let candidate = try makeCandidate(meetingID: meetingID)
            if let existing = try uploadStore.load(meetingID: meetingID) {
                setCurrent(existing)
                guard existing.transcriptDigest != candidate.transcriptDigest else {
                    switch existing.state {
                    case .queued, .delivering:
                        if let captureID = existing.captureID,
                           let api = apiProvider() {
                            await poll(captureID: captureID, revision: existing, api: api)
                        } else if existing.captureID == nil {
                            await post(existing)
                        }
                    case .notUploaded, .delivered, .failed:
                        break
                    }
                    return
                }

                // The existing body and key remain immutable. The UI can now
                // offer an explicit Re-upload action for the new content.
                hasPendingRevision = true
                errorMessage = nil
                return
            }

            try persist(candidate)
            await post(candidate)
        } catch {
            recordLocalFailure(error)
        }
    }

    /// Rebuilds the current persisted transcript only after an explicit user
    /// action and assigns it the next durable revision number.
    func reupload(meetingID: UUID) async {
        do {
            let existing = try uploadStore.load(meetingID: meetingID)
            var candidate = try makeCandidate(meetingID: meetingID)
            guard existing?.transcriptDigest != candidate.transcriptDigest else {
                throw MeetingUploadError.noNewRevision
            }
            candidate = MeetingUploadRevision(
                meetingID: candidate.meetingID,
                revision: (existing?.revision ?? 0) + 1,
                transcriptDigest: candidate.transcriptDigest,
                idempotencyKey: candidate.idempotencyKey,
                request: candidate.request,
                state: .queued,
                captureID: nil,
                retryable: false,
                retryMode: .post,
                lastError: nil,
                updatedAt: now()
            )
            hasPendingRevision = false
            try persist(candidate)
            await post(candidate)
        } catch {
            recordLocalFailure(error)
        }
    }

    /// Retries the persisted body, never a fresh rendering. A failed poll
    /// resumes with GET; a retryable server/POST failure reuses the original
    /// POST body and idempotency key.
    func retry(meetingID: UUID) async {
        do {
            let revision = try requireRevision(meetingID: meetingID)
            setCurrent(revision)
            guard revision.state == .failed, revision.retryable else {
                throw MeetingUploadError.noRetryAvailable
            }
            switch revision.retryMode {
            case .post:
                await post(revision)
            case .poll:
                guard let captureID = revision.captureID,
                      let api = apiProvider() else {
                    throw BrainAPIError.notPaired
                }
                await poll(captureID: captureID, revision: revision, api: api)
            case .none:
                throw MeetingUploadError.noRetryAvailable
            }
        } catch {
            recordLocalFailure(error)
        }
    }

    /// Restores visible state after relaunch and resumes remote monitoring. An
    /// accepted capture is polled by ID and is never POSTed again.
    func resume(meetingID: UUID) async {
        do {
            let revision = try requireRevision(meetingID: meetingID)
            setCurrent(revision)
            guard [.queued, .delivering].contains(revision.state) else { return }
            if let captureID = revision.captureID {
                guard let api = apiProvider() else { throw BrainAPIError.notPaired }
                await poll(captureID: captureID, revision: revision, api: api)
            } else {
                await post(revision)
            }
        } catch {
            recordLocalFailure(error)
        }
    }

    func persistedRevision(meetingID: UUID) throws -> MeetingUploadRevision? {
        try uploadStore.load(meetingID: meetingID)
    }

    private func makeCandidate(meetingID: UUID) throws -> MeetingUploadRevision {
        let stored = try meetingStore.load(meetingID)
        guard stored.meeting.lifecycleState == .completed,
              stored.meeting.transcriptionState == .completed else {
            throw MeetingUploadError.transcriptNotFinal
        }
        // Missing, failed, or corrupt analysis can never prevent preservation
        // of the final raw transcript.
        let analysis = try? analysisStore.load(meetingID: meetingID)
        let markdown = renderer.render(
            meeting: stored.meeting,
            utterances: stored.utterances,
            storedAnalysis: analysis
        )
        guard markdown.lengthOfBytes(using: .utf8) <= Self.maximumRenderedBytes else {
            throw MeetingUploadError.oversizedTranscript
        }

        let digest = MeetingMarkdownRenderer.transcriptDigest(markdown)
        let key = MeetingMarkdownRenderer.stableIdempotencyKey(
            meetingID: meetingID,
            transcriptDigest: digest
        )
        return MeetingUploadRevision(
            meetingID: meetingID,
            revision: 1,
            transcriptDigest: digest,
            idempotencyKey: key,
            request: BrainCaptureRequest(
                type: .transcript,
                source: MeetingMarkdownRenderer.captureSource,
                transcript: markdown,
                title: MeetingMarkdownRenderer.filenameSafeTitle(stored.meeting.title)
            ),
            state: .queued,
            captureID: nil,
            retryable: false,
            retryMode: .post,
            lastError: nil,
            updatedAt: now()
        )
    }

    private func requireRevision(meetingID: UUID) throws -> MeetingUploadRevision {
        guard let revision = try uploadStore.load(meetingID: meetingID) else {
            throw MeetingUploadError.noRetryAvailable
        }
        return revision
    }

    private func post(
        _ original: MeetingUploadRevision,
        automaticRepublishesRemaining: Int = MeetingUploadController.automaticRepublishAttempts
    ) async {
        var revision = original
        var acceptedThisAttempt = false
        do {
            guard let api = apiProvider() else { throw BrainAPIError.notPaired }
            // A retryable server failure may carry the old failed capture ID.
            // Clear it before persisting the new POST attempt so a relaunch
            // cannot mistake that terminal ID for an accepted retry.
            revision.captureID = nil
            revision.state = .queued
            revision.retryable = false
            revision.retryMode = .post
            revision.lastError = nil
            revision.updatedAt = now()
            try persist(revision)

            let receipt = try await api.capture(
                revision.request,
                idempotencyKey: revision.idempotencyKey
            )
            guard receipt.state == "queued" else {
                throw MeetingUploadError.responseNotQueued
            }

            revision.captureID = receipt.id
            acceptedThisAttempt = true
            revision.state = .queued
            revision.retryable = false
            revision.retryMode = .poll
            revision.lastError = nil
            revision.updatedAt = now()
            try persist(revision)
            await poll(
                captureID: receipt.id,
                revision: revision,
                api: api,
                automaticRepublishesRemaining: automaticRepublishesRemaining
            )
        } catch is CancellationError {
            return
        } catch {
            revision.state = .failed
            revision.retryable = Self.isRetryable(error)
            revision.retryMode = revision.retryable
                ? (acceptedThisAttempt ? .poll : .post)
                : .none
            revision.lastError = Self.boundedError(error)
            revision.updatedAt = now()
            try? persist(revision)
            setCurrent(revision)
        }
    }

    private func poll(
        captureID: String,
        revision original: MeetingUploadRevision,
        api: any BrainCaptureAPI,
        automaticRepublishesRemaining: Int = MeetingUploadController.automaticRepublishAttempts
    ) async {
        var revision = original
        var attempt = 0
        while !Task.isCancelled {
            do {
                let delay = Self.pollingBackoff[min(attempt, Self.pollingBackoff.count - 1)]
                attempt += 1
                try await sleep(delay)
                let status = try await api.captureStatus(id: captureID)
                guard status.id == captureID else { throw BrainAPIError.invalidResponse }

                switch status.state {
                case .queued:
                    revision.state = .queued
                    revision.retryable = false
                    revision.retryMode = .poll
                    revision.lastError = nil
                case .processing:
                    revision.state = .delivering
                    revision.retryable = false
                    revision.retryMode = .poll
                    revision.lastError = nil
                case .delivered:
                    revision.state = .delivered
                    revision.retryable = false
                    revision.retryMode = .none
                    revision.lastError = nil
                case .failed:
                    revision.state = .failed
                    revision.retryable = status.retryable
                    revision.retryMode = status.retryable ? .post : .none
                    revision.lastError = status.error ?? "Meeting transcript delivery failed."
                }
                revision.captureID = captureID
                revision.updatedAt = now()
                try persist(revision)

                if status.state == .delivered || status.state == .failed { return }
                if attempt >= Self.maximumPollAttempts {
                    revision.state = .failed
                    revision.retryable = true
                    revision.retryMode = .post
                    revision.lastError = "Brain did not complete meeting delivery within the expected time."
                    revision.updatedAt = now()
                    try persist(revision)
                    if automaticRepublishesRemaining > 0 {
                        await post(
                            revision,
                            automaticRepublishesRemaining: automaticRepublishesRemaining - 1
                        )
                    }
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                revision.state = .failed
                revision.retryable = Self.isRetryable(error)
                revision.retryMode = revision.retryable ? .poll : .none
                revision.captureID = captureID
                revision.lastError = Self.boundedError(error)
                revision.updatedAt = now()
                try? persist(revision)
                setCurrent(revision)
                return
            }
        }
    }

    private func persist(_ revision: MeetingUploadRevision) throws {
        try uploadStore.save(revision)

        // Keep the established MeetingRecord state in sync for normal meeting
        // list rendering. Upload JSON remains the source of exact retry data.
        let stored = try meetingStore.load(revision.meetingID)
        if stored.meeting.uploadState != revision.state {
            var meeting = stored.meeting
            meeting.uploadState = revision.state
            try meetingStore.save(meeting, utterances: stored.utterances)
        }
        setCurrent(revision)
    }

    private func setCurrent(_ revision: MeetingUploadRevision) {
        currentRevision = revision
        uploadState = revision.state
        errorMessage = revision.lastError
        if revision.state == .delivered {
            // A fresh comparison is performed when the meeting is next loaded;
            // delivery itself never infers that local content changed.
            hasPendingRevision = false
        }
    }

    private func recordLocalFailure(_ error: Error) {
        errorMessage = error.localizedDescription
        if currentRevision == nil {
            uploadState = .failed
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let apiError = error as? BrainAPIError else { return false }
        return switch apiError {
        case .transport, .timedOut, .notPaired, .credentialUnavailable:
            true
        case .http(let status, _, _, _):
            (500...599).contains(status)
        default:
            false
        }
    }

    private static func boundedError(_ error: Error) -> String {
        String(error.localizedDescription.prefix(512))
    }

}
