import Testing
@testable import BrainMenu

struct CoreMLSpeakerEmbeddingClientTests {
    @Test
    func missingBundleModelReturnsNil() {
        #expect(CoreMLSpeakerEmbeddingClient(modelURL: nil).embed(pcm: [0.25], sampleRate: 16_000) == nil)
    }
}
