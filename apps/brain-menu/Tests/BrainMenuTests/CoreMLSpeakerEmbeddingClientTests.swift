import Foundation
import Testing
@testable import BrainMenu

struct CoreMLSpeakerEmbeddingClientTests {
    @Test
    func missingBundleModelReturnsNil() {
        let client = CoreMLSpeakerEmbeddingClient(modelURL: nil)
        #expect(client.embed(pcm: [0.25], sampleRate: 16_000) == nil)
        #expect(client.embed(pcm: [0.25], sampleRate: 16_000) == nil)
    }

    @Test
    func unloadableModelFailsClosedOnEveryCall() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mlmodelc")
        let client = CoreMLSpeakerEmbeddingClient(modelURL: url)
        #expect(client.embed(pcm: [0.25, -0.25], sampleRate: 16_000) == nil)
        #expect(client.embed(pcm: [0.25, -0.25], sampleRate: 16_000) == nil)
    }

    @Test
    func rejectsUnsupportedInput() {
        let client = CoreMLSpeakerEmbeddingClient(modelURL: nil)
        #expect(client.embed(pcm: [], sampleRate: 16_000) == nil)
        #expect(client.embed(pcm: [0.25], sampleRate: 48_000) == nil)
    }
}
