import Foundation

typealias MeetingAudioSource = MeetingUtteranceSource

enum MeetingAudioDeliveryPolicy {
    static let largeGapThreshold: TimeInterval = 0.65
    static let repeatedGapWindow: TimeInterval = 6
    static let watchdogRepeatedGapCount = 3
    static let stalledStreamTimeout: TimeInterval = 2.5
}

struct MeetingAudioSampleBuffer: Equatable, Sendable {
    let source: MeetingAudioSource
    let sourceTimestamp: TimeInterval
    let hostTimestamp: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let interleavedSamples: [Float]

    init(
        source: MeetingAudioSource,
        sourceTimestamp: TimeInterval,
        hostTimestamp: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        interleavedSamples: [Float]
    ) {
        self.source = source
        self.sourceTimestamp = sourceTimestamp
        self.hostTimestamp = hostTimestamp
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.interleavedSamples = interleavedSamples
    }
}

enum MeetingAudioDiscontinuityReason: String, Codable, CaseIterable, Sendable {
    case deviceChanged
    case sampleRateChanged
    case systemSleep
    case systemWake
    case permissionRevoked
    case streamInterrupted
    case timestampRegression
    case sourceFailure
}

enum MeetingAudioFailureReason: String, Codable, CaseIterable, Sendable {
    case permissionDenied
    case permissionRevoked
    case sourceUnavailable
    case interrupted
    case sourceFailed
    case writerFailed
    case emptyCapture
}

struct MeetingAudioLevel: Codable, Equatable, Sendable {
    let source: MeetingAudioSource
    let timestampMilliseconds: Int64
    let rms: Float
    let isClipping: Bool
}

struct MeetingAudioChunk: Codable, Equatable, Sendable {
    let source: MeetingAudioSource
    let timestampMilliseconds: Int64
    let sourceTimestamp: TimeInterval
    let frameOffset: Int64
    let frameCount: Int
}

struct MeetingAudioDiscontinuity: Codable, Equatable, Sendable {
    let source: MeetingAudioSource
    let timestampMilliseconds: Int64
    let sourceTimestamp: TimeInterval?
    let reason: MeetingAudioDiscontinuityReason
    let detail: String?
}

struct MeetingAudioFailure: Codable, Equatable, Sendable {
    let source: MeetingAudioSource?
    let timestampMilliseconds: Int64
    let reason: MeetingAudioFailureReason
    let message: String
}

struct MeetingAudioTrack: Codable, Equatable, Sendable {
    let source: MeetingAudioSource
    let fileURL: URL
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int64
}

struct MeetingAudioSourceDiagnostics: Codable, Equatable, Sendable {
    let source: MeetingAudioSource
    let callbackCount: Int
    let deliveredDurationMilliseconds: Int64
    let observedDurationMilliseconds: Int64
    let coverageRatio: Double
    let maximumInterBufferGapMilliseconds: Int64
    let detectedDropoutCount: Int
    let nativeSampleRate: Double?
    let nativeChannelCount: Int?
}

struct MeetingAudioCaptureDiagnostics: Codable, Equatable, Sendable {
    let sources: [MeetingAudioSourceDiagnostics]
}

struct MeetingAudioCaptureSummary: Codable, Equatable, Sendable {
    let origin: Date
    let originHostTimestamp: TimeInterval
    let tracks: [MeetingAudioTrack]
    let chunks: [MeetingAudioChunk]
    let discontinuities: [MeetingAudioDiscontinuity]
    let failures: [MeetingAudioFailure]
    /// Optional so manifests written by older Brain versions remain decodable.
    let diagnostics: MeetingAudioCaptureDiagnostics?

    init(
        origin: Date,
        originHostTimestamp: TimeInterval,
        tracks: [MeetingAudioTrack],
        chunks: [MeetingAudioChunk],
        discontinuities: [MeetingAudioDiscontinuity],
        failures: [MeetingAudioFailure],
        diagnostics: MeetingAudioCaptureDiagnostics? = nil
    ) {
        self.origin = origin
        self.originHostTimestamp = originHostTimestamp
        self.tracks = tracks
        self.chunks = chunks
        self.discontinuities = discontinuities
        self.failures = failures
        self.diagnostics = diagnostics
    }

