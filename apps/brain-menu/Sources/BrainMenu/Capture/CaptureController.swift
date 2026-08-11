import AppKit
import Foundation
import Observation

protocol BrainCaptureAPI: Sendable {
    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt
    func captureStatus(id: String) async throws -> BrainCaptureStatus
    func captureList() async throws -> BrainCaptureListResponse
}

private struct CaptureStatusUnavailable: Error {}
private struct CaptureListUnavailable: Error {}

extension BrainCaptureAPI {
    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        throw CaptureStatusUnavailable()
    }

    func captureList() async throws -> BrainCaptureListResponse {
        throw CaptureListUnavailable()
    }
}

enum CaptureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case note
    case link
    case image
    case transcript

    var id: Self { self }

    var title: String {
        switch self {
        case .note: "Note"
        case .link: "Link"
        case .image: "Image"
        case .transcript: "Transcript"
        }
    }
}

enum CaptureActivityStage: String, Codable, Equatable, Sendable {
    case sending
    case queued
    case delivering
    case delivered
    case needsAttention
}

struct CaptureActivityRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var captureID: String?
    let kind: CaptureKind?
    let label: String
    var source: String?
    let createdAt: Date
    var updatedAt: Date
    var stage: CaptureActivityStage
    var error: String?
}

struct CaptureImagePayload: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let filename: String?
}

struct CaptureDraft: Equatable, Sendable {
    var kind: CaptureKind = .note
    var noteText = ""
    var url = ""
    var comment = ""
    var selectedText = ""
    var image: CaptureImagePayload?
    var imageContext = ""
    var transcriptText = ""
    var transcriptFilename: String?

    static func empty(kind: CaptureKind) -> Self {
        var draft = Self()
        draft.kind = kind
        return draft
    }
}

enum CaptureSubmissionState: Equatable, Sendable {
    case idle
    case sending
    case retrying
    case queued(id: String)
    case delivering(id: String)
    case delivered(id: String)
    case retryAvailable(id: String)
    case needsAttention(id: String)
    case failed
}

enum CaptureValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyNote
    case emptyURL
    case invalidURL
    case missingImage
    case unsupportedImageType
    case invalidImageData
    case oversizedEncodedImage
    case oversizedDecodedImage
    case missingImageContext
    case unsupportedTranscript
    case emptyTranscript
    case oversizedTranscript
    case responseNotQueued

    var errorDescription: String? {
        switch self {
        case .emptyNote:
            "Enter note text before sending."
        case .emptyURL:
            "Enter a URL before sending."
        case .invalidURL:
            "Enter a valid HTTP or HTTPS URL."
        case .missingImage:
            "Choose or drop a JPEG, PNG, or WebP image."
        case .unsupportedImageType:
            "Image must be JPEG, PNG, or WebP."
        case .invalidImageData:
            "Image data does not match its declared format."
        case .oversizedEncodedImage:
            "Encoded image must be 6 MiB or smaller."
        case .oversizedDecodedImage:
            "Image must be 4 MiB or smaller."
        case .missingImageContext:
            "Add searchable context for this design image."
        case .unsupportedTranscript:
            "Transcript must be a .md or .txt file."
        case .emptyTranscript:
            "Transcript must not be empty."
        case .oversizedTranscript:
            "Transcript must be 6 MiB or smaller."
        case .responseNotQueued:
            "Brain did not confirm that the capture was queued."
        }
    }
}

@MainActor
protocol CaptureClipboardReading: AnyObject {
    func readText() -> String?
    func readImage() -> CaptureImagePayload?
}

@MainActor
final class SystemCaptureClipboard: CaptureClipboardReading {
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func readImage() -> CaptureImagePayload? {
        let pasteboard = NSPasteboard.general
        let directTypes: [(NSPasteboard.PasteboardType, String, String)] = [
            (.png, "image/png", "clipboard.png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg", "clipboard.jpg"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "image/webp", "clipboard.webp"),
        ]
        for (type, mimeType, filename) in directTypes {
            if let data = pasteboard.data(forType: type) {
                return CaptureImagePayload(data: data, mimeType: mimeType, filename: filename)
            }
        }

        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        return CaptureImagePayload(data: png, mimeType: "image/png", filename: "clipboard.png")
    }
}

