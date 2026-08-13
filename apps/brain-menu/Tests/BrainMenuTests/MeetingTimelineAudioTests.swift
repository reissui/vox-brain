import Darwin
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingTimelineAudioTests {
    @Test
    func detectsAlternatingSpeechWithinOneTenSecondWindow() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let samples = voicedSamples(
            durationMilliseconds: 6_000,
            rangesMilliseconds: [900..<1_500, 3_000..<3_600]
        )
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: samples.count)]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans == [
            MeetingTimelineSpeechSpan(
                source: .microphone,
                startMilliseconds: 700,
                endMilliseconds: 1_700
            ),
            MeetingTimelineSpeechSpan(
                source: .microphone,
                startMilliseconds: 2_800,
                endMilliseconds: 3_800
            ),
        ])
    }

    @Test
    func batchesNaturalSameSpeakerPausesIntoOneTranscriptionSpan() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let samples = voicedSamples(
            durationMilliseconds: 4_000,
            rangesMilliseconds: [900..<1_500, 2_200..<2_800]
        )
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(
                timestampMilliseconds: 0,
                frameOffset: 0,
                frameCount: samples.count
            )]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans == [MeetingTimelineSpeechSpan(
            source: .microphone,
            startMilliseconds: 700,
            endMilliseconds: 3_020
        )])
    }

    @Test
    func doesNotMergeSpeechAcrossExactOnePointTwoSecondBoundary() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let samples = voicedSamples(
            durationMilliseconds: 4_000,
            rangesMilliseconds: [300..<900, 2_100..<2_700]
        )
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(
                timestampMilliseconds: 0,
                frameOffset: 0,
                frameCount: samples.count
            )]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.endMilliseconds - $0.startMilliseconds <= 30_000 })
    }

    @Test
    func preservesGenuineOverlapAcrossSources() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let microphone = voicedSamples(
            durationMilliseconds: 4_000,
            rangesMilliseconds: [900..<1_800]
        )
        let system = voicedSamples(
            durationMilliseconds: 4_000,
            rangesMilliseconds: [1_200..<2_100]
        )
        let capture = try fixture.capture(tracks: [
            TrackFixture(
                source: .system,
                samples: system,
                chunks: [ChunkFixture(
                    timestampMilliseconds: 0,
                    frameOffset: 0,
                    frameCount: system.count
                )]
            ),
            TrackFixture(
                source: .microphone,
                samples: microphone,
                chunks: [ChunkFixture(
                    timestampMilliseconds: 0,
                    frameOffset: 0,
                    frameCount: microphone.count
                )]
            ),
        ])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans == [
            MeetingTimelineSpeechSpan(
                source: .microphone,
                startMilliseconds: 700,
                endMilliseconds: 2_000
            ),
            MeetingTimelineSpeechSpan(
                source: .system,
                startMilliseconds: 1_000,
                endMilliseconds: 2_300
            ),
        ])
        #expect(spans[0].endMilliseconds > spans[1].startMilliseconds)
    }

    @Test
    func acknowledgementInOtherSourcePauseSplitsTheSurroundingTurn() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let system = voicedSamples(
            durationMilliseconds: 2_400,
            rangesMilliseconds: [0..<600, 900..<1_500]
        )
        let microphone = voicedSamples(
            durationMilliseconds: 2_400,
            rangesMilliseconds: [630..<870]
        )
        let capture = try fixture.capture(tracks: [
            TrackFixture(
                source: .system,
                samples: system,
                chunks: [ChunkFixture(
                    timestampMilliseconds: 0,
                    frameOffset: 0,
                    frameCount: system.count
                )]
            ),
            TrackFixture(
                source: .microphone,
                samples: microphone,
                chunks: [ChunkFixture(
                    timestampMilliseconds: 0,
                    frameOffset: 0,
                    frameCount: microphone.count
                )]
            ),
        ])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans.map(\.source) == [.system, .system])
        #expect(spans.map(\.startMilliseconds) == [0, 700])
    }

    @Test
    func sharedSpeechGateRejectsQuietShortAcknowledgements() throws {
        let fixture = try MeetingTimelineAudioFixture()
        var samples = [Float](repeating: 0, count: 2_000 * MeetingAudioWriter.sampleRate / 1_000)
        let start = 900 * MeetingAudioWriter.sampleRate / 1_000
        let end = 1_020 * MeetingAudioWriter.sampleRate / 1_000
        let quietTurn = (0..<(end - start)).map { index in
            index.isMultiple(of: 2) ? Float(0.006) : Float(-0.006)
        }
        samples.replaceSubrange(start..<end, with: quietTurn)
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: samples.count)]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans.isEmpty)
    }

    @Test
    func sharedSpeechGateRejectsSparsePeakOnlyAcknowledgements() throws {
        let fixture = try MeetingTimelineAudioFixture()
        var samples = [Float](repeating: 0, count: 2_000 * MeetingAudioWriter.sampleRate / 1_000)
        let start = 900 * MeetingAudioWriter.sampleRate / 1_000
        let frameCount = 150 * MeetingAudioWriter.sampleRate / 1_000
        for offset in stride(from: 0, to: frameCount, by: 480) {
            samples[start + offset] = 0.02
        }
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: samples.count)]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans.isEmpty)
    }

    @Test
    func acceptsMillisecondRoundingOverlapFromNormalizedCallbacks() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let callbackFrameCount = 171
        let callbackCount = 30
        let samples = alternatingTone(frameCount: callbackFrameCount * callbackCount)
        let chunks = (0..<callbackCount).map { index in
            ChunkFixture(
                timestampMilliseconds: Int64(
                    (Double(index * callbackFrameCount)
                        / Double(MeetingAudioWriter.sampleRate) * 1_000).rounded()
                ),
                frameOffset: Int64(index * callbackFrameCount),
                frameCount: callbackFrameCount
            )
        }
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: chunks
        )])

        let timeline = try MeetingTimelineAudio(capture: capture)
        let spans = try timeline.speechSpans()

        #expect(spans.count == 1)
        #expect(spans.first?.source == .microphone)
        #expect(spans.first?.startMilliseconds == 0)
        #expect((spans.first?.endMilliseconds ?? 0) >= 500)
    }

    @Test
    func boundsRoundingOverlapAndKeepsTheMaximumTimelineTail() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let long = alternatingTone(frameCount: 4_800)
        let nested = alternatingTone(frameCount: 10)
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: long + nested,
            chunks: [
                ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: long.count),
                ChunkFixture(
                    timestampMilliseconds: 299,
                    frameOffset: Int64(long.count),
                    frameCount: nested.count
                ),
            ]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        #expect(spans.first?.endMilliseconds == 500)

        let invalid = try fixture.capture(tracks: [TrackFixture(
            source: .system,
            samples: long + nested,
            chunks: [
                ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: long.count),
                ChunkFixture(
                    timestampMilliseconds: 200,
                    frameOffset: Int64(long.count),
                    frameCount: nested.count
                ),
            ]
        )])
        #expect(throws: MeetingTimelineAudioError.overlappingTimelineFrames(source: .system)) {
            _ = try MeetingTimelineAudio(capture: invalid)
        }
    }

    @Test
    func reconstructsCompactFrameOffsetsAndTimelineGapsInWAV() throws {
        let fixture = try MeetingTimelineAudioFixture()
        var compact = [Float](repeating: 0, count: 27_000)
        compact.replaceSubrange(3_000..<12_600, with: alternatingTone(frameCount: 9_600))
        compact.replaceSubrange(15_000..<24_600, with: alternatingTone(frameCount: 9_600))
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: compact,
            chunks: [
                ChunkFixture(timestampMilliseconds: 900, frameOffset: 3_000, frameCount: 9_600),
                ChunkFixture(timestampMilliseconds: 3_000, frameOffset: 15_000, frameCount: 9_600),
            ]
        )])
        let timeline = try MeetingTimelineAudio(capture: capture)
        let span = try #require(try timeline.speechSpans().first)

        let wavURL = try timeline.writeWAV(for: span, to: fixture.url)
        let wavSamples = try floatWAVSamples(at: wavURL)

        #expect(span.startMilliseconds == 700)
        #expect(span.endMilliseconds == 1_700)
        #expect(wavSamples.count == 16_000)
        #expect(wavSamples[0] == 0)
        #expect(wavSamples[3_199] == 0)
        #expect(abs(wavSamples[3_200]) == 0.2)
        #expect(abs(wavSamples[12_799]) == 0.2)
        #expect(wavSamples[12_800] == 0)
        #expect(wavSamples[15_999] == 0)
    }

    @Test
    func rejectsInvalidFilesAndChunkBoundsWithExactErrors() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let shortURL = try fixture.writeTrack(source: .microphone, samples: [0.1])
        let wrongSize = MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: [MeetingAudioTrack(
                source: .microphone,
                fileURL: shortURL,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: 2
            )],
            chunks: [],
            discontinuities: [],
            failures: []
        )
        #expect(throws: MeetingTimelineAudioError.invalidTrackFileSize(
            source: .microphone,
            expectedBytes: 8,
            actualBytes: 4
        )) {
            _ = try MeetingTimelineAudio(capture: wrongSize)
        }

        let samples = [Float](repeating: 0.1, count: 100)
        let trackURL = try fixture.writeTrack(source: .system, samples: samples)
        let outOfBounds = MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: [MeetingAudioTrack(
                source: .system,
                fileURL: trackURL,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: 100
            )],
            chunks: [MeetingAudioChunk(
                source: .system,
                timestampMilliseconds: 0,
                sourceTimestamp: 0,
                frameOffset: 50,
                frameCount: 51
            )],
            discontinuities: [],
            failures: []
        )
        #expect(throws: MeetingTimelineAudioError.chunkOutOfTrackBounds(
            source: .system,
            index: 0
        )) {
            _ = try MeetingTimelineAudio(capture: outOfBounds)
        }

        let directoryTrack = fixture.url.appendingPathComponent("not-a-track")
        try FileManager.default.createDirectory(at: directoryTrack, withIntermediateDirectories: false)
        let notRegular = MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: [MeetingAudioTrack(
                source: .microphone,
                fileURL: directoryTrack,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: 0
            )],
            chunks: [],
            discontinuities: [],
            failures: []
        )
        #expect(throws: MeetingTimelineAudioError.trackNotRegularFile(.microphone)) {
            _ = try MeetingTimelineAudio(capture: notRegular)
        }
    }

    @Test
    func writesOwnerOnlyFloatWAVAndLeavesSuccessfulCleanupToCaller() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let samples = voicedSamples(
            durationMilliseconds: 2_400,
            rangesMilliseconds: [900..<1_500]
        )
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .system,
            samples: samples,
            chunks: [ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: samples.count)]
        )])
        let output: URL = try {
            let timeline = try MeetingTimelineAudio(capture: capture)
            let span = try #require(try timeline.speechSpans().first)
            return try timeline.writeWAV(for: span, to: fixture.url)
        }()

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        let owner = try #require(attributes[.ownerAccountID] as? NSNumber).uint32Value
        let data = try Data(contentsOf: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(permissions == 0o600)
        #expect(owner == Darwin.geteuid())
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(littleEndianUInt16(data, offset: 20) == 3)
        #expect(littleEndianUInt32(data, offset: 24) == 16_000)
        #expect(littleEndianUInt32(data, offset: 40) == 64_000)
        #expect(data.count == 44 + 64_000)

        try FileManager.default.removeItem(at: output)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func splitsLongGroupsAndNeverExceedsThirtySeconds() throws {
        let fixture = try MeetingTimelineAudioFixture()
        let samples = voicedSamples(
            durationMilliseconds: 35_000,
            rangesMilliseconds: [0..<29_000, 29_300..<35_000]
        )
        let capture = try fixture.capture(tracks: [TrackFixture(
            source: .microphone,
            samples: samples,
            chunks: [ChunkFixture(timestampMilliseconds: 0, frameOffset: 0, frameCount: samples.count)]
        )])

        let spans = try MeetingTimelineAudio(capture: capture).speechSpans()

        let first = try #require(spans.first)
        let last = try #require(spans.last)
        #expect(spans.count == 2)
        #expect(first.startMilliseconds == 0)
        #expect(last.endMilliseconds == 35_200)
        #expect(spans.allSatisfy { $0.endMilliseconds - $0.startMilliseconds <= 30_000 })
    }
}

