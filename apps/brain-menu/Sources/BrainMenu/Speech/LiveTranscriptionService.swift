import CryptoKit
import Darwin
import Foundation

/// The live meeting path deliberately sees only one VoxType operation. It
/// cannot start paste recording, stop it, or reach any focus-changing API.
protocol LiveTranscriptionClient: Sendable {
    func transcribe(wavURL: URL, engine: String) async throws -> String
    func effectiveEngine(for requestedEngine: String) async -> String
}

extension LiveTranscriptionClient {
    func effectiveEngine(for requestedEngine: String) async -> String { requestedEngine }
}

extension VoxTypeClient: LiveTranscriptionClient {}

enum LiveTranscriptionPhase: String, Equatable, Sendable {
    case preview
    case final
}

struct LiveTranscriptSegment: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: MeetingAudioSource
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
    let phase: LiveTranscriptionPhase

    var sourceLabel: String {
        source == .microphone ? "You" : "Remote"
    }

    init(
        source: MeetingAudioSource,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String,
        phase: LiveTranscriptionPhase
    ) {
        self.source = source
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.phase = phase
        id = Self.stableID(
            source: source,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
    }

    private static func stableID(
        source: MeetingAudioSource,
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) -> UUID {
        let value = [
            "brain-live-transcript-v1",
            source.rawValue,
            String(startMilliseconds),
            String(endMilliseconds),
        ].joined(separator: "\0")
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct LiveTranscriptFailure: Equatable, Sendable {
    let source: MeetingAudioSource
    let phase: LiveTranscriptionPhase
    let startMilliseconds: Int64?
    let endMilliseconds: Int64?
    let message: String
}

enum LiveTranscriptPreviewLagState: Equatable, Sendable {
    case current
    case lagging(droppedChunksBySource: [MeetingAudioSource: Int])

    var droppedChunksBySource: [MeetingAudioSource: Int] {
        guard case .lagging(let values) = self else { return [:] }
        return values
    }
}

enum LiveTranscriptionEvent: Equatable, Sendable {
    case preview(LiveTranscriptSegment)
    case failure(LiveTranscriptFailure)
    case previewLagChanged(LiveTranscriptPreviewLagState)
}

struct LiveTranscriptionFinalization: Equatable, Sendable {
    let segments: [LiveTranscriptSegment]
    let failures: [LiveTranscriptFailure]
    let previewLag: LiveTranscriptPreviewLagState
    let wasCancelled: Bool
    let effectiveEngine: String
}

struct LiveTranscriptionServiceSnapshot: Equatable, Sendable {
    let pendingChunksBySource: [MeetingAudioSource: Int]
    let activeSources: Set<MeetingAudioSource>
    let previewLag: LiveTranscriptPreviewLagState
}

enum LiveTranscriptionServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case unsafeDirectory
    case alreadyStopped
    case invalidTrack(MeetingAudioSource)
    case wavWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Live transcription has an invalid origin, duration, queue bound, or threshold."
        case .unsafeDirectory:
            "Live transcript WAV files require a private regular directory."
        case .alreadyStopped:
            "Live transcription has already stopped."
        case .invalidTrack:
            "A final meeting audio track is incomplete or unsafe."
        case .wavWriteFailed:
            "A private WAV file could not be written for transcription."
        }
    }
}