    var totalFrameCount: Int64 {
        tracks.reduce(0) { $0 + $1.frameCount }
    }
}

struct MeetingAudioAppendResult: Equatable, Sendable {
    let frameCount: Int
    let level: MeetingAudioLevel?
}

enum MeetingAudioWriterError: Error, Equatable, LocalizedError, Sendable {
    case unsafeMeetingDirectory
    case invalidBuffer
    case alreadyFinalized
    case fileWriteFailed
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .unsafeMeetingDirectory:
            "Meeting audio must stay in a safe application-state directory."
        case .invalidBuffer:
            "The captured audio buffer has an invalid format or timestamp."
        case .alreadyFinalized:
            "The meeting audio writer has already been finalized."
        case .fileWriteFailed:
            "The private meeting audio files could not be written."
        case .emptyCapture:
            "The meeting ended without any microphone or system audio."
        }
    }
}

/// Writes normalized source tracks directly to private local files. The writer
/// deliberately has no ingest dependency: only transcript text is sent to the
/// local Brain vault.
final class MeetingAudioWriter: @unchecked Sendable {
    static let sampleRate = 16_000
    static let channelCount = 1
    static let manifestFilename = "audio-capture.json"
    private static let contiguousTimestampTolerance: TimeInterval = 0.1

    let meetingDirectory: URL
    let origin: Date

    private let fileManager: FileManager
    private let lock = NSLock()
    private var state: State

    init(
        meetingDirectory: URL,
        origin: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        self.meetingDirectory = meetingDirectory.standardizedFileURL
        self.origin = origin
        self.fileManager = fileManager

        try Self.prepareDirectory(self.meetingDirectory, fileManager: fileManager)
        let microphone = try Self.openTrack(
            source: .microphone,
            directory: self.meetingDirectory,
            fileManager: fileManager
        )
        do {
            let system = try Self.openTrack(
                source: .system,
                directory: self.meetingDirectory,
                fileManager: fileManager
            )
            state = State(tracks: [.microphone: microphone, .system: system])
        } catch {
            try? microphone.handle.close()
            try? fileManager.removeItem(at: microphone.url)
            throw error
        }
    }

    deinit {
        lock.withLock {
            for track in state.tracks.values {
                try? track.handle.close()
            }
        }
    }

    func append(_ buffer: MeetingAudioSampleBuffer) throws -> MeetingAudioAppendResult {
        try lock.withLock {
            guard !state.finalized else { throw MeetingAudioWriterError.alreadyFinalized }
            let normalized = try Self.normalize(buffer)
            let rawLevel = Self.levelMetrics(for: buffer.interleavedSamples)
            guard var track = state.tracks[buffer.source] else {
                throw MeetingAudioWriterError.invalidBuffer
            }

            var requiresNewChunk = state.forceNewChunkSources.remove(buffer.source) != nil
            if let prior = state.lastHostTimestamp[buffer.source], buffer.hostTimestamp < prior {
                state.discontinuities.append(StoredDiscontinuity(
                    source: buffer.source,
                    hostTimestamp: buffer.hostTimestamp,
                    sourceTimestamp: buffer.sourceTimestamp,
                    reason: .timestampRegression,
                    detail: "Audio arrived before an earlier buffer from the same source."
                ))
                requiresNewChunk = true
            }
            state.lastHostTimestamp[buffer.source] = max(
                state.lastHostTimestamp[buffer.source] ?? buffer.hostTimestamp,
                buffer.hostTimestamp
            )
            state.originHostTimestamp = min(
                state.originHostTimestamp ?? buffer.hostTimestamp,
                buffer.hostTimestamp
            )

            do {
                try track.handle.write(contentsOf: Self.data(for: normalized))
            } catch {
                throw MeetingAudioWriterError.fileWriteFailed
            }

            let frameOffset = track.frameCount
            track.frameCount += Int64(normalized.count)
            state.tracks[buffer.source] = track
            state.callbackCounts[buffer.source, default: 0] += 1
            state.nativeFormats[buffer.source] = NativeAudioFormat(
                sampleRate: buffer.sampleRate,
                channelCount: buffer.channelCount
            )
            state.hasNonzeroAudio = state.hasNonzeroAudio || normalized.contains { $0 != 0 }
            let chunk = StoredChunk(
                source: buffer.source,
                hostTimestamp: buffer.hostTimestamp,
                sourceTimestamp: buffer.sourceTimestamp,
                frameOffset: frameOffset,
                frameCount: normalized.count
            )
            if !requiresNewChunk,
               let index = state.lastChunkIndex[buffer.source],
               state.chunks.indices.contains(index),
               state.chunks[index].canCoalesce(
                   chunk,
                   timestampTolerance: Self.contiguousTimestampTolerance,
                   sampleRate: Self.sampleRate
               ) {
                state.chunks[index].frameCount += normalized.count
            } else {
                state.chunks.append(chunk)
                state.lastChunkIndex[buffer.source] = state.chunks.index(before: state.chunks.endIndex)
            }

            let level: MeetingAudioLevel?
            let previousLevelTime = state.lastLevelHostTimestamp[buffer.source]
            if previousLevelTime == nil || buffer.hostTimestamp - previousLevelTime! >= 0.1 {
                state.lastLevelHostTimestamp[buffer.source] = buffer.hostTimestamp
                level = MeetingAudioLevel(
                    source: buffer.source,
                    timestampMilliseconds: Self.milliseconds(
                        buffer.hostTimestamp,
                        since: state.originHostTimestamp ?? buffer.hostTimestamp
                    ),
                    rms: rawLevel.rms,
                    isClipping: rawLevel.isClipping
                )
            } else {
                level = nil
            }

            return MeetingAudioAppendResult(frameCount: normalized.count, level: level)
        }
    }