@MainActor
@Observable
final class CaptureController {
    static let maximumEncodedImageBytes = 6 * 1_024 * 1_024
    static let maximumDecodedImageBytes = 4 * 1_024 * 1_024
    static let maximumTranscriptBytes = 6 * 1_024 * 1_024
    static let source = "Brain.app"
    static let monitorDefaultsKey = "brain.capture.active-monitor.v1"
    static let activityDefaultsKey = "brain.capture.activity.v1"
    static let dismissedActivityDefaultsKey = "brain.capture.activity-dismissed.v1"
    static let maximumActivityRecords = 100
    static let pollingBackoff: [Duration] = [
        .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ]

    var draft = CaptureDraft() {
        didSet {
            guard draft != oldValue else { return }
            guard !isClearingDeliveredDraft else { return }
            draftRevision &+= 1
            guard !isSubmitting else { return }
            pendingSubmission = nil
            if submissionState != .idle {
                submissionState = .idle
                errorMessage = nil
                queuedReceipt = nil
            }
        }
    }

    private(set) var observedSubmissionStates: [CaptureSubmissionState] = []
    private(set) var submissionState: CaptureSubmissionState = .idle {
        didSet {
            if submissionState != oldValue {
                observedSubmissionStates.append(submissionState)
            }
        }
    }
    private(set) var errorMessage: String?
    private(set) var queuedReceipt: BrainCaptureReceipt?
    private(set) var isSubmitting = false
    private(set) var activeMonitor: CaptureMonitor?
    private(set) var activities: [CaptureActivityRecord]

    var canRetry: Bool {
        guard pendingSubmission != nil, !isSubmitting else { return false }
        if case .retryAvailable = submissionState { return true }
        return false
    }

    var canSubmit: Bool {
        guard pendingSubmission == nil, !isSubmitting else { return false }
        switch submissionState {
        case .idle, .failed, .needsAttention:
            return true
        case .sending, .retrying, .queued, .delivering,
             .delivered, .retryAvailable:
            return false
        }
    }

    @ObservationIgnored private let apiProvider: @MainActor () -> (any BrainCaptureAPI)?
    @ObservationIgnored private let clipboard: any CaptureClipboardReading
    @ObservationIgnored private let makeUUID: () -> UUID
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let monitorStore: CaptureMonitorStore
    @ObservationIgnored private let activityStore: CaptureActivityStore
    @ObservationIgnored private var pendingSubmission: PendingSubmission?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var activityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryHandler: (@MainActor @Sendable (String) -> Void)?
    @ObservationIgnored private var notifiedDeliveries = Set<String>()
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var isClearingDeliveredDraft = false

    init(
        clipboard: any CaptureClipboardReading = SystemCaptureClipboard(),
        makeUUID: @escaping () -> UUID = UUID.init,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.clipboard = clipboard
        self.makeUUID = makeUUID
        self.sleep = sleep
        self.now = now
        monitorStore = CaptureMonitorStore(defaults: defaults)
        activityStore = CaptureActivityStore(defaults: defaults)
        activities = activityStore.load()
        apiProvider = { BrainRuntime.captureClient() }
        restoreMonitor()
        startActivityRefresh(excluding: activeMonitor?.id)
    }

    init(
        api: any BrainCaptureAPI,
        clipboard: any CaptureClipboardReading = SystemCaptureClipboard(),
        makeUUID: @escaping () -> UUID = UUID.init,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.clipboard = clipboard
        self.makeUUID = makeUUID
        self.sleep = sleep
        self.now = now
        monitorStore = CaptureMonitorStore(defaults: defaults)
        activityStore = CaptureActivityStore(defaults: defaults)
        activities = activityStore.load()
        apiProvider = { api }
        restoreMonitor()
        startActivityRefresh(excluding: activeMonitor?.id)
    }

    init(
        apiProvider: @escaping @MainActor () -> (any BrainCaptureAPI)?,
        clipboard: any CaptureClipboardReading = SystemCaptureClipboard(),
        makeUUID: @escaping () -> UUID = UUID.init,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.apiProvider = apiProvider
        self.clipboard = clipboard
        self.makeUUID = makeUUID
        self.sleep = sleep
        self.now = now
        monitorStore = CaptureMonitorStore(defaults: defaults)
        activityStore = CaptureActivityStore(defaults: defaults)
        activities = activityStore.load()
        restoreMonitor()
        startActivityRefresh(excluding: activeMonitor?.id)
    }

