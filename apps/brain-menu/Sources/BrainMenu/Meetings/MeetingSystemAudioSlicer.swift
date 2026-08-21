import Foundation

/// Reads one utterance-sized window of retained system audio.
///
/// Capture tracks are compact: a track file holds only the frames that were
/// actually delivered, and `MeetingAudioCaptureSummary.chunks` maps them onto
/// the shared meeting timeline. Utterance timestamps are timeline positions,
/// so they must be translated through that manifest rather than used as file
/// offsets. Any unreadable or unmappable region fails closed.
struct MeetingSystemAudioSlicer: Sendable {
    private let timeline: MeetingTimelineAudio

    init?(capture: MeetingAudioCaptureSummary) {
        guard capture.chunks.contains(where: { $0.source == .system }),
              let timeline = try? MeetingTimelineAudio(capture: capture) else { return nil }
        self.timeline = timeline
    }

    func systemSamples(startMilliseconds: Int64, endMilliseconds: Int64) -> [Float]? {
        guard startMilliseconds >= 0, endMilliseconds > startMilliseconds else { return nil }
        return try? timeline.samples(for: MeetingTimelineSpeechSpan(
            source: .system,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        ))
    }
}
