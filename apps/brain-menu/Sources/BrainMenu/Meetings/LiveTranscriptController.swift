import Foundation
import Observation

@MainActor
@Observable
final class LiveTranscriptController {
    private(set) var utterances: [MeetingUtterance] = []
    private(set) var errors: [LiveTranscriptFailure] = []
    private(set) var previewLag: LiveTranscriptPreviewLagState = .current
    private(set) var isFinalizing = false
    private(set) var isFinalized = false
    private(set) var finalEngine: String?

    @ObservationIgnored private let service: LiveTranscriptionService
    @ObservationIgnored private var isConnected = false
    @ObservationIgnored private var utteranceCheckpointHandler: (([MeetingUtterance]) -> Void)?

    init(service: LiveTranscriptionService) {
        self.service = service
    }

    func setUtteranceCheckpointHandler(
        _ handler: @escaping ([MeetingUtterance]) -> Void
    ) {
        utteranceCheckpointHandler = handler
    }

    func append(_ buffer: MeetingAudioSampleBuffer) async {
        await connectIfNeeded()
        do {
            try await service.append(buffer)
        } catch {
            receive(.failure(LiveTranscriptFailure(
                source: buffer.source,
                phase: .preview,
                startMilliseconds: nil,
                endMilliseconds: nil,
                message: String(error.localizedDescription.prefix(240))
            )))
        }
    }

    func waitForPendingPreview() async {
        await connectIfNeeded()
        await service.waitForPendingPreview()
    }

    /// Replaces only the preview ranges covered by successful final spans.
    /// Uncovered previews survive a VAD miss or failed final span. Failures stay
    /// in `errors`; they are never converted into transcript utterances.
    func stop(capture: MeetingAudioCaptureSummary) async {
        guard !isFinalizing, !isFinalized else { return }
        await connectIfNeeded()
        isFinalizing = true
        let finalization = await service.stop(capture: capture)
        finalEngine = finalization.effectiveEngine
        guard !finalization.wasCancelled else {
            isFinalizing = false
            return
        }

        let finalUtterances = finalization.segments.compactMap(Self.utterance(from:))
        let preservedPreviews = utterances.filter { preview in
            !finalUtterances.contains { Self.overlaps(preview, $0) }
        }
        utterances = (preservedPreviews + finalUtterances)
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)
        utteranceCheckpointHandler?(utterances)
        let preservedPreviewErrors = errors.filter {
            $0.phase == .preview && !Self.failure($0, overlapsAny: finalUtterances)
        }
        errors = Self.deduplicated(preservedPreviewErrors + finalization.failures)
        let preservedSources = Set(preservedPreviews.map(\.source))
        let retainedLag = finalization.previewLag.droppedChunksBySource.filter {
            preservedSources.contains($0.key)
        }
        previewLag = retainedLag.isEmpty
            ? .current
            : .lagging(droppedChunksBySource: retainedLag)
        isFinalizing = false
        isFinalized = true
    }

    func cancel() async {
        await service.cancel()
        isFinalizing = false
    }

    private func connectIfNeeded() async {
        guard !isConnected else { return }
        isConnected = true
        await service.setEventHandler { [weak self] event in
            await self?.receive(event)
        }
    }

    private func receive(_ event: LiveTranscriptionEvent) {
        switch event {
        case .preview(let segment):
            guard !isFinalized, let utterance = Self.utterance(from: segment) else { return }
            utterances.removeAll { $0.id == utterance.id }
            utterances.append(utterance)
            utterances.sort(by: MeetingUtterance.chronologicallyPrecedes)
            utteranceCheckpointHandler?(utterances)
        case .failure(let failure):
            errors = Self.deduplicated(errors + [failure])
        case .previewLagChanged(let state):
            previewLag = state
        }
    }

    private static func utterance(from segment: LiveTranscriptSegment) -> MeetingUtterance? {
        try? MeetingUtterance(
            id: segment.id,
            source: segment.source,
            startMilliseconds: segment.startMilliseconds,
            endMilliseconds: segment.endMilliseconds,
            text: segment.text,
            baseSpeakerID: segment.source == .microphone ? "you" : "remote",
            humanName: segment.sourceLabel
        )
    }

    private static func overlaps(_ lhs: MeetingUtterance, _ rhs: MeetingUtterance) -> Bool {
        lhs.source == rhs.source
            && min(lhs.endMilliseconds, rhs.endMilliseconds)
                > max(lhs.startMilliseconds, rhs.startMilliseconds)
    }

    private static func failure(
        _ failure: LiveTranscriptFailure,
        overlapsAny utterances: [MeetingUtterance]
    ) -> Bool {
        guard let start = failure.startMilliseconds,
              let end = failure.endMilliseconds else {
            return utterances.contains { $0.source == failure.source }
        }
        return utterances.contains {
            $0.source == failure.source
                && min($0.endMilliseconds, end) > max($0.startMilliseconds, start)
        }
    }

    private static func deduplicated(
        _ failures: [LiveTranscriptFailure]
    ) -> [LiveTranscriptFailure] {
        failures.reduce(into: []) { values, failure in
            if !values.contains(failure) { values.append(failure) }
        }
    }
}
