protocol SpeakerEmbeddingClient: Sendable {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]?
}

struct MissingSpeakerEmbeddingClient: SpeakerEmbeddingClient {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]? { nil }
}
