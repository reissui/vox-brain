import Darwin
import Foundation

struct MeetingTimelineSpeechSpan: Equatable, Sendable {
    let source: MeetingAudioSource
    let startMilliseconds: Int64
    let endMilliseconds: Int64
}

enum MeetingTimelineAudioError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTrack(MeetingAudioSource)
    case invalidTrackFormat(MeetingAudioSource)
    case trackNotRegularFile(MeetingAudioSource)
    case invalidTrackFileSize(source: MeetingAudioSource, expectedBytes: Int64, actualBytes: Int64)
    case missingTrack(MeetingAudioSource)
    case invalidChunk(source: MeetingAudioSource, index: Int)
    case chunkOutOfTrackBounds(source: MeetingAudioSource, index: Int)
    case overlappingTrackFrames(source: MeetingAudioSource)
    case overlappingTimelineFrames(source: MeetingAudioSource)
    case trackReadFailed(MeetingAudioSource)
    case unknownSpan
    case unsafeOutputDirectory
    case wavWriteFailed

    var errorDescription: String? {
        switch self {
        case .duplicateTrack(let source):
            "The meeting audio manifest contains more than one \(source.rawValue) track."
        case .invalidTrackFormat(let source):
            "The \(source.rawValue) track is not Float32 16 kHz mono audio."
        case .trackNotRegularFile(let source):
            "The \(source.rawValue) track is not a regular local file."
        case .invalidTrackFileSize(let source, let expectedBytes, let actualBytes):
            "The \(source.rawValue) track contains \(actualBytes) bytes; expected \(expectedBytes)."
        case .missingTrack(let source):
            "A \(source.rawValue) audio chunk has no matching track."
        case .invalidChunk(let source, let index):
            "The \(source.rawValue) audio chunk at manifest index \(index) is invalid."
        case .chunkOutOfTrackBounds(let source, let index):
            "The \(source.rawValue) audio chunk at manifest index \(index) exceeds its track."
        case .overlappingTrackFrames(let source):
            "The \(source.rawValue) audio chunks reuse compact track frames."
        case .overlappingTimelineFrames(let source):
            "The \(source.rawValue) audio chunks overlap beyond timestamp rounding tolerance."
        case .trackReadFailed(let source):
            "The \(source.rawValue) meeting audio track could not be read."
        case .unknownSpan:
            "The requested speech span was not detected in this meeting."
        case .unsafeOutputDirectory:
            "Meeting transcription audio must be written to a safe local directory."
        case .wavWriteFailed:
            "The private meeting transcription WAV could not be written."
        }
    }
}

/// Reconstructs each compact source track on the shared meeting timeline.
/// Track bytes are read in small windows; a whole meeting is never resident in memory.
struct MeetingTimelineAudio: Sendable {
    private static let sampleRate = MeetingAudioWriter.sampleRate
    private static let bytesPerSample = MemoryLayout<Float>.size
    private static let vadWindowFrames = 30 * sampleRate / 1_000
    private static let minimumSpeechFrames = 90 * sampleRate / 1_000
    // Keep natural pauses inside one conversational turn. This substantially
    // reduces external transcriber launches without merging across speech from
    // the other source, which is handled as an explicit interruption below.
    private static let maximumMergeSilenceFrames = 1_200 * sampleRate / 1_000
    private static let paddingFrames = 200 * sampleRate / 1_000
    private static let maximumSpanFrames = 30 * sampleRate
    private static let maximumRetryContextFrames = 3 * sampleRate
    private static let minimumPreferredSplitFrames = 3 * sampleRate
    private static let maximumRoundingOverlapFrames = 2 * sampleRate / 1_000
    private static let voiceRMSThreshold: Float = 0.005
    private static let voicePeakThreshold = LiveTranscriptionService.defaultVoiceThreshold
    private static let ioFrames = 4_096

    private let tracks: [MeetingAudioSource: TimelineTrack]
    private let chunksBySource: [MeetingAudioSource: [TimelineChunk]]