    /// Reads the system pasteboard only when called by the Paste button.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        switch draft.kind {
        case .note:
            guard let text = clipboard.readText() else { return false }
            draft.noteText = text
        case .link:
            guard let text = clipboard.readText() else { return false }
            if draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.url = text
            } else {
                draft.selectedText = text
            }
        case .image:
            guard let image = clipboard.readImage() else { return false }
            draft.image = image
        case .transcript:
            guard let text = clipboard.readText() else { return false }
            draft.transcriptText = text
            draft.transcriptFilename = "Pasted transcript.txt"
        }
        return true
    }

    /// Called only from the view's explicit drag/drop handler.
    func acceptDroppedImage(data: Data, mimeType: String, filename: String? = nil) {
        draft.kind = .image
        draft.image = CaptureImagePayload(data: data, mimeType: mimeType, filename: filename)
    }

    /// Called only after the user chooses a transcript in the file importer.
    func loadTranscript(from fileURL: URL) {
        do {
            let filename = fileURL.lastPathComponent
            guard Self.isSupportedTranscript(filename: filename) else {
                throw CaptureValidationError.unsupportedTranscript
            }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { fileURL.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumTranscriptBytes else {
                throw CaptureValidationError.oversizedTranscript
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CaptureValidationError.unsupportedTranscript
            }
            draft.kind = .transcript
            draft.transcriptText = text
            draft.transcriptFilename = filename
            errorMessage = nil
        } catch {
            pendingSubmission = nil
            errorMessage = error.localizedDescription
            submissionState = .failed
        }
    }

    /// Called only after the user chooses an image in the file importer.
    func loadImage(from fileURL: URL) {
        do {
            guard let mimeType = Self.imageMIMEType(for: fileURL) else {
                throw CaptureValidationError.unsupportedImageType
            }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { fileURL.stopAccessingSecurityScopedResource() }
            }
            acceptDroppedImage(
                data: try Data(contentsOf: fileURL, options: .mappedIfSafe),
                mimeType: mimeType,
                filename: fileURL.lastPathComponent
            )
            errorMessage = nil
        } catch {
            pendingSubmission = nil
            errorMessage = error.localizedDescription
            submissionState = .failed
        }
    }

    func submit() async {
        guard canSubmit else { return }
        do {
            let request = try validatedRequest()
            let idempotencyKey = makeUUID()
            let pending = PendingSubmission(
                request: request,
                idempotencyKey: idempotencyKey,
                draftRevision: draftRevision,
                activityID: addActivity(for: draft, idempotencyKey: idempotencyKey)
            )
            pendingSubmission = pending
            await deliver(pending, automaticallyRetry: true)
        } catch {
            pendingSubmission = nil
            queuedReceipt = nil
            submissionState = .failed
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        guard canRetry, let pendingSubmission else { return }
        await deliver(pendingSubmission, automaticallyRetry: false)
    }

    /// Refreshes the persisted capture immediately without submitting its body again.
    func checkAgain() {
        if activeMonitor != nil { startMonitoring(immediately: true) }
        startActivityRefresh(excluding: activeMonitor?.id)
    }

    func setDeliveryHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        deliveryHandler = handler
    }

    func clearCompletedActivity() {
        activityStore.dismiss(activities.compactMap { record in
            record.stage == .delivered ? record.captureID : nil
        })
        activities.removeAll { $0.stage == .delivered }
        activityStore.save(activities)
    }

    /// Test synchronization for finite fake status sequences.
    func waitForMonitoring() async {
        await monitorTask?.value
        await activityRefreshTask?.value
    }

    func validatedRequest() throws -> BrainCaptureRequest {
        switch draft.kind {
        case .note:
            guard !draft.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptureValidationError.emptyNote
            }
            return BrainCaptureRequest(
                type: .note,
                text: draft.noteText,
                source: Self.source
            )

        case .link:
            let url = try Self.validatedURL(draft.url)
            return BrainCaptureRequest(
                url: url,
                text: Self.nonblank(draft.selectedText),
                note: Self.nonblank(draft.comment),
                source: Self.source
            )

        case .image:
            guard let image = draft.image else { throw CaptureValidationError.missingImage }
            guard !draft.imageContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptureValidationError.missingImageContext
            }
            let dataURL = try Self.validatedImageDataURL(image)
            return BrainCaptureRequest(
                type: .design,
                text: draft.imageContext,
                source: Self.source,
                image: dataURL
            )

        case .transcript:
            guard let filename = draft.transcriptFilename,
                  Self.isSupportedTranscript(filename: filename) else {
                throw CaptureValidationError.unsupportedTranscript
            }
            guard !draft.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptureValidationError.emptyTranscript
            }
            guard draft.transcriptText.lengthOfBytes(using: .utf8) <= Self.maximumTranscriptBytes else {
                throw CaptureValidationError.oversizedTranscript
            }
            return BrainCaptureRequest(
                type: .transcript,
                source: Self.source,
                transcript: draft.transcriptText,
                title: filename
            )
        }
    }

    private func deliver(_ pending: PendingSubmission, automaticallyRetry: Bool) async {
        isSubmitting = true
        queuedReceipt = nil
        errorMessage = nil
        submissionState = automaticallyRetry ? .sending : .retrying
        updateActivity(
            activityID: pending.activityID,
            captureID: nil,
            stage: .sending,
            error: nil
        )
        defer { isSubmitting = false }

        let attempts = automaticallyRetry ? 2 : 1
        for attempt in 0..<attempts {
            do {
                guard let api = apiProvider() else { throw LocalBrainError.notInitialized }
                let receipt = try await api.capture(
                    pending.request,
                    idempotencyKey: pending.idempotencyKey
                )
                guard receipt.state == "queued" else {
                    throw CaptureValidationError.responseNotQueued
                }

                queuedReceipt = receipt
                submissionState = .queued(id: receipt.id)
                updateActivity(
                    activityID: pending.activityID,
                    captureID: receipt.id,
                    stage: .queued,
                    error: nil
                )
                errorMessage = nil
                let monitor = CaptureMonitor(
                    id: receipt.id,
                    startedAt: now(),
                    lastState: .queued,
                    lastError: nil
                )
                activeMonitor = monitor
                monitorStore.save(monitor)
                clearDeliveredDraft(for: pending)
                // HTTP 202 is the submission boundary. Polling is app-lifetime
                // work and must not keep a form or floating panel busy.
                isSubmitting = false
                startMonitoring(api: api)
                startActivityRefresh(excluding: receipt.id, api: api)
                await Task.yield()
                return
            } catch is CancellationError {
                pendingSubmission = nil
                updateActivity(
                    activityID: pending.activityID,
                    captureID: nil,
                    stage: .needsAttention,
                    error: "Capture sending was cancelled before delivery was confirmed."
                )
                return
            } catch {
                if attempt + 1 < attempts, Self.isAutomaticallyRetryable(error) {
                    submissionState = .retrying
                    await Task.yield()
                    continue
                }
                pendingSubmission = nil
                submissionState = .failed
                errorMessage = error.localizedDescription
                updateActivity(
                    activityID: pending.activityID,
                    captureID: nil,
                    stage: .needsAttention,
                    error: error.localizedDescription
                )
                return
            }
        }
    }

    private func startMonitoring(
        api suppliedAPI: (any BrainCaptureAPI)? = nil,
        immediately: Bool = false
    ) {
        guard let monitor = activeMonitor else { return }
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            let api = suppliedAPI ?? self.apiProvider()
            guard let api else {
                self.errorMessage = LocalBrainError.notInitialized.localizedDescription
                return
            }
            await self.pollStatus(monitor.id, api: api, immediately: immediately)
        }
    }

    private func startActivityRefresh(
        excluding excludedCaptureID: String?,
        api suppliedAPI: (any BrainCaptureAPI)? = nil
    ) {
        let fallbackCaptureIDs = activities.compactMap { record -> String? in
            guard record.stage == .queued || record.stage == .delivering,
                  let captureID = record.captureID,
                  captureID != excludedCaptureID else { return nil }
            return captureID
        }
        activityRefreshTask?.cancel()
        activityRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard let api = suppliedAPI ?? self.apiProvider() else { return }
            var listedCaptureIDs = Set<String>()
            do {
                let response = try await api.captureList()
                for capture in response.captures {
                    listedCaptureIDs.insert(capture.id)
                    self.mergeActivity(capture)
                }
                self.persistActivities()
            } catch is CaptureListUnavailable {
                // Older/focused API implementations can still refresh known IDs.
            } catch is CancellationError {
                return
            } catch {
                // Keep local metadata. A later refresh can merge current activity.
            }

            for captureID in fallbackCaptureIDs
            where !listedCaptureIDs.contains(captureID) && !Task.isCancelled {
                do {
                    let status = try await api.captureStatus(id: captureID)
                    guard status.id == captureID else {
                        self.updateActivity(
                            captureID: captureID,
                            stage: .needsAttention,
                            error: LocalBrainError.invalidOutput.localizedDescription
                        )
                        continue
                    }
                    switch status.state {
                    case .queued:
                        self.updateActivity(
                            captureID: captureID,
                            stage: .queued,
                            error: status.error
                        )
                    case .processing:
                        self.updateActivity(
                            captureID: captureID,
                            stage: .delivering,
                            error: status.error
                        )
                    case .delivered:
                        self.updateActivity(
                            captureID: captureID,
                            stage: .delivered,
                            error: nil
                        )
                    case .failed:
                        self.updateActivity(
                            captureID: captureID,
                            stage: .needsAttention,
                            error: status.error ?? "Capture delivery needs attention."
                        )
                    }
                } catch is CaptureStatusUnavailable {
                    continue
                } catch is CancellationError {
                    return
                } catch {
                    // Keep an accepted capture in its last confirmed state.
                    // A later refresh can recheck it without resubmitting.
                    continue
                }
            }
        }
    }

    private func mergeActivity(_ status: BrainCaptureStatus) {
        guard !activityStore.isDismissed(status.id) else { return }
        let stage = Self.activityStage(for: status)
        let error = stage == .needsAttention
            ? status.error ?? "Capture delivery needs attention."
            : status.error
        if let index = activities.firstIndex(where: { $0.captureID == status.id }) {
            activities[index].source = Self.nonblank(status.source ?? "")
                ?? activities[index].source
            activities[index].updatedAt = status.updatedAt
            activities[index].stage = stage
            activities[index].error = error
            return
        }

        activities.append(CaptureActivityRecord(
            id: status.id,
            captureID: status.id,
            kind: Self.activityKind(for: status),
            label: Self.activityLabel(for: status),
            source: Self.nonblank(status.source ?? ""),
            createdAt: status.createdAt,
            updatedAt: status.updatedAt,
            stage: stage,
            error: error
        ))
        activities.sort {
            if $0.createdAt == $1.createdAt { return $0.id > $1.id }
            return $0.createdAt > $1.createdAt
        }
    }

    private static func activityStage(for status: BrainCaptureStatus) -> CaptureActivityStage {
        switch status.state {
        case .queued: .queued
        case .processing: .delivering
        case .delivered: .delivered
        case .failed: .needsAttention
        }
    }

    private static func activityKind(for status: BrainCaptureStatus) -> CaptureKind? {
        switch status.type {
        case .article, .tweet, .video: .link
        case .design: .image
        case .note:
            if status.object?.contentType.lowercased().hasPrefix("image/") == true { .image }
            else if status.object != nil { nil }
            else { .note }
        case .transcript: .transcript
        case nil: nil
        }
    }

    private static func activityLabel(for status: BrainCaptureStatus) -> String {
        if let filename = status.object?.filename, !filename.isEmpty { return filename }
        return switch status.type {
        case .article: "Article"
        case .tweet: "Post"
        case .video: "Video"
        case .design: "Image"
        case .note: "Note"
        case .transcript: "Transcript"
        case nil: "Capture"
        }
    }

    private func pollStatus(
        _ captureID: String,
        api: any BrainCaptureAPI,
        immediately: Bool
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            if !immediately || attempt > 0 {
                let delay = Self.pollingBackoff[min(attempt, Self.pollingBackoff.count - 1)]
                do { try await sleep(delay) } catch { return }
            }
            attempt += 1

            let status: BrainCaptureStatus
            do {
                status = try await api.captureStatus(id: captureID)
            } catch is CaptureStatusUnavailable {
                return
            } catch is CancellationError {
                return
            } catch {
                if Self.isAutomaticallyRetryable(error) {
                    errorMessage = error.localizedDescription
                    if let monitor = activeMonitor {
                        let updated = CaptureMonitor(
                            id: monitor.id,
                            startedAt: monitor.startedAt,
                            lastState: monitor.lastState,
                            lastError: error.localizedDescription
                        )
                        activeMonitor = updated
                        monitorStore.save(updated)
                    }
                    continue
                }
                pendingSubmission = nil
                clearMonitor()
                errorMessage = error.localizedDescription
                submissionState = .needsAttention(id: captureID)
                updateActivity(
                    captureID: captureID,
                    stage: .needsAttention,
                    error: error.localizedDescription
                )
                return
            }
            guard status.id == captureID else {
                pendingSubmission = nil
                clearMonitor()
                errorMessage = LocalBrainError.invalidOutput.localizedDescription
                submissionState = .needsAttention(id: captureID)
                updateActivity(
                    captureID: captureID,
                    stage: .needsAttention,
                    error: errorMessage
                )
                return
            }
            errorMessage = nil

            switch status.state {
            case .queued:
                submissionState = .queued(id: captureID)
                updateActivity(captureID: captureID, stage: .queued, error: status.error)
            case .processing:
                submissionState = .delivering(id: captureID)
                updateActivity(captureID: captureID, stage: .delivering, error: status.error)
            case .delivered:
                pendingSubmission = nil
                clearMonitor()
                submissionState = .delivered(id: captureID)
                updateActivity(captureID: captureID, stage: .delivered, error: nil)
                return
            case .failed:
                errorMessage = status.error ?? "Capture delivery needs attention."
                updateActivity(
                    captureID: captureID,
                    stage: .needsAttention,
                    error: errorMessage
                )
                if status.retryable, pendingSubmission?.draftRevision == draftRevision {
                    submissionState = .retryAvailable(id: captureID)
                } else {
                    pendingSubmission = nil
                    clearMonitor()
                    submissionState = .needsAttention(id: captureID)
                }
                return
            }
            activeMonitor = CaptureMonitor(
                id: captureID,
                startedAt: activeMonitor?.startedAt ?? status.createdAt,
                lastState: status.state,
                lastError: status.error
            )
            if let activeMonitor { monitorStore.save(activeMonitor) }
        }
    }

    private func restoreMonitor() {
        guard let monitor = monitorStore.load() else { return }
        if !activities.contains(where: { $0.captureID == monitor.id }) {
            let restored = CaptureActivityRecord(
                id: monitor.id,
                captureID: monitor.id,
                kind: nil,
                label: "Capture",
                source: nil,
                createdAt: monitor.startedAt,
                updatedAt: now(),
                stage: monitor.lastState == .processing ? .delivering : .queued,
                error: monitor.lastError
            )
            activities.insert(restored, at: 0)
            persistActivities()
        }
        activeMonitor = monitor
        queuedReceipt = BrainCaptureReceipt(id: monitor.id, state: "queued")
        submissionState = monitor.lastState == .processing
            ? .delivering(id: monitor.id)
            : .queued(id: monitor.id)
        startMonitoring()
    }

    private func clearMonitor() {
        activeMonitor = nil
        monitorStore.clear()
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func clearDeliveredDraft(for pending: PendingSubmission) {
        guard pending.draftRevision == draftRevision else { return }
        isClearingDeliveredDraft = true
        draft = .empty(kind: draft.kind)
        isClearingDeliveredDraft = false
    }

    private func addActivity(for draft: CaptureDraft, idempotencyKey: UUID) -> String {
        let id = idempotencyKey.uuidString.lowercased()
        let label: String = switch draft.kind {
        case .note:
            "Note"
        case .link:
            URL(string: draft.url)?.host.map { "Link · \($0)" } ?? "Link"
        case .image:
            draft.image?.filename ?? "Image"
        case .transcript:
            draft.transcriptFilename ?? "Transcript"
        }
        activities.insert(CaptureActivityRecord(
            id: id,
            captureID: nil,
            kind: draft.kind,
            label: label,
            source: Self.source,
            createdAt: now(),
            updatedAt: now(),
            stage: .sending,
            error: nil
        ), at: 0)
        persistActivities()
        return id
    }

    private func updateActivity(
        activityID: String? = nil,
        captureID: String?,
        stage: CaptureActivityStage,
        error: String?
    ) {
        guard let index = activities.firstIndex(where: {
            (activityID != nil && $0.id == activityID) ||
                (captureID != nil && $0.captureID == captureID)
        }) else { return }
        if let captureID { activities[index].captureID = captureID }
        activities[index].stage = stage
        activities[index].updatedAt = now()
        activities[index].error = error
        persistActivities()
        if stage == .delivered,
           let deliveredID = captureID ?? activities[index].captureID,
           notifiedDeliveries.insert(deliveredID).inserted {
            deliveryHandler?(deliveredID)
        }
    }

    private func persistActivities() {
        if activities.count > Self.maximumActivityRecords {
            activities.removeLast(activities.count - Self.maximumActivityRecords)
        }
        activityStore.save(activities)
    }

    private static func isAutomaticallyRetryable(_ error: Error) -> Bool {
        false
    }

    private static func validatedURL(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureValidationError.emptyURL }
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw CaptureValidationError.invalidURL
        }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CaptureValidationError.invalidURL
        }
        return normalized
    }

    private static func validatedImageDataURL(_ image: CaptureImagePayload) throws -> String {
        guard ["image/jpeg", "image/png", "image/webp"].contains(image.mimeType) else {
            throw CaptureValidationError.unsupportedImageType
        }
        guard imageMatchesDeclaredType(image.data, mimeType: image.mimeType) else {
            throw CaptureValidationError.invalidImageData
        }
        let encoded = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
        guard encoded.lengthOfBytes(using: .utf8) <= maximumEncodedImageBytes else {
            throw CaptureValidationError.oversizedEncodedImage
        }
        guard image.data.count <= maximumDecodedImageBytes else {
            throw CaptureValidationError.oversizedDecodedImage
        }
        return encoded
    }

    private static func imageMatchesDeclaredType(_ data: Data, mimeType: String) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        switch mimeType {
        case "image/jpeg":
            return bytes.count >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8
        case "image/png":
            return bytes.count >= 8 && Array(bytes.prefix(8)) == [
                0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            ]
        case "image/webp":
            return bytes.count >= 12
                && String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF"
                && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP"
        default:
            return false
        }
    }

    private static func imageMIMEType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        default: nil
        }
    }

    private static func isSupportedTranscript(filename: String) -> Bool {
        ["md", "txt"].contains((filename as NSString).pathExtension.lowercased())
    }

    private static func nonblank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

}