    @discardableResult
    func recordDiscontinuity(
        source: MeetingAudioSource,
        reason: MeetingAudioDiscontinuityReason,
        sourceTimestamp: TimeInterval? = nil,
        hostTimestamp: TimeInterval,
        detail: String? = nil
    ) throws -> MeetingAudioDiscontinuity {
        try lock.withLock {
            guard !state.finalized else { throw MeetingAudioWriterError.alreadyFinalized }
            guard hostTimestamp.isFinite else { throw MeetingAudioWriterError.invalidBuffer }
            state.originHostTimestamp = min(
                state.originHostTimestamp ?? hostTimestamp,
                hostTimestamp
            )
            let stored = StoredDiscontinuity(
                source: source,
                hostTimestamp: hostTimestamp,
                sourceTimestamp: sourceTimestamp,
                reason: reason,
                detail: detail
            )
            state.discontinuities.append(stored)
            state.forceNewChunkSources.insert(source)
            return stored.publicValue(origin: state.originHostTimestamp ?? hostTimestamp)
        }
    }

    @discardableResult
    func recordFailure(
        source: MeetingAudioSource?,
        reason: MeetingAudioFailureReason,
        hostTimestamp: TimeInterval,
        message: String
    ) throws -> MeetingAudioFailure {
        try lock.withLock {
            guard !state.finalized else { throw MeetingAudioWriterError.alreadyFinalized }
            guard hostTimestamp.isFinite else { throw MeetingAudioWriterError.invalidBuffer }
            state.originHostTimestamp = min(
                state.originHostTimestamp ?? hostTimestamp,
                hostTimestamp
            )
            let stored = StoredFailure(
                source: source,
                hostTimestamp: hostTimestamp,
                reason: reason,
                message: message
            )
            state.failures.append(stored)
            if let source { state.forceNewChunkSources.insert(source) }
            return stored.publicValue(origin: state.originHostTimestamp ?? hostTimestamp)
        }
    }