    init(capture: MeetingAudioCaptureSummary) throws {
        let fileManager = FileManager.default
        var validatedTracks: [MeetingAudioSource: TimelineTrack] = [:]

        for track in capture.tracks {
            guard validatedTracks[track.source] == nil else {
                throw MeetingTimelineAudioError.duplicateTrack(track.source)
            }
            guard track.sampleRate == Self.sampleRate,
                  track.channelCount == MeetingAudioWriter.channelCount,
                  track.frameCount >= 0,
                  track.frameCount <= Int64.max / Int64(Self.bytesPerSample) else {
                throw MeetingTimelineAudioError.invalidTrackFormat(track.source)
            }

            let url = track.fileURL.standardizedFileURL
            guard url.isFileURL,
                  url.path.hasPrefix("/"),
                  url.resolvingSymlinksInPath().standardizedFileURL == url else {
                throw MeetingTimelineAudioError.trackNotRegularFile(track.source)
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: url.path)
            } catch {
                throw MeetingTimelineAudioError.trackNotRegularFile(track.source)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let actualBytes = (attributes[.size] as? NSNumber)?.int64Value else {
                throw MeetingTimelineAudioError.trackNotRegularFile(track.source)
            }
            let expectedBytes = track.frameCount * Int64(Self.bytesPerSample)
            guard actualBytes == expectedBytes else {
                throw MeetingTimelineAudioError.invalidTrackFileSize(
                    source: track.source,
                    expectedBytes: expectedBytes,
                    actualBytes: actualBytes
                )
            }
            validatedTracks[track.source] = TimelineTrack(
                source: track.source,
                fileURL: url,
                frameCount: track.frameCount
            )
        }

        var preparedBySource: [MeetingAudioSource: [TimelineChunk]] = [:]
        for (index, chunk) in capture.chunks.enumerated() {
            guard let track = validatedTracks[chunk.source] else {
                throw MeetingTimelineAudioError.missingTrack(chunk.source)
            }
            guard chunk.timestampMilliseconds >= 0,
                  chunk.sourceTimestamp.isFinite,
                  chunk.frameOffset >= 0,
                  chunk.frameCount > 0 else {
                throw MeetingTimelineAudioError.invalidChunk(source: chunk.source, index: index)
            }
            let (trackEndFrame, trackOverflow) = chunk.frameOffset.addingReportingOverflow(
                Int64(chunk.frameCount)
            )
            guard !trackOverflow, trackEndFrame <= track.frameCount else {
                throw MeetingTimelineAudioError.chunkOutOfTrackBounds(
                    source: chunk.source,
                    index: index
                )
            }
            let (timelineStartFrame, timestampOverflow) = chunk.timestampMilliseconds
                .multipliedReportingOverflow(by: Int64(Self.sampleRate / 1_000))
            let (timelineEndFrame, timelineOverflow) = timelineStartFrame.addingReportingOverflow(
                Int64(chunk.frameCount)
            )
            guard !timestampOverflow,
                  !timelineOverflow,
                  timelineEndFrame <= Int64.max - Int64(Self.paddingFrames) else {
                throw MeetingTimelineAudioError.invalidChunk(source: chunk.source, index: index)
            }
            preparedBySource[chunk.source, default: []].append(TimelineChunk(
                manifestIndex: index,
                timelineStartFrame: timelineStartFrame,
                timelineEndFrame: timelineEndFrame,
                trackStartFrame: chunk.frameOffset,
                trackEndFrame: trackEndFrame
            ))
        }

        for source in MeetingAudioSource.allCases {
            guard var chunks = preparedBySource[source], !chunks.isEmpty else { continue }

            let compactOrder = chunks.sorted {
                if $0.trackStartFrame != $1.trackStartFrame {
                    return $0.trackStartFrame < $1.trackStartFrame
                }
                return $0.manifestIndex < $1.manifestIndex
            }
            for pair in zip(compactOrder, compactOrder.dropFirst())
            where pair.1.trackStartFrame < pair.0.trackEndFrame {
                throw MeetingTimelineAudioError.overlappingTrackFrames(source: source)
            }

            chunks.sort {
                if $0.timelineStartFrame != $1.timelineStartFrame {
                    return $0.timelineStartFrame < $1.timelineStartFrame
                }
                return $0.manifestIndex < $1.manifestIndex
            }
            var maximumPriorEnd = chunks[0].timelineEndFrame
            for chunk in chunks.dropFirst() {
                if chunk.timelineStartFrame < maximumPriorEnd {
                    let overlap = maximumPriorEnd - chunk.timelineStartFrame
                    guard overlap <= Int64(Self.maximumRoundingOverlapFrames) else {
                        throw MeetingTimelineAudioError.overlappingTimelineFrames(source: source)
                    }
                }
                maximumPriorEnd = max(maximumPriorEnd, chunk.timelineEndFrame)
            }
            // Host timestamps are persisted at millisecond precision while
            // normalized audio is stored at 16 kHz. Consecutive callbacks can
            // therefore overlap by a handful of frames after rounding. The
            // reader resolves any overlap deterministically in manifest order,
            // matching retained-audio reconstruction instead of discarding the
            // final transcript for an otherwise valid capture.
            preparedBySource[source] = chunks
        }

        tracks = validatedTracks
        chunksBySource = preparedBySource
    }