private struct PendingSubmission: Sendable {
    let request: BrainCaptureRequest
    let idempotencyKey: UUID
    let draftRevision: Int
    let activityID: String?
}

struct CaptureMonitor: Codable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let lastState: BrainCaptureState
    let lastError: String?
}

@MainActor
private final class CaptureActivityStore {
    private let defaults: UserDefaults?
    private var memory: Data?
    private var dismissedMemory: Set<String> = []

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() -> [CaptureActivityRecord] {
        guard let data = defaults?.data(forKey: CaptureController.activityDefaultsKey) ?? memory,
              let records = try? JSONDecoder.brainDecoder().decode(
                [CaptureActivityRecord].self,
                from: data
              ) else { return [] }
        return Array(records.prefix(CaptureController.maximumActivityRecords))
    }

    func save(_ records: [CaptureActivityRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        memory = data
        defaults?.set(data, forKey: CaptureController.activityDefaultsKey)
    }

    func isDismissed(_ captureID: String) -> Bool {
        dismissedIDs().contains(captureID)
    }

    func dismiss(_ captureIDs: [String]) {
        guard !captureIDs.isEmpty else { return }
        var ids = dismissedIDs()
        ids.formUnion(captureIDs)
        if ids.count > 500 {
            ids = Set(ids.sorted().suffix(500))
        }
        dismissedMemory = ids
        defaults?.set(ids.sorted(), forKey: CaptureController.dismissedActivityDefaultsKey)
    }

    private func dismissedIDs() -> Set<String> {
        if let stored = defaults?.stringArray(
            forKey: CaptureController.dismissedActivityDefaultsKey
        ) {
            return Set(stored)
        }
        return dismissedMemory
    }
}

@MainActor
private final class CaptureMonitorStore {
    private let defaults: UserDefaults?
    private var memory: Data?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() -> CaptureMonitor? {
        guard let data = defaults?.data(forKey: CaptureController.monitorDefaultsKey) ?? memory else {
            return nil
        }
        guard let monitor = try? JSONDecoder.brainDecoder().decode(CaptureMonitor.self, from: data),
              UUID(uuidString: monitor.id) != nil,
              monitor.lastState == .queued || monitor.lastState == .processing else {
            clear()
            return nil
        }
        return monitor
    }

    func save(_ monitor: CaptureMonitor) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(monitor) else { return }
        memory = data
        defaults?.set(data, forKey: CaptureController.monitorDefaultsKey)
    }

    func clear() {
        memory = nil
        defaults?.removeObject(forKey: CaptureController.monitorDefaultsKey)
    }
}