/// Chunks each source against one meeting clock while allowing microphone and
/// system VoxType work to progress independently. A source has one worker and
/// at most `maximumPendingChunksPerSource` queued WAVs behind it.
actor LiveTranscriptionService {
    typealias EventHandler = @Sendable (LiveTranscriptionEvent) async -> Void

    static let defaultChunkDuration: TimeInterval = 10
    static let defaultMaximumPendingChunksPerSource = 6
    static let defaultVoiceThreshold: Float = 0.01

    let engine: SpeechEngineID
    let originHostTimestamp: TimeInterval
    let chunkDuration: TimeInterval
    let maximumPendingChunksPerSource: Int

    private let client: any LiveTranscriptionClient
    private let wavDirectory: URL
    private let fileManager: FileManager
    private let voiceThreshold: Float
    private let sampleRate = MeetingAudioWriter.sampleRate
    private let chunkFrameCount: Int

    private var windows: [MeetingAudioSource: SourceWindow] = [:]
    private var queues: [MeetingAudioSource: [PendingChunk]] = [:]
    private var workerTasks: [MeetingAudioSource: Task<Void, Never>] = [:]
    private var activeSources = Set<MeetingAudioSource>()
    private var droppedChunks: [MeetingAudioSource: Int] = [:]
    private var eventHandler: EventHandler = { _ in }
    private var finalizationTask: Task<FinalSpanBatch, Never>?
    private var isStopping = false
    private var isStopped = false
    private var wasCancelled = false

    init(
        client: any LiveTranscriptionClient,
        engine: SpeechEngineID,
        originHostTimestamp: TimeInterval,
        wavDirectory: URL,
        chunkDuration: TimeInterval = LiveTranscriptionService.defaultChunkDuration,
        maximumPendingChunksPerSource: Int = LiveTranscriptionService
            .defaultMaximumPendingChunksPerSource,
        voiceThreshold: Float = LiveTranscriptionService.defaultVoiceThreshold,
        fileManager: FileManager = .default
    ) throws {
        guard originHostTimestamp.isFinite,
              chunkDuration.isFinite,
              chunkDuration == Self.defaultChunkDuration,
              maximumPendingChunksPerSource > 0,
              maximumPendingChunksPerSource <= Self.defaultMaximumPendingChunksPerSource,
              voiceThreshold.isFinite,
              voiceThreshold >= 0 else {
            throw LiveTranscriptionServiceError.invalidConfiguration
        }
        let frames = Int((chunkDuration * Double(MeetingAudioWriter.sampleRate)).rounded())
        guard frames > 0 else {
            throw LiveTranscriptionServiceError.invalidConfiguration
        }

        self.client = client
        self.engine = engine
        self.originHostTimestamp = originHostTimestamp
        self.wavDirectory = wavDirectory.standardizedFileURL
        self.chunkDuration = chunkDuration
        self.maximumPendingChunksPerSource = maximumPendingChunksPerSource
        self.voiceThreshold = voiceThreshold
        self.fileManager = fileManager
        chunkFrameCount = frames
        try Self.preparePrivateDirectory(self.wavDirectory, fileManager: fileManager)
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        eventHandler = handler
    }

    /// Input may use native source formats. It follows the same normalization
    /// routine as the persisted source tracks before being put on the shared
    /// 16 kHz meeting timeline.
    func append(_ buffer: MeetingAudioSampleBuffer) async throws {
        guard !isStopping, !isStopped else {
            throw LiveTranscriptionServiceError.alreadyStopped
        }
        let normalized = try MeetingAudioWriter.normalize(buffer)
        var firstGlobalFrame = Int64(
            ((buffer.hostTimestamp - originHostTimestamp) * Double(sampleRate)).rounded()
        )
        var firstSampleIndex = 0
        if firstGlobalFrame < 0 {
            firstSampleIndex = min(normalized.count, Int(-firstGlobalFrame))
            firstGlobalFrame = 0
        }
        guard firstSampleIndex < normalized.count else { return }

        var globalFrame = firstGlobalFrame
        var sampleIndex = firstSampleIndex
        while sampleIndex < normalized.count {
            var window = windows[buffer.source] ?? SourceWindow()
            let targetIndex = globalFrame / Int64(chunkFrameCount)

            if let currentIndex = window.index, targetIndex > currentIndex {
                if let chunk = finishWindow(
                    source: buffer.source,
                    window: window,
                    fullWindow: true
                ) {
                    await enqueue(chunk)
                }
                window = SourceWindow(nextMinimumIndex: currentIndex + 1)
            }

            if window.index == nil {
                guard targetIndex >= window.nextMinimumIndex else {
                    let obsoleteFrames = min(
                        normalized.count - sampleIndex,
                        Int((window.nextMinimumIndex * Int64(chunkFrameCount)) - globalFrame)
                    )
                    guard obsoleteFrames > 0 else { break }
                    sampleIndex += obsoleteFrames
                    globalFrame += Int64(obsoleteFrames)
                    windows[buffer.source] = window
                    continue
                }
                window.begin(index: targetIndex, frameCount: chunkFrameCount)
            }

            guard let currentIndex = window.index else { break }
            if targetIndex < currentIndex {
                let skip = min(
                    normalized.count - sampleIndex,
                    Int((Int64(currentIndex) * Int64(chunkFrameCount)) - globalFrame)
                )
                guard skip > 0 else { break }
                sampleIndex += skip
                globalFrame += Int64(skip)
                windows[buffer.source] = window
                continue
            }

            let offset = Int(globalFrame % Int64(chunkFrameCount))
            let count = min(normalized.count - sampleIndex, chunkFrameCount - offset)
            let values = normalized[sampleIndex..<(sampleIndex + count)]
            window.samples.replaceSubrange(offset..<(offset + count), with: values)
            window.lastWrittenOffset = max(window.lastWrittenOffset, offset + count)
            if !window.hasVoice {
                window.hasVoice = values.contains { abs($0) >= voiceThreshold }
            }
            sampleIndex += count
            globalFrame += Int64(count)

            if offset + count == chunkFrameCount {
                if let chunk = finishWindow(
                    source: buffer.source,
                    window: window,
                    fullWindow: true
                ) {
                    await enqueue(chunk)
                }
                window = SourceWindow(nextMinimumIndex: currentIndex + 1)
            }
            windows[buffer.source] = window
        }
    }

    /// Waits for all preview WAVs admitted so far. Primarily useful when a UI
    /// wants a settled snapshot without stopping capture.
    func waitForPendingPreview() async {
        await drainWorkers()
    }

    func waitForPendingPreview(source: MeetingAudioSource) async {
        while let task = workerTasks[source] { await task.value }
    }

    func snapshot() -> LiveTranscriptionServiceSnapshot {
        LiveTranscriptionServiceSnapshot(
            pendingChunksBySource: Dictionary(
                uniqueKeysWithValues: MeetingAudioSource.allCases.map {
                    ($0, queues[$0, default: []].count)
                }
            ),
            activeSources: activeSources,
            previewLag: previewLagState
        )
    }

    /// Flushes the live preview workers, then derives source-attributed speech
    /// spans from the persisted tracks on their shared meeting clock. Preview
    /// queue pressure never affects final completeness, and a failed final
    /// span cannot collapse the rest of a source into one whole-track blob.
    func stop(capture: MeetingAudioCaptureSummary) async -> LiveTranscriptionFinalization {
        guard !isStopped, !isStopping else {
            return LiveTranscriptionFinalization(
                segments: [],
                failures: [],
                previewLag: previewLagState,
                wasCancelled: wasCancelled,
                effectiveEngine: engine.rawValue
            )
        }
        isStopping = true
        defer {
            MeetingTranscriptionAudioCleanup.removeDirectoryIfEmpty(
                wavDirectory,
                fileManager: fileManager
            )
        }

        for source in MeetingAudioSource.allCases {
            guard let window = windows[source], window.index != nil else { continue }
            if let chunk = finishWindow(source: source, window: window, fullWindow: false) {
                await enqueue(chunk)
            }
            windows[source] = SourceWindow(nextMinimumIndex: window.nextMinimumIndex)
        }
        await drainWorkers()
        if wasCancelled || Task.isCancelled {
            isStopping = false
            isStopped = true
            return LiveTranscriptionFinalization(
                segments: [],
                failures: [],
                previewLag: previewLagState,
                wasCancelled: true,
                effectiveEngine: await client.effectiveEngine(for: engine.rawValue)
            )
        }

        let final: FinalSpanBatch
        do {
            let timeline = try MeetingTimelineAudio(capture: capture)
            let spans = try timeline.speechSpans()
            let task = Task { [client, engine, wavDirectory] in
                await Self.transcribeFinalSpans(
                    spans,
                    timeline: timeline,
                    client: client,
                    engine: engine,
                    wavDirectory: wavDirectory
                )
            }
            finalizationTask = task
            final = await task.value
            finalizationTask = nil
        } catch {
            final = FinalSpanBatch(
                segments: [],
                failures: Self.timelineFailures(capture: capture, error: error)
            )
        }

        if wasCancelled || Task.isCancelled {
            isStopping = false
            isStopped = true
            return LiveTranscriptionFinalization(
                segments: [],
                failures: [],
                previewLag: previewLagState,
                wasCancelled: true,
                effectiveEngine: await client.effectiveEngine(for: engine.rawValue)
            )
        }

        isStopping = false
        isStopped = true
        return LiveTranscriptionFinalization(
            segments: final.segments.sorted(by: Self.segmentsAreOrdered),
            failures: final.failures.sorted(by: Self.failuresAreOrdered),
            previewLag: previewLagState,
            wasCancelled: false,
            effectiveEngine: await client.effectiveEngine(for: engine.rawValue)
        )
    }

    /// Cancels in-flight work and removes every queued private WAV. The
    /// Process-backed client propagates cancellation to its child process.
    func cancel() async {
        wasCancelled = true
        isStopping = true
        let finalTask = finalizationTask
        finalTask?.cancel()
        let tasks = Array(workerTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        if let finalTask { _ = await finalTask.value }
        for queue in queues.values {
            for chunk in queue { try? fileManager.removeItem(at: chunk.wavURL) }
        }
        queues.removeAll()
        workerTasks.removeAll()
        finalizationTask = nil
        activeSources.removeAll()
        windows.removeAll()
        isStopping = false
        isStopped = true
        MeetingTranscriptionAudioCleanup.removeDirectoryIfEmpty(
            wavDirectory,
            fileManager: fileManager
        )
    }

    private var previewLagState: LiveTranscriptPreviewLagState {
        let values = droppedChunks.filter { $0.value > 0 }
        return values.isEmpty ? .current : .lagging(droppedChunksBySource: values)
    }

    private func finishWindow(
        source: MeetingAudioSource,
        window: SourceWindow,
        fullWindow: Bool
    ) -> PendingSamples? {
        guard let index = window.index,
              window.hasVoice,
              window.lastWrittenOffset > 0 else { return nil }
        let frameCount = fullWindow ? chunkFrameCount : window.lastWrittenOffset
        let start = Int64(
            (Double(index * Int64(chunkFrameCount)) / Double(sampleRate) * 1_000).rounded()
        )
        let end = Int64(
            (Double(index * Int64(chunkFrameCount) + Int64(frameCount))
                / Double(sampleRate) * 1_000).rounded()
        )
        return PendingSamples(
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            samples: Array(window.samples.prefix(frameCount))
        )
    }

    private func enqueue(_ samples: PendingSamples) async {
        if queues[samples.source, default: []].count >= maximumPendingChunksPerSource {
            droppedChunks[samples.source, default: 0] += 1
            await eventHandler(.previewLagChanged(previewLagState))
            return
        }

        do {
            let url = try writePreviewWAV(samples)
            let pending = PendingChunk(
                source: samples.source,
                startMilliseconds: samples.startMilliseconds,
                endMilliseconds: samples.endMilliseconds,
                wavURL: url
            )
            queues[samples.source, default: []].append(pending)
            queues[samples.source]?.sort {
                if $0.startMilliseconds != $1.startMilliseconds {
                    return $0.startMilliseconds < $1.startMilliseconds
                }
                return $0.endMilliseconds < $1.endMilliseconds
            }
            startWorkerIfNeeded(for: samples.source)
        } catch {
            await eventHandler(.failure(LiveTranscriptFailure(
                source: samples.source,
                phase: .preview,
                startMilliseconds: samples.startMilliseconds,
                endMilliseconds: samples.endMilliseconds,
                message: Self.boundedMessage(error)
            )))
        }
    }

    private func startWorkerIfNeeded(for source: MeetingAudioSource) {
        guard workerTasks[source] == nil else { return }
        workerTasks[source] = Task { [weak self] in
            await self?.runWorker(for: source)
        }
    }

    private func runWorker(for source: MeetingAudioSource) async {
        while !Task.isCancelled {
            guard !queues[source, default: []].isEmpty else { break }
            let chunk = queues[source, default: []].removeFirst()
            activeSources.insert(source)
            let result = await transcribePreview(chunk)
            activeSources.remove(source)
            if let result { await eventHandler(result) }
        }

        if Task.isCancelled {
            let abandoned = queues.removeValue(forKey: source) ?? []
            for chunk in abandoned { try? fileManager.removeItem(at: chunk.wavURL) }
        }
        activeSources.remove(source)
        workerTasks.removeValue(forKey: source)
    }

    private func transcribePreview(_ chunk: PendingChunk) async -> LiveTranscriptionEvent? {
        defer { try? fileManager.removeItem(at: chunk.wavURL) }
        do {
            let text = try await client.transcribe(
                wavURL: chunk.wavURL,
                engine: engine.rawValue
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .preview(LiveTranscriptSegment(
                source: chunk.source,
                startMilliseconds: chunk.startMilliseconds,
                endMilliseconds: chunk.endMilliseconds,
                text: text,
                phase: .preview
            ))
        } catch is CancellationError {
            return nil
        } catch {
            return .failure(LiveTranscriptFailure(
                source: chunk.source,
                phase: .preview,
                startMilliseconds: chunk.startMilliseconds,
                endMilliseconds: chunk.endMilliseconds,
                message: Self.boundedMessage(error)
            ))
        }
    }

    private func drainWorkers() async {
        while !workerTasks.isEmpty {
            let tasks = Array(workerTasks.values)
            for task in tasks { await task.value }
        }
    }

    private static func transcribeFinalSpans(
        _ spans: [MeetingTimelineSpeechSpan],
        timeline: MeetingTimelineAudio,
        client: any LiveTranscriptionClient,
        engine: SpeechEngineID,
        wavDirectory: URL
    ) async -> FinalSpanBatch {
        await withTaskGroup(of: FinalSpanBatch.self) { group in
            for source in MeetingAudioSource.allCases {
                let sourceSpans = spans.filter { $0.source == source }
                guard !sourceSpans.isEmpty else { continue }
                group.addTask {
                    var batch = FinalSpanBatch()
                    var skipRemainingSpans = false
                    for span in sourceSpans {
                        guard !Task.isCancelled else { break }
                        if skipRemainingSpans {
                            batch.failures.append(Self.skippedFinalFailure(span: span))
                            continue
                        }
                        switch await Self.transcribeFinalSpan(
                            span,
                            timeline: timeline,
                            client: client,
                            engine: engine,
                            wavDirectory: wavDirectory
                        ) {
                        case .segment(let segment):
                            batch.segments.append(segment)
                        case .failure(let failure, let shouldStopSource):
                            batch.failures.append(failure)
                            skipRemainingSpans = shouldStopSource
                        }
                    }
                    return batch
                }
            }

            var combined = FinalSpanBatch()
            for await batch in group {
                combined.segments.append(contentsOf: batch.segments)
                combined.failures.append(contentsOf: batch.failures)
            }
            return combined
        }
    }

    private static func transcribeFinalSpan(
        _ span: MeetingTimelineSpeechSpan,
        timeline: MeetingTimelineAudio,
        client: any LiveTranscriptionClient,
        engine: SpeechEngineID,
        wavDirectory: URL
    ) async -> FinalSpanOutcome {
        let wavURL: URL
        do {
            wavURL = try timeline.writeWAV(for: span, to: wavDirectory)
        } catch {
            return .failure(finalFailure(span: span, error: error), stopSource: false)
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        var finalMessage = "VoxType returned no text for a detected speech span."
        var systemicClientErrorCount = 0
        for attempt in 0..<2 {
            do {
                let text = try await client.transcribe(
                    wavURL: wavURL,
                    engine: engine.rawValue
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    if attempt == 0 { continue }
                    break
                }
                return .segment(LiveTranscriptSegment(
                    source: span.source,
                    startMilliseconds: span.startMilliseconds,
                    endMilliseconds: span.endMilliseconds,
                    text: text,
                    phase: .final
                ))
            } catch is CancellationError {
                finalMessage = CancellationError().localizedDescription
                break
            } catch {
                if isSystemicFinalFailure(error) {
                    systemicClientErrorCount += 1
                }
                finalMessage = boundedMessage(error)
            }
        }
        return .failure(
            LiveTranscriptFailure(
                source: span.source,
                phase: .final,
                startMilliseconds: span.startMilliseconds,
                endMilliseconds: span.endMilliseconds,
                message: String(finalMessage.prefix(240))
            ),
            stopSource: systemicClientErrorCount == 2
        )
    }

    private static func finalFailure(
        span: MeetingTimelineSpeechSpan,
        error: Error
    ) -> LiveTranscriptFailure {
        LiveTranscriptFailure(
            source: span.source,
            phase: .final,
            startMilliseconds: span.startMilliseconds,
            endMilliseconds: span.endMilliseconds,
            message: boundedMessage(error)
        )
    }

    private static func skippedFinalFailure(
        span: MeetingTimelineSpeechSpan
    ) -> LiveTranscriptFailure {
        LiveTranscriptFailure(
            source: span.source,
            phase: .final,
            startMilliseconds: span.startMilliseconds,
            endMilliseconds: span.endMilliseconds,
            message: "Skipped after VoxType failed twice for an earlier source span."
        )
    }

    private static func isSystemicFinalFailure(_ error: Error) -> Bool {
        guard let error = error as? VoxTypeClientError else { return false }
        return switch error {
        case .timedOut(command: .transcribe), .launchFailed(command: .transcribe): true
        default: false
        }
    }

    private func writePreviewWAV(_ chunk: PendingSamples) throws -> URL {
        let name = [
            "preview",
            chunk.source.rawValue,
            String(chunk.startMilliseconds),
            String(chunk.endMilliseconds),
            UUID().uuidString,
        ].joined(separator: "-") + ".wav"
        let url = wavDirectory.appendingPathComponent(name, isDirectory: false)
        return try PrivateFloatWAV.write(samples: chunk.samples, to: url, fileManager: fileManager)
    }

    private static func segmentsAreOrdered(
        _ lhs: LiveTranscriptSegment,
        _ rhs: LiveTranscriptSegment
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func failuresAreOrdered(
        _ lhs: LiveTranscriptFailure,
        _ rhs: LiveTranscriptFailure
    ) -> Bool {
        let lhsStart = lhs.startMilliseconds ?? .max
        let rhsStart = rhs.startMilliseconds ?? .max
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        let lhsEnd = lhs.endMilliseconds ?? .max
        let rhsEnd = rhs.endMilliseconds ?? .max
        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.phase != rhs.phase { return lhs.phase.rawValue < rhs.phase.rawValue }
        return lhs.message < rhs.message
    }

    private static func timelineFailures(
        capture: MeetingAudioCaptureSummary,
        error: Error
    ) -> [LiveTranscriptFailure] {
        MeetingAudioSource.allCases.compactMap { source in
            let chunks = capture.chunks.filter { $0.source == source }
            guard !chunks.isEmpty else { return nil }
            let start = chunks.map(\.timestampMilliseconds).min()
            let end = chunks.map { chunk -> Int64 in
                let duration = max(Int64.zero, Int64(
                    (Double(chunk.frameCount) / Double(MeetingAudioWriter.sampleRate) * 1_000)
                        .rounded()
                ))
                let (value, overflow) = chunk.timestampMilliseconds.addingReportingOverflow(
                    duration
                )
                return overflow ? Int64.max : value
            }.max()
            return LiveTranscriptFailure(
                source: source,
                phase: .final,
                startMilliseconds: start,
                endMilliseconds: end,
                message: boundedMessage(error)
            )
        }
    }

    private static func boundedMessage(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }

    private static func preparePrivateDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LiveTranscriptionServiceError.unsafeDirectory
        }
        if fileManager.fileExists(atPath: directory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
                throw LiveTranscriptionServiceError.unsafeDirectory
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw LiveTranscriptionServiceError.unsafeDirectory
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard owner == Darwin.geteuid(), permissions.map({ $0 & 0o077 == 0 }) == true else {
                throw LiveTranscriptionServiceError.unsafeDirectory
            }
        } catch let error as LiveTranscriptionServiceError {
            throw error
        } catch {
            throw LiveTranscriptionServiceError.unsafeDirectory
        }
        do {
            try MeetingTranscriptionAudioCleanup.sweepOwnedWAVs(
                in: directory,
                fileManager: fileManager
            )
        } catch {
            throw LiveTranscriptionServiceError.unsafeDirectory
        }
    }
}

enum MeetingTranscriptionAudioCleanup {
    static func sweepOwnedWAVs(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".wav"),
                  name.hasPrefix("preview-") || name.hasPrefix("final-") else { continue }
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  candidate.resolvingSymlinksInPath().standardizedFileURL == candidate else {
                continue
            }
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  owner == Darwin.geteuid() else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }

    static func removeDirectoryIfEmpty(
        _ directory: URL,
        fileManager: FileManager
    ) {
        try? sweepOwnedWAVs(in: directory, fileManager: fileManager)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path),
              entries.isEmpty else { return }
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = Darwin.rmdir(path)
        }
    }

}