    func speechSpans() throws -> [MeetingTimelineSpeechSpan] {
        var provisionalGroupsBySource: [MeetingAudioSource: [VoiceGroup]] = [:]
        for source in MeetingAudioSource.allCases {
            guard let track = tracks[source],
                  let chunks = chunksBySource[source],
                  let timelineEnd = chunks.map(\.timelineEndFrame).max() else { continue }
            var reader = try TimelineSourceReader(track: track, chunks: chunks)
            let runs = try Self.detectVoiceRuns(reader: &reader, timelineEndFrame: timelineEnd)
            provisionalGroupsBySource[source] = Self.mergeVoiceRuns(
                runs,
                interruptedBy: []
            ).filter { $0.voicedFrameCount >= Int64(Self.minimumSpeechFrames) }
        }

        var result: [MeetingTimelineSpeechSpan] = []
        for source in MeetingAudioSource.allCases {
            let validatedRuns = provisionalGroupsBySource[source, default: []]
                .flatMap(\.runs)
            guard !validatedRuns.isEmpty else { continue }
            let interruptions = MeetingAudioSource.allCases
                .filter { $0 != source }
                .flatMap { provisionalGroupsBySource[$0, default: []].flatMap(\.runs) }
                .sorted { $0.startFrame < $1.startFrame }
            let groups = Self.mergeVoiceRuns(
                validatedRuns,
                interruptedBy: interruptions
            )
            for group in groups {
                let start = max(Int64(0), group.startFrame - Int64(Self.paddingFrames))
                let end = group.endFrame + Int64(Self.paddingFrames)
                let candidates = Self.split(
                    source: source,
                    startFrame: start,
                    endFrame: end,
                    voiceRuns: group.runs
                )
                for candidate in candidates {
                    let evidence = try speechEvidence(for: candidate)
                    if evidence.isSpeechBearing { result.append(candidate) }
                }
            }
        }
        return result.sorted(by: Self.spansAreOrdered)
    }

    /// Returns the shared, deterministic speech evidence used to admit a
    /// planned final span. A span is bounded to 30 seconds, so this never loads
    /// an entire meeting into memory.
    func speechEvidence(
        for span: MeetingTimelineSpeechSpan
    ) throws -> SpeechActivityGate.Result {
        SpeechActivityGate().evaluate(try samples(for: span, maximumExtraFrames: 0))
    }