    func finalize() throws -> MeetingAudioCaptureSummary {
        try lock.withLock {
            guard !state.finalized else { throw MeetingAudioWriterError.alreadyFinalized }
            guard state.tracks.values.contains(where: { $0.frameCount > 0 }),
                  state.hasNonzeroAudio else {
                state.failures.append(StoredFailure(
                    source: nil,
                    hostTimestamp: state.originHostTimestamp ?? 0,
                    reason: .emptyCapture,
                    message: MeetingAudioWriterError.emptyCapture.localizedDescription
                ))
                throw MeetingAudioWriterError.emptyCapture
            }

            for track in state.tracks.values {
                do {
                    try track.handle.synchronize()
                    try track.handle.close()
                    try fileManager.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o600)],
                        ofItemAtPath: track.url.path
                    )
                } catch {
                    throw MeetingAudioWriterError.fileWriteFailed
                }
            }

            let originHostTimestamp = state.originHostTimestamp ?? 0
            let summary = MeetingAudioCaptureSummary(
                origin: origin,
                originHostTimestamp: originHostTimestamp,
                tracks: MeetingAudioSource.allCases.compactMap { source in
                    guard let track = state.tracks[source] else { return nil }
                    return MeetingAudioTrack(
                        source: source,
                        fileURL: track.url,
                        sampleRate: Self.sampleRate,
                        channelCount: Self.channelCount,
                        frameCount: track.frameCount
                    )
                },
                chunks: state.chunks
                    .sorted(by: Self.chunksAreOrdered)
                    .map { $0.publicValue(origin: originHostTimestamp) },
                discontinuities: state.discontinuities
                    .sorted(by: Self.discontinuitiesAreOrdered)
                    .map { $0.publicValue(origin: originHostTimestamp) },
                failures: state.failures
                    .sorted(by: Self.failuresAreOrdered)
                    .map { $0.publicValue(origin: originHostTimestamp) },
                diagnostics: Self.captureDiagnostics(state: state)
            )
            try writeManifest(summary)
            state.finalized = true
            return summary
        }
    }

    private func writeManifest(_ summary: MeetingAudioCaptureSummary) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(summary)
        } catch {
            throw MeetingAudioWriterError.fileWriteFailed
        }
        let url = meetingDirectory.appendingPathComponent(Self.manifestFilename)
        guard fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingAudioWriterError.fileWriteFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw MeetingAudioWriterError.fileWriteFailed
        }
    }

    static func normalize(_ buffer: MeetingAudioSampleBuffer) throws -> [Float] {
        guard buffer.sourceTimestamp.isFinite,
              buffer.hostTimestamp.isFinite,
              buffer.sampleRate.isFinite,
              buffer.sampleRate > 0,
              buffer.channelCount > 0,
              !buffer.interleavedSamples.isEmpty,
              buffer.interleavedSamples.allSatisfy(\.isFinite),
              buffer.interleavedSamples.count.isMultiple(of: buffer.channelCount) else {
            throw MeetingAudioWriterError.invalidBuffer
        }

        let inputFrameCount = buffer.interleavedSamples.count / buffer.channelCount
        var mono = [Float](repeating: 0, count: inputFrameCount)
        var channelSquareSums = [Double](repeating: 0, count: buffer.channelCount)
        for frame in 0..<inputFrameCount {
            var sum: Float = 0
            for channel in 0..<buffer.channelCount {
                let sample = buffer.interleavedSamples[frame * buffer.channelCount + channel]
                sum += sample
                channelSquareSums[channel] += Double(sample) * Double(sample)
            }
            mono[frame] = sum / Float(buffer.channelCount)
        }

        // Averaging is the right default for ordinary multi-channel input, but
        // some USB devices expose the same signal with inverted polarity across
        // two channels. A straight average turns that valid microphone signal
        // into digital silence, so retain the strongest channel when destructive
        // cancellation is severe.
        if buffer.channelCount > 1,
           let loudestChannel = channelSquareSums.indices.max(by: {
               channelSquareSums[$0] < channelSquareSums[$1]
           }) {
            let loudestRMS = sqrt(channelSquareSums[loudestChannel] / Double(inputFrameCount))
            let monoSquareSum = mono.reduce(0.0) { $0 + Double($1) * Double($1) }
            let monoRMS = sqrt(monoSquareSum / Double(inputFrameCount))
            if loudestRMS > 0, monoRMS < loudestRMS * 0.1 {
                for frame in 0..<inputFrameCount {
                    mono[frame] = buffer.interleavedSamples[
                        frame * buffer.channelCount + loudestChannel
                    ]
                }
            }
        }

        if abs(buffer.sampleRate - Double(sampleRate)) < 0.000_001 {
            return mono
        }

        let outputFrameCount = max(
            1,
            Int((Double(inputFrameCount) * Double(sampleRate) / buffer.sampleRate).rounded())
        )
        let sourceFramesPerOutputFrame = buffer.sampleRate / Double(sampleRate)
        return (0..<outputFrameCount).map { outputIndex in
            let position = Double(outputIndex) * sourceFramesPerOutputFrame
            let lower = min(Int(position), inputFrameCount - 1)
            let upper = min(lower + 1, inputFrameCount - 1)
            let fraction = Float(position - Double(lower))
            return mono[lower] + (mono[upper] - mono[lower]) * fraction
        }
    }

    private static func levelMetrics(for samples: [Float]) -> (rms: Float, isClipping: Bool) {
        let squareSum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (
            rms: samples.isEmpty ? 0 : Float(sqrt(squareSum / Double(samples.count))),
            isClipping: samples.contains { abs($0) >= 0.999 }
        )
    }

    private static func data(for samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: directory.path) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MeetingAudioWriterError.unsafeMeetingDirectory
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw MeetingAudioWriterError.unsafeMeetingDirectory
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        } catch {
            throw MeetingAudioWriterError.unsafeMeetingDirectory
        }
    }

    private static func openTrack(
        source: MeetingAudioSource,
        directory: URL,
        fileManager: FileManager
    ) throws -> TrackState {
        let url = directory.appendingPathComponent("\(source.rawValue).f32le.pcm")
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MeetingAudioWriterError.unsafeMeetingDirectory
            }
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingAudioWriterError.fileWriteFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            return TrackState(url: url, handle: handle)
        } catch {
            throw MeetingAudioWriterError.fileWriteFailed
        }
    }

    private static func milliseconds(_ timestamp: TimeInterval, since origin: TimeInterval) -> Int64 {
        Int64(max(0, ((timestamp - origin) * 1_000).rounded()))
    }

    private static func chunksAreOrdered(_ lhs: StoredChunk, _ rhs: StoredChunk) -> Bool {
        if lhs.hostTimestamp != rhs.hostTimestamp { return lhs.hostTimestamp < rhs.hostTimestamp }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.frameOffset < rhs.frameOffset
    }

    private static func discontinuitiesAreOrdered(
        _ lhs: StoredDiscontinuity,
        _ rhs: StoredDiscontinuity
    ) -> Bool {
        if lhs.hostTimestamp != rhs.hostTimestamp { return lhs.hostTimestamp < rhs.hostTimestamp }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private static func failuresAreOrdered(_ lhs: StoredFailure, _ rhs: StoredFailure) -> Bool {
        if lhs.hostTimestamp != rhs.hostTimestamp { return lhs.hostTimestamp < rhs.hostTimestamp }
        return (lhs.source?.rawValue ?? "") < (rhs.source?.rawValue ?? "")
    }

    private static func captureDiagnostics(state: State) -> MeetingAudioCaptureDiagnostics {
        let sources = MeetingAudioSource.allCases.compactMap { source
            -> MeetingAudioSourceDiagnostics? in
            let chunks = state.chunks
                .filter { $0.source == source }
                .sorted { $0.hostTimestamp < $1.hostTimestamp }
            guard !chunks.isEmpty else { return nil }
            let deliveredFrames = chunks.reduce(Int64(0)) {
                $0 + Int64($1.frameCount)
            }
            let deliveredDuration = Double(deliveredFrames) / Double(sampleRate)
            let firstStart = chunks[0].hostTimestamp
            var priorEnd = firstStart
            var maximumGap: TimeInterval = 0
            var dropoutCount = 0
            for chunk in chunks {
                let gap = max(0, chunk.hostTimestamp - priorEnd)
                maximumGap = max(maximumGap, gap)
                if gap >= MeetingAudioDeliveryPolicy.largeGapThreshold {
                    dropoutCount += 1
                }
                priorEnd = max(
                    priorEnd,
                    chunk.hostTimestamp + Double(chunk.frameCount) / Double(sampleRate)
                )
            }
            let observedDuration = max(deliveredDuration, priorEnd - firstStart)
            let format = state.nativeFormats[source]
            return MeetingAudioSourceDiagnostics(
                source: source,
                callbackCount: state.callbackCounts[source, default: 0],
                deliveredDurationMilliseconds: Int64((deliveredDuration * 1_000).rounded()),
                observedDurationMilliseconds: Int64((observedDuration * 1_000).rounded()),
                coverageRatio: observedDuration > 0
                    ? min(max(deliveredDuration / observedDuration, 0), 1)
                    : 1,
                maximumInterBufferGapMilliseconds: Int64((maximumGap * 1_000).rounded()),
                detectedDropoutCount: dropoutCount,
                nativeSampleRate: format?.sampleRate,
                nativeChannelCount: format?.channelCount
            )
        }
        return MeetingAudioCaptureDiagnostics(sources: sources)
    }
}

