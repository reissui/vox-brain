import Foundation

protocol MeetingSpeakerDiarizing: Sendable {
    func assign(
        utterances: [MeetingUtterance],
        capture: MeetingAudioCaptureSummary?
    ) -> [UUID: String]
}

struct MeetingSpeakerDiarizer: MeetingSpeakerDiarizing {
    static let minimumSpanMilliseconds: Int64 = 500
    /// Matches the planner's bounded final span, so one embedding never loads
    /// an unbounded region of a long meeting.
    static let maximumSpanMilliseconds: Int64 = 30_000
    private let embedder: any SpeakerEmbeddingClient
    private let gate = SpeechActivityGate()
    private let clusterer = MeetingSpeakerClusterer()

    init(embedder: any SpeakerEmbeddingClient) {
        self.embedder = embedder
    }

    func assign(
        utterances: [MeetingUtterance],
        capture: MeetingAudioCaptureSummary?
    ) -> [UUID: String] {
        guard let capture, let slicer = MeetingSystemAudioSlicer(capture: capture) else {
            return [:]
        }
        let candidates = utterances
            .filter { !$0.suppressed && $0.source == .system }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
            .filter { $0.endMilliseconds - $0.startMilliseconds >= Self.minimumSpanMilliseconds }
        var points: [MeetingSpeakerClusterer.Point] = []
        for utterance in candidates {
            let end = min(
                utterance.endMilliseconds,
                utterance.startMilliseconds + Self.maximumSpanMilliseconds
            )
            guard let pcm = slicer.systemSamples(
                startMilliseconds: utterance.startMilliseconds,
                endMilliseconds: end
            ), gate.evaluate(pcm).isSpeechBearing,
               let vector = embedder.embed(pcm: pcm, sampleRate: MeetingAudioWriter.sampleRate)
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