    /// Expands a failed final span with adjacent retained audio. Context is
    /// clipped to the first and last frames actually retained for that source;
    /// it never manufactures silence beyond the capture as retry input.
    func retrySpan(
        for span: MeetingTimelineSpeechSpan,
        adjacentMilliseconds: Int64 = 1_500
    ) throws -> MeetingTimelineSpeechSpan {
        guard adjacentMilliseconds >= 0,
              let chunks = chunksBySource[span.source],
              let retainedStartFrame = chunks.map(\.timelineStartFrame).min(),
              let retainedEndFrame = chunks.map(\.timelineEndFrame).max()
        else { throw MeetingTimelineAudioError.unknownSpan }

        let originalStartFrame = try Self.timelineFrame(milliseconds: span.startMilliseconds)
        let originalEndFrame = try Self.timelineFrame(milliseconds: span.endMilliseconds)
        let contextFrames = adjacentMilliseconds.multipliedReportingOverflow(
            by: Int64(Self.sampleRate / 1_000)
        )
        guard !contextFrames.overflow else { throw MeetingTimelineAudioError.unknownSpan }
        let expandedStart = max(retainedStartFrame, originalStartFrame - contextFrames.partialValue)
        let (candidateEnd, endOverflow) = originalEndFrame.addingReportingOverflow(
            contextFrames.partialValue
        )
        let expandedEnd = min(retainedEndFrame, endOverflow ? .max : candidateEnd)
        guard expandedEnd > expandedStart else { throw MeetingTimelineAudioError.unknownSpan }
        return Self.span(
            source: span.source,
            startFrame: expandedStart,
            endFrame: expandedEnd
        )
    }

    /// Reads one bounded span of a source track on the meeting timeline.
    /// Regions the manifest never mapped read as silence; a region the track
    /// cannot supply throws instead of returning misaligned audio.
    func samples(for span: MeetingTimelineSpeechSpan) throws -> [Float] {
        try samples(for: span, maximumExtraFrames: Self.maximumRetryContextFrames)
    }

    /// Creates a unique owner-only WAV. The caller owns and must remove the returned file.
    func writeWAV(
        for span: MeetingTimelineSpeechSpan,
        to directory: URL
    ) throws -> URL {
        guard tracks[span.source] != nil,
              chunksBySource[span.source] != nil else {
            throw MeetingTimelineAudioError.unknownSpan
        }
        let safeDirectory = try Self.validatedOutputDirectory(directory)
        let filename = [
            "final",
            span.source.rawValue,
            String(span.startMilliseconds),
            String(span.endMilliseconds),
            UUID().uuidString,
        ].joined(separator: "-") + ".wav"
        let destination = safeDirectory.appendingPathComponent(filename).standardizedFileURL
        guard destination.deletingLastPathComponent() == safeDirectory else {
            throw MeetingTimelineAudioError.unsafeOutputDirectory
        }

        let samples = try samples(
            for: span,
            maximumExtraFrames: Self.maximumRetryContextFrames
        )

        let fileDescriptor = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileDescriptor >= 0 else { throw MeetingTimelineAudioError.wavWriteFailed }

        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        let output = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            guard Darwin.fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw MeetingTimelineAudioError.wavWriteFailed
            }
            let frameCount = Int64(samples.count)
            try output.write(contentsOf: Self.wavHeader(
                dataByteCount: UInt32(frameCount * Int64(Self.bytesPerSample))
            ))