private struct TrackFixture {
    let source: MeetingAudioSource
    let samples: [Float]
    let chunks: [ChunkFixture]
}

private struct ChunkFixture {
    let timestampMilliseconds: Int64
    let frameOffset: Int64
    let frameCount: Int
}

private final class MeetingTimelineAudioFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTimelineAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func capture(tracks: [TrackFixture]) throws -> MeetingAudioCaptureSummary {
        var manifestTracks: [MeetingAudioTrack] = []
        var manifestChunks: [MeetingAudioChunk] = []
        for track in tracks {
            let trackURL = try writeTrack(source: track.source, samples: track.samples)
            manifestTracks.append(MeetingAudioTrack(
                source: track.source,
                fileURL: trackURL,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: Int64(track.samples.count)
            ))
            manifestChunks.append(contentsOf: track.chunks.map { chunk in
                MeetingAudioChunk(
                    source: track.source,
                    timestampMilliseconds: chunk.timestampMilliseconds,
                    sourceTimestamp: Double(chunk.timestampMilliseconds) / 1_000,
                    frameOffset: chunk.frameOffset,
                    frameCount: chunk.frameCount
                )
            })
        }
        return MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: manifestTracks,
            chunks: manifestChunks,
            discontinuities: [],
            failures: []
        )
    }

    func writeTrack(source: MeetingAudioSource, samples: [Float]) throws -> URL {
        let destination = url.appendingPathComponent("\(source.rawValue)-\(UUID().uuidString).pcm")
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingTimelineAudioError.wavWriteFailed
        }
        return destination
    }
}

private func voicedSamples(
    durationMilliseconds: Int,
    rangesMilliseconds: [Range<Int>]
) -> [Float] {
    let frameCount = durationMilliseconds * MeetingAudioWriter.sampleRate / 1_000
    var result = [Float](repeating: 0, count: frameCount)
    for range in rangesMilliseconds {
        let start = range.lowerBound * MeetingAudioWriter.sampleRate / 1_000
        let end = range.upperBound * MeetingAudioWriter.sampleRate / 1_000
        result.replaceSubrange(start..<end, with: alternatingTone(frameCount: end - start))
    }
    return result
}

private func alternatingTone(frameCount: Int) -> [Float] {
    (0..<frameCount).map { $0.isMultiple(of: 2) ? 0.2 : -0.2 }
}

private func floatWAVSamples(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    let sampleData = data.dropFirst(44)
    var result = [Float](repeating: 0, count: sampleData.count / MemoryLayout<Float>.size)
    _ = result.withUnsafeMutableBytes { destination in
        sampleData.copyBytes(to: destination)
    }
    return result
}

private func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}