private struct State {
    var tracks: [MeetingAudioSource: TrackState]
    var originHostTimestamp: TimeInterval?
    var lastHostTimestamp: [MeetingAudioSource: TimeInterval] = [:]
    var lastLevelHostTimestamp: [MeetingAudioSource: TimeInterval] = [:]
    var chunks: [StoredChunk] = []
    var lastChunkIndex: [MeetingAudioSource: Int] = [:]
    var forceNewChunkSources = Set<MeetingAudioSource>()
    var discontinuities: [StoredDiscontinuity] = []
    var failures: [StoredFailure] = []
    var callbackCounts: [MeetingAudioSource: Int] = [:]
    var nativeFormats: [MeetingAudioSource: NativeAudioFormat] = [:]
    var hasNonzeroAudio = false
    var finalized = false
}

private struct NativeAudioFormat {
    let sampleRate: Double
    let channelCount: Int
}

private struct TrackState {
    let url: URL
    let handle: FileHandle
    var frameCount: Int64 = 0
}

private struct StoredChunk {
    let source: MeetingAudioSource
    let hostTimestamp: TimeInterval
    let sourceTimestamp: TimeInterval
    let frameOffset: Int64
    var frameCount: Int

    func canCoalesce(
        _ next: StoredChunk,
        timestampTolerance: TimeInterval,
        sampleRate: Int
    ) -> Bool {
        guard source == next.source,
              frameOffset <= Int64.max - Int64(frameCount),
              frameOffset + Int64(frameCount) == next.frameOffset,
              frameCount <= Int.max - next.frameCount else {
            return false
        }
        let expectedTimestamp = hostTimestamp + Double(frameCount) / Double(sampleRate)
        return abs(next.hostTimestamp - expectedTimestamp) <= timestampTolerance
    }