            var cursor = 0
            while cursor < samples.count {
                let end = min(cursor + Self.ioFrames, samples.count)
                try output.write(contentsOf: Self.littleEndianData(Array(samples[cursor..<end])))
                cursor = end
            }
            try output.synchronize()
            try output.close()

            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  permissions.map({ $0 & 0o077 == 0 }) == true,
                  owner == Darwin.geteuid() else {
                throw MeetingTimelineAudioError.wavWriteFailed
            }
            succeeded = true
            return destination
        } catch let error as MeetingTimelineAudioError {
            try? output.close()
            throw error
        } catch {
            try? output.close()
            throw MeetingTimelineAudioError.wavWriteFailed
        }
    }

    private func samples(
        for span: MeetingTimelineSpeechSpan,
        maximumExtraFrames: Int
    ) throws -> [Float] {
        guard let track = tracks[span.source],
              let chunks = chunksBySource[span.source],
              let sourceTimelineEnd = chunks.map(\.timelineEndFrame).max() else {
            throw MeetingTimelineAudioError.unknownSpan
        }
        let startFrame = try Self.timelineFrame(milliseconds: span.startMilliseconds)
        let endFrame = try Self.timelineFrame(milliseconds: span.endMilliseconds)
        let (maximumPaddedEnd, paddedEndOverflow) = sourceTimelineEnd.addingReportingOverflow(
            Int64(Self.paddingFrames)
        )
        let maximumFrames = Self.maximumSpanFrames + maximumExtraFrames
        guard endFrame > startFrame,
              endFrame - startFrame <= Int64(maximumFrames),
              startFrame <= sourceTimelineEnd,
              endFrame <= (paddedEndOverflow ? Int64.max : maximumPaddedEnd),
              endFrame - startFrame <= Int64(UInt32.max) / Int64(Self.bytesPerSample) else {
            throw MeetingTimelineAudioError.unknownSpan
        }
        var reader = try TimelineSourceReader(track: track, chunks: chunks)
        return try reader.read(
            timelineStartFrame: startFrame,
            frameCount: Int(endFrame - startFrame)
        )
    }

    private static func detectVoiceRuns(
        reader: inout TimelineSourceReader,
        timelineEndFrame: Int64
    ) throws -> [VoiceRun] {
        guard let firstMappedFrame = reader.nextMappedFrame(atOrAfter: 0) else { return [] }
        var result: [VoiceRun] = []
        var activeStart: Int64?
        var activeEnd: Int64 = 0
        var cursor = firstMappedFrame / Int64(vadWindowFrames) * Int64(vadWindowFrames)
        while cursor < timelineEndFrame {
            let count = Int(min(Int64(vadWindowFrames), timelineEndFrame - cursor))
            let samples = try reader.read(timelineStartFrame: cursor, frameCount: count)
            var squareSum = 0.0
            var peak: Float = 0
            for sample in samples {
                squareSum += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }
            let rms = samples.isEmpty ? 0 : Float(sqrt(squareSum / Double(samples.count)))
            if rms >= voiceRMSThreshold || peak >= voicePeakThreshold {
                if activeStart == nil { activeStart = cursor }
                activeEnd = cursor + Int64(count)
            } else if let start = activeStart {
                result.append(VoiceRun(startFrame: start, endFrame: activeEnd))
                activeStart = nil
            }
            let nextCursor = cursor + Int64(count)
            if activeStart == nil,
               let nextMappedFrame = reader.nextMappedFrame(atOrAfter: nextCursor),
               nextMappedFrame > nextCursor {
                cursor = nextMappedFrame / Int64(vadWindowFrames) * Int64(vadWindowFrames)
            } else {
                cursor = nextCursor
            }
        }
        if let start = activeStart {
            result.append(VoiceRun(startFrame: start, endFrame: activeEnd))
        }
        return result
    }

    private static func mergeVoiceRuns(
        _ runs: [VoiceRun],
        interruptedBy interruptingRuns: [VoiceRun]
    ) -> [VoiceGroup] {
        var groups: [VoiceGroup] = []
        var firstPossibleInterruption = 0
        for run in runs {
            guard let lastIndex = groups.indices.last else {
                groups.append(VoiceGroup(
                    startFrame: run.startFrame,
                    endFrame: run.endFrame,
                    voicedFrameCount: run.frameCount,
                    runs: [run]
                ))
                continue
            }
            let silenceStart = groups[lastIndex].endFrame
            let silenceEnd = run.startFrame
            while firstPossibleInterruption < interruptingRuns.count,
                  interruptingRuns[firstPossibleInterruption].endFrame <= silenceStart {
                firstPossibleInterruption += 1
            }
            var interruptionIndex = firstPossibleInterruption
            var isInterrupted = false
            while interruptionIndex < interruptingRuns.count,
                  interruptingRuns[interruptionIndex].startFrame < silenceEnd {
                if interruptingRuns[interruptionIndex].endFrame > silenceStart {
                    isInterrupted = true
                    break
                }
                interruptionIndex += 1
            }

            if silenceEnd - silenceStart < Int64(maximumMergeSilenceFrames),
               !isInterrupted {
                groups[lastIndex].endFrame = run.endFrame
                groups[lastIndex].voicedFrameCount += run.frameCount
                groups[lastIndex].runs.append(run)
            } else {
                groups.append(VoiceGroup(
                    startFrame: run.startFrame,
                    endFrame: run.endFrame,
                    voicedFrameCount: run.frameCount,
                    runs: [run]
                ))
            }
        }
        return groups
    }

    private static func split(
        source: MeetingAudioSource,
        startFrame: Int64,
        endFrame: Int64,
        voiceRuns: [VoiceRun]
    ) -> [MeetingTimelineSpeechSpan] {
        var result: [MeetingTimelineSpeechSpan] = []
        var cursor = startFrame
        while endFrame - cursor > Int64(maximumSpanFrames) {
            let remaining = endFrame - cursor
            let partCount = (remaining + Int64(maximumSpanFrames) - 1)
                / Int64(maximumSpanFrames)
            let balancedLength = (remaining + partCount - 1) / partCount
            let balancedEnd = cursor + balancedLength
            let hardEnd = cursor + Int64(maximumSpanFrames)
            let minimumPreferred = cursor + min(
                Int64(minimumPreferredSplitFrames),
                balancedLength / 2
            )
            let minimumRemaining = (partCount - 1) * Int64(minimumPreferredSplitFrames)
            let silenceCuts = zip(voiceRuns, voiceRuns.dropFirst()).compactMap { pair -> Int64? in
                let silenceStart = pair.0.endFrame
                let silenceEnd = pair.1.startFrame
                guard silenceEnd > silenceStart else { return nil }
                let midpoint = silenceStart + (silenceEnd - silenceStart) / 2
                return midpoint >= minimumPreferred
                    && midpoint <= hardEnd
                    && endFrame - midpoint >= minimumRemaining ? midpoint : nil
            }
            let cut = silenceCuts.min {
                abs($0 - balancedEnd) < abs($1 - balancedEnd)
            } ?? balancedEnd
            result.append(span(source: source, startFrame: cursor, endFrame: cut))
            cursor = cut
        }
        result.append(span(source: source, startFrame: cursor, endFrame: endFrame))
        return result
    }

    private static func span(
        source: MeetingAudioSource,
        startFrame: Int64,
        endFrame: Int64
    ) -> MeetingTimelineSpeechSpan {
        MeetingTimelineSpeechSpan(
            source: source,
            startMilliseconds: startFrame * 1_000 / Int64(sampleRate),
            endMilliseconds: endFrame * 1_000 / Int64(sampleRate)
        )
    }

    private static func spansAreOrdered(
        _ lhs: MeetingTimelineSpeechSpan,
        _ rhs: MeetingTimelineSpeechSpan
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private static func validatedOutputDirectory(_ directory: URL) throws -> URL {
        let result = directory.standardizedFileURL
        guard result.isFileURL,
              result.path.hasPrefix("/"),
              result.resolvingSymlinksInPath().standardizedFileURL == result else {
            throw MeetingTimelineAudioError.unsafeOutputDirectory
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        } catch {
            throw MeetingTimelineAudioError.unsafeOutputDirectory
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MeetingTimelineAudioError.unsafeOutputDirectory
        }
        return result
    }

    private static func timelineFrame(milliseconds: Int64) throws -> Int64 {
        guard milliseconds >= 0 else { throw MeetingTimelineAudioError.unknownSpan }
        let (result, overflow) = milliseconds.multipliedReportingOverflow(
            by: Int64(sampleRate / 1_000)
        )
        guard !overflow else { throw MeetingTimelineAudioError.unknownSpan }
        return result
    }

    private static func wavHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataByteCount, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(3), to: &data)
        appendLittleEndian(UInt16(MeetingAudioWriter.channelCount), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * bytesPerSample), to: &data)
        appendLittleEndian(UInt16(bytesPerSample), to: &data)
        appendLittleEndian(UInt16(bytesPerSample * 8), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataByteCount, to: &data)
        return data
    }

    private static func littleEndianData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * bytesPerSample)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct TimelineTrack: Sendable {
    let source: MeetingAudioSource
    let fileURL: URL
    let frameCount: Int64
}

