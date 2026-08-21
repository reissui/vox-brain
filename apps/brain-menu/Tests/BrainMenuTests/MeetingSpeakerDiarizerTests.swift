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
        let track = try Self.writeTrack(seconds: 3, voiced: true)
        let map = MeetingSpeakerDiarizer(embedder: embedder).assign(
            utterances: [mic, first, second, short],
            systemTrack: track
        )
        #expect(map[mic.id] == nil)
        #expect(map[short.id] == nil)
        #expect(map[first.id] == "remote-2")
        #expect(map[second.id] == "remote-3")
    }

    @Test
    func missingTrackOrFailedEmbedReturnsEmpty() throws {
        let remote = try MeetingUtterance(
            source: .system, startMilliseconds: 0, endMilliseconds: 1_000,
            text: "a", baseSpeakerID: "remote"
        )
        let empty = MeetingSpeakerDiarizer(embedder: SequenceSpeakerEmbeddingClient(vectors: []))
            .assign(utterances: [remote], systemTrack: nil)
        #expect(empty.isEmpty)

        let track = try Self.writeTrack(seconds: 1, voiced: true)
        let failed = MeetingSpeakerDiarizer(embedder: NilSpeakerEmbeddingClient())
            .assign(utterances: [remote], systemTrack: track)
        #expect(failed.isEmpty)
    }

    private static func writeTrack(seconds: Int, voiced: Bool) throws -> MeetingAudioTrack {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).f32le.pcm")
        let frames = seconds * MeetingAudioWriter.sampleRate
        let sample: Float = voiced ? 0.25 : 0
        var data = Data(count: frames * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            for i in 0..<frames { buffer[i] = sample }
        }
        try data.write(to: url)
        return MeetingAudioTrack(
            source: .system,
            fileURL: url,
            sampleRate: MeetingAudioWriter.sampleRate,
            channelCount: 1,
            frameCount: Int64(frames)
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

struct NilSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
}
