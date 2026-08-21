import Foundation

protocol MeetingSpeakerDiarizing: Sendable {
    func assign(utterances: [MeetingUtterance], systemTrack: MeetingAudioTrack?) -> [UUID: String]
}

struct MeetingSpeakerDiarizer: MeetingSpeakerDiarizing {
    static let minimumSpanMilliseconds: Int64 = 500
    private let embedder: any SpeakerEmbeddingClient
    private let gate = SpeechActivityGate()
    private let clusterer = MeetingSpeakerClusterer()

    init(embedder: any SpeakerEmbeddingClient) {
        self.embedder = embedder
    }

    func assign(
        utterances: [MeetingUtterance],
        systemTrack: MeetingAudioTrack?
    ) -> [UUID: String] {
        guard let systemTrack else { return [:] }
        let candidates = utterances
            .filter { !$0.suppressed && $0.source == .system }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
            .filter { $0.endMilliseconds - $0.startMilliseconds >= Self.minimumSpanMilliseconds }
        var points: [MeetingSpeakerClusterer.Point] = []
        for utterance in candidates {
            guard let pcm = MeetingSystemAudioSlicer.samples(
                track: systemTrack,
                startMilliseconds: utterance.startMilliseconds,
                endMilliseconds: utterance.endMilliseconds
            ), gate.evaluate(pcm).isSpeechBearing,
               let vector = embedder.embed(pcm: pcm, sampleRate: systemTrack.sampleRate)
            else { continue }
            points.append(.init(
                id: utterance.id,
                startMilliseconds: utterance.startMilliseconds,
                vector: vector
            ))
        }
        return clusterer.cluster(points)
    }
}