private struct TimelineChunk: Sendable {
    let manifestIndex: Int
    let timelineStartFrame: Int64
    let timelineEndFrame: Int64
    let trackStartFrame: Int64
    let trackEndFrame: Int64
}

private struct VoiceRun {
    let startFrame: Int64
    let endFrame: Int64

    var frameCount: Int64 { endFrame - startFrame }
}

private struct VoiceGroup {
    let startFrame: Int64
    var endFrame: Int64
    var voicedFrameCount: Int64
    var runs: [VoiceRun]
}

private struct TimelineSourceReader {
    private let track: TimelineTrack
    private let chunks: [TimelineChunk]
    private let handle: FileHandle
    private var firstPossibleChunk = 0

    init(track: TimelineTrack, chunks: [TimelineChunk]) throws {
        self.track = track
        self.chunks = chunks
        do {
            handle = try FileHandle(forReadingFrom: track.fileURL)
        } catch {
            throw MeetingTimelineAudioError.trackReadFailed(track.source)
        }
    }

    mutating func read(timelineStartFrame: Int64, frameCount: Int) throws -> [Float] {
        guard timelineStartFrame >= 0, frameCount >= 0 else {
            throw MeetingTimelineAudioError.trackReadFailed(track.source)
        }
        var result = [Float](repeating: 0, count: frameCount)
        let timelineEndFrame = timelineStartFrame + Int64(frameCount)
        while firstPossibleChunk < chunks.count,
              chunks[firstPossibleChunk].timelineEndFrame <= timelineStartFrame {
            firstPossibleChunk += 1
        }

        var index = firstPossibleChunk
        while index < chunks.count, chunks[index].timelineStartFrame < timelineEndFrame {
            let chunk = chunks[index]
            let overlapStart = max(timelineStartFrame, chunk.timelineStartFrame)
            let overlapEnd = min(timelineEndFrame, chunk.timelineEndFrame)
            if overlapEnd > overlapStart {
                let trackStart = chunk.trackStartFrame + overlapStart - chunk.timelineStartFrame
                let count = Int(overlapEnd - overlapStart)
                let destinationOffset = Int(overlapStart - timelineStartFrame)
                let samples = try readTrack(frameOffset: trackStart, frameCount: count)
                result.replaceSubrange(
                    destinationOffset..<(destinationOffset + count),
                    with: samples
                )
            }
            index += 1
        }
        return result
    }

    mutating func nextMappedFrame(atOrAfter frame: Int64) -> Int64? {
        while firstPossibleChunk < chunks.count,
              chunks[firstPossibleChunk].timelineEndFrame <= frame {
            firstPossibleChunk += 1
        }
        guard firstPossibleChunk < chunks.count else { return nil }
        return max(frame, chunks[firstPossibleChunk].timelineStartFrame)
    }

    private func readTrack(frameOffset: Int64, frameCount: Int) throws -> [Float] {
        let byteOffset = frameOffset * Int64(MemoryLayout<Float>.size)
        let byteCount = frameCount * MemoryLayout<Float>.size
        do {
            try handle.seek(toOffset: UInt64(byteOffset))
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                throw MeetingTimelineAudioError.trackReadFailed(track.source)
            }
            var samples = [Float](repeating: 0, count: frameCount)
            _ = samples.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination)
            }
            return samples
        } catch let error as MeetingTimelineAudioError {
            throw error
        } catch {
            throw MeetingTimelineAudioError.trackReadFailed(track.source)
        }
    }
}