private struct FinalSpanBatch: Sendable {
    var segments: [LiveTranscriptSegment] = []
    var failures: [LiveTranscriptFailure] = []
}

private enum FinalSpanOutcome: Sendable {
    case segment(LiveTranscriptSegment)
    case failure(LiveTranscriptFailure, stopSource: Bool)
}

private struct SourceWindow {
    var index: Int64?
    var nextMinimumIndex: Int64
    var samples: [Float]
    var lastWrittenOffset = 0
    var hasVoice = false

    init(nextMinimumIndex: Int64 = 0) {
        index = nil
        self.nextMinimumIndex = nextMinimumIndex
        samples = []
    }

    mutating func begin(index: Int64, frameCount: Int) {
        self.index = index
        nextMinimumIndex = index
        samples = [Float](repeating: 0, count: frameCount)
        lastWrittenOffset = 0
        hasVoice = false
    }
}

private struct PendingSamples: Sendable {
    let source: MeetingAudioSource
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let samples: [Float]
}

private struct PendingChunk: Sendable {
    let source: MeetingAudioSource
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let wavURL: URL
}

private enum PrivateFloatWAV {
    static let headerSize = 44
    static let bytesPerSample = MemoryLayout<Float>.size

    static func write(
        samples: [Float],
        to url: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard samples.count <= Int(UInt32.max) / bytesPerSample else {
            throw LiveTranscriptionServiceError.wavWriteFailed
        }
        let dataByteCount = samples.count * bytesPerSample
        var data = header(dataByteCount: dataByteCount)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try create(data: data, at: url, fileManager: fileManager)
        return url
    }

