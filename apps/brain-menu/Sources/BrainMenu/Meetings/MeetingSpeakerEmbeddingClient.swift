protocol SpeakerEmbeddingClient: Sendable {
    func embed(pcm: [Float], sampleRate: Int) -> [Float]?
}
