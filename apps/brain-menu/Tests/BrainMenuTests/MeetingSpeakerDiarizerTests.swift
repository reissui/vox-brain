import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerDiarizerTests {
    @Test
    func assignsRemoteClustersFromSystemEmbeddingsAndSkipsMic() throws {
        let mic = try MeetingUtterance(
            source: .microphone, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "me", baseSpeakerID: "you"
        )
        let first = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let second = try MeetingUtterance(
            source: .system, startMilliseconds: 1_000, endMilliseconds: 2_000,
            text: "b", baseSpeakerID: "remote"
        )
        let short = try MeetingUtterance(
            source: .system, startMilliseconds: 2_000, endMilliseconds: 2_200,
            text: "x", baseSpeakerID: "remote"
        )
        let embedder = SequenceSpeakerEmbeddingClient(vectors: [[1, 0], [0, 1]])
        let fixture = try MeetingSystemAudioFixture()
        let capture = try fixture.capture(chunks: [
            .init(timelineMilliseconds: 0, durationMilliseconds: 3_000, level: 0.25),
        ])
        let map = MeetingSpeakerDiarizer(embedder: embedder).assign(
            utterances: [mic, first, second, short],
            capture: capture
        )
        #expect(map[mic.id] == nil)
        #expect(map[short.id] == nil)
        #expect(map[first.id] == "remote-2")
        #expect(map[second.id] == "remote-3")
    }

    /// Capture tracks are compact. An utterance at timeline 10 s can live at
    /// file frame 0, and a naive `milliseconds * sampleRate` file offset reads
    /// past the end of the track instead.
    @Test
    func slicesGappedChunksThroughTimelineMappingNotFileOffsets() throws {
        let fixture = try MeetingSystemAudioFixture()
        let capture = try fixture.capture(chunks: [
            .init(timelineMilliseconds: 10_000, durationMilliseconds: 1_000, level: 0.25),
            .init(timelineMilliseconds: 30_000, durationMilliseconds: 1_000, level: -0.25),
        ])
        let track = try #require(capture.tracks.first { $0.source == .system })
        let naiveByteOffset = 10_000 * Int64(MeetingAudioWriter.sampleRate) / 1_000
            * Int64(MemoryLayout<Float>.size)
        #expect(naiveByteOffset > track.frameCount * Int64(MemoryLayout<Float>.size))

        let early = try MeetingUtterance(
            source: .system, startMilliseconds: 10_000, endMilliseconds: 11_000,
            text: "a", baseSpeakerID: "remote"
        )
        let late = try MeetingUtterance(
            source: .system, startMilliseconds: 30_000, endMilliseconds: 31_000,
            text: "b", baseSpeakerID: "remote"
        )
        let unmapped = try MeetingUtterance(
            source: .system, startMilliseconds: 20_000, endMilliseconds: 21_000,
            text: "gap", baseSpeakerID: "remote"
        )
        let beyondRetainedAudio = try MeetingUtterance(
            source: .system, startMilliseconds: 60_000, endMilliseconds: 61_000,
            text: "past the end", baseSpeakerID: "remote"
        )
        let embedder = PolaritySpeakerEmbeddingClient()
        let map = MeetingSpeakerDiarizer(embedder: embedder).assign(
            utterances: [early, late, unmapped, beyondRetainedAudio],
            capture: capture
        )

        #expect(map[early.id] == "remote-2")
        #expect(map[late.id] == "remote-3")
        #expect(map[unmapped.id] == nil)
        #expect(map[beyondRetainedAudio.id] == nil)
        #expect(embedder.observedLevels == [0.25, -0.25])
    }

    @Test
    func quietSpansAreSkippedBeforeEmbedding() throws {
        let fixture = try MeetingSystemAudioFixture()
        let capture = try fixture.capture(chunks: [
            .init(timelineMilliseconds: 0, durationMilliseconds: 3_000, level: 0),
        ])
        let first = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let second = try MeetingUtterance(
            source: .system, startMilliseconds: 1_000, endMilliseconds: 2_000,
            text: "b", baseSpeakerID: "remote"
        )
        let embedder = PolaritySpeakerEmbeddingClient()
        let map = MeetingSpeakerDiarizer(embedder: embedder).assign(
            utterances: [first, second],
            capture: capture
        )

        #expect(map.isEmpty)
        #expect(embedder.observedLevels.isEmpty)
    }

    @Test
    func missingTrackOrFailedEmbedReturnsEmpty() throws {
        let remote = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let empty = MeetingSpeakerDiarizer(embedder: SequenceSpeakerEmbeddingClient(vectors: []))
            .assign(utterances: [remote], capture: nil)
        #expect(empty.isEmpty)

        let fixture = try MeetingSystemAudioFixture()
        let capture = try fixture.capture(chunks: [
            .init(timelineMilliseconds: 0, durationMilliseconds: 1_000, level: 0.25),
        ])
        let failed = MeetingSpeakerDiarizer(embedder: NilSpeakerEmbeddingClient())
            .assign(utterances: [remote], capture: capture)
        #expect(failed.isEmpty)
    }
}

struct MeetingSystemAudioChunkFixture {
    let timelineMilliseconds: Int64
    let durationMilliseconds: Int
    let level: Float
}

/// Builds a compact system track whose file frames deliberately do not line up
/// with the timeline positions recorded in the manifest.
final class MeetingSystemAudioFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSystemAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func capture(chunks: [MeetingSystemAudioChunkFixture]) throws -> MeetingAudioCaptureSummary {
        var samples: [Float] = []
        var manifestChunks: [MeetingAudioChunk] = []
        for chunk in chunks {
            let frameCount = chunk.durationMilliseconds * MeetingAudioWriter.sampleRate / 1_000
            manifestChunks.append(MeetingAudioChunk(
                source: .system,
                timestampMilliseconds: chunk.timelineMilliseconds,
                sourceTimestamp: Double(chunk.timelineMilliseconds) / 1_000,
                frameOffset: Int64(samples.count),
                frameCount: frameCount
            ))
            samples.append(contentsOf: [Float](repeating: chunk.level, count: frameCount))
        }

        let url = directory.appendingPathComponent("system.f32le.pcm")
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)

        return MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: [MeetingAudioTrack(
                source: .system,
                fileURL: url,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: Int64(samples.count)
            )],
            chunks: manifestChunks,
            discontinuities: [],
            failures: []
        )
    }
}

final class SequenceSpeakerEmbeddingClient: SpeakerEmbeddingClient, @unchecked Sendable {
    let vectors: [[Float]]
    private let lock = NSLock()
    private var index = 0

    init(vectors: [[Float]]) {
        self.vectors = vectors
    }

    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        lock.withLock {
            guard index < vectors.count else { return nil }
            defer { index += 1 }
            return vectors[index]
        }
    }
}

/// Returns a vector determined by the audio it actually received, so a test can
/// prove which region of the compact track was read.
final class PolaritySpeakerEmbeddingClient: SpeakerEmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [Float] = []

    var observedLevels: [Float] {
        lock.withLock { levels }
    }

    func embed(pcm: [Float], sampleRate: Int) -> [Float]? {
        let level = pcm.reduce(Float(0), +) / Float(pcm.count)
        lock.withLock { levels.append(level) }
        return level >= 0 ? [1, 0] : [0, 1]
    }
}

struct NilSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
}