    static func write(
        track: MeetingAudioTrack,
        to url: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard track.fileURL.isFileURL,
              track.fileURL.path.hasPrefix("/"),
              track.frameCount <= Int64(UInt32.max) / Int64(bytesPerSample) else {
            throw LiveTranscriptionServiceError.invalidTrack(track.source)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: track.fileURL.path)
        } catch {
            throw LiveTranscriptionServiceError.invalidTrack(track.source)
        }
        let expectedBytes = track.frameCount * Int64(bytesPerSample)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              track.fileURL.resolvingSymlinksInPath().standardizedFileURL
                == track.fileURL.standardizedFileURL,
              (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else {
            throw LiveTranscriptionServiceError.invalidTrack(track.source)
        }

        let initial = header(dataByteCount: Int(expectedBytes))
        try create(data: initial, at: url, fileManager: fileManager)
        do {
            let input = try FileHandle(forReadingFrom: track.fileURL)
            let output = try FileHandle(forWritingTo: url)
            defer {
                try? input.close()
                try? output.close()
            }
            try output.seekToEnd()
            var copied: Int64 = 0
            while copied < expectedBytes {
                let count = min(64 * 1_024, Int(expectedBytes - copied))
                let data = try input.read(upToCount: count) ?? Data()
                guard !data.isEmpty else {
                    throw LiveTranscriptionServiceError.invalidTrack(track.source)
                }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
            }
            try output.synchronize()
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            return url
        } catch let error as LiveTranscriptionServiceError {
            try? fileManager.removeItem(at: url)
            throw error
        } catch {
            try? fileManager.removeItem(at: url)
            throw LiveTranscriptionServiceError.wavWriteFailed
        }
    }

    private static func create(data: Data, at url: URL, fileManager: FileManager) throws {
        guard !fileManager.fileExists(atPath: url.path),
              fileManager.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
              ) else {
            throw LiveTranscriptionServiceError.wavWriteFailed
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: url)
            throw LiveTranscriptionServiceError.wavWriteFailed
        }
    }

    private static func header(dataByteCount: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(3), to: &data) // IEEE Float32
        append(UInt16(MeetingAudioWriter.channelCount), to: &data)
        append(UInt32(MeetingAudioWriter.sampleRate), to: &data)
        append(
            UInt32(MeetingAudioWriter.sampleRate * MeetingAudioWriter.channelCount * bytesPerSample),
            to: &data
        )
        append(UInt16(MeetingAudioWriter.channelCount * bytesPerSample), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataByteCount), to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