    func publicValue(origin: TimeInterval) -> MeetingAudioChunk {
        MeetingAudioChunk(
            source: source,
            timestampMilliseconds: Int64(max(0, ((hostTimestamp - origin) * 1_000).rounded())),
            sourceTimestamp: sourceTimestamp,
            frameOffset: frameOffset,
            frameCount: frameCount
        )
    }
}

private struct StoredDiscontinuity {
    let source: MeetingAudioSource
    let hostTimestamp: TimeInterval
    let sourceTimestamp: TimeInterval?
    let reason: MeetingAudioDiscontinuityReason
    let detail: String?

    func publicValue(origin: TimeInterval) -> MeetingAudioDiscontinuity {
        MeetingAudioDiscontinuity(
            source: source,
            timestampMilliseconds: Int64(max(0, ((hostTimestamp - origin) * 1_000).rounded())),
            sourceTimestamp: sourceTimestamp,
            reason: reason,
            detail: detail
        )
    }
}

private struct StoredFailure {
    let source: MeetingAudioSource?
    let hostTimestamp: TimeInterval
    let reason: MeetingAudioFailureReason
    let message: String

    func publicValue(origin: TimeInterval) -> MeetingAudioFailure {
        MeetingAudioFailure(
            source: source,
            timestampMilliseconds: Int64(max(0, ((hostTimestamp - origin) * 1_000).rounded())),
            reason: reason,
            message: message
        )
    }
}
