import Testing
@testable import BrainMenu

struct LivePreviewSegmenterTests {
    @Test
    func silenceClosesAfterMinimumCaptureWithBoundedContext() {
        var segmenter = LivePreviewSegmenter()
        let samples = audio([
            (0.5, 0),
            (1.0, 0.2),
            (2.6, 0),
        ])

        let segments = segmenter.append(
            source: .microphone,
            startFrame: 0,
            samples: samples
        )

        #expect(segments.count == 1)
        #expect(segments.first?.startMilliseconds == 0)
        #expect((segments.first?.endMilliseconds ?? 0) - 1_500 <= 500)
        #expect((segments.first?.endMilliseconds ?? 0) >= 1_980)
    }

    @Test
    func continuouslyVoicedWindowUsesHardCap() {
        var segmenter = LivePreviewSegmenter()

        let segments = segmenter.append(
            source: .system,
            startFrame: 0,
            samples: audio([(21.0, 0.2)])
        )

        #expect(segments.count == 1)
        #expect(segments.first?.startMilliseconds == 0)
        #expect(segments.first?.endMilliseconds == 20_000)
        #expect(segments.first?.samples.count == 20 * SpeechActivityGate.sampleRate)
    }

    @Test
    func timestampsStayOnCaptureTimelineAndLeadingContextIsAtMostHalfSecond() {
        var segmenter = LivePreviewSegmenter()
        let startFrame = Int64(10 * SpeechActivityGate.sampleRate)

        let segments = segmenter.append(
            source: .microphone,
            startFrame: startFrame,
            samples: audio([
                (0.8, 0),
                (1.0, 0.2),
                (2.5, 0),
            ])
        )

        let segment = segments.first
        #expect(segments.count == 1)
        #expect(segment?.startMilliseconds == 10_280)
        #expect((segment?.endMilliseconds ?? 0) - 11_800 <= 500)
        #expect((10_780 - (segment?.startMilliseconds ?? 0)) <= 500)
    }

    @Test
    func sourceStateMachinesCloseIndependently() {
        var segmenter = LivePreviewSegmenter()

        let microphone = segmenter.append(
            source: .microphone,
            startFrame: 0,
            samples: audio([(6.0, 0.2)])
        )
        let system = segmenter.append(
            source: .system,
            startFrame: 0,
            samples: audio([(1.0, 0.2), (3.1, 0)])
        )

        #expect(microphone.isEmpty)
        #expect(system.count == 1)
        #expect(system.first?.source == .system)
        let flushed = segmenter.flush(source: .microphone)
        #expect(flushed.count == 1)
        #expect(flushed.first?.endMilliseconds == 6_000)
    }

    @Test
    func weakAndSparseTailsAreRejectedBySharedGate() {
        var shortSegmenter = LivePreviewSegmenter()
        _ = shortSegmenter.append(
            source: .microphone,
            startFrame: 0,
            samples: audio([(0.24, 0.2)])
        )
        #expect(shortSegmenter.flush().isEmpty)

        var sparseSegmenter = LivePreviewSegmenter()
        var sparse = [Float](repeating: 0, count: SpeechActivityGate.sampleRate * 5)
        for frame in 0..<100 {
            sparse[frame * SpeechActivityGate.samplesPerFrame] = 0.5
        }
        _ = sparseSegmenter.append(source: .system, startFrame: 0, samples: sparse)
        #expect(sparseSegmenter.flush().isEmpty)
    }

    @Test
    func stopFlushesSpeechBearingShortTailAndCancelDropsIt() {
        var flushed = LivePreviewSegmenter()
        _ = flushed.append(
            source: .microphone,
            startFrame: 0,
            samples: audio([(0.6, 0.2)])
        )
        #expect(flushed.flush().map(\.endMilliseconds) == [600])

        var cancelled = LivePreviewSegmenter()
        _ = cancelled.append(
            source: .microphone,
            startFrame: 0,
            samples: audio([(0.6, 0.2)])
        )
        cancelled.cancel()
        #expect(cancelled.flush().isEmpty)
    }

    @Test
    func stopFlushTrimsLongPauseToHalfSecondTrailingContext() {
        var segmenter = LivePreviewSegmenter()
        _ = segmenter.append(
            source: .system,
            startFrame: 0,
            samples: audio([(0.6, 0.2), (3.0, 0)])
        )

        let flushed = segmenter.flush()

        #expect(flushed.count == 1)
        #expect(flushed.first?.startMilliseconds == 0)
        #expect(flushed.first?.endMilliseconds == 1_100)
    }

    @Test
    func discontinuousBuffersRetainNewestTimelineContext() {
        var segmenter = LivePreviewSegmenter()
        _ = segmenter.append(
            source: .system,
            startFrame: 0,
            samples: audio([(1.0, 0)])
        )
        let segments = segmenter.append(
            source: .system,
            startFrame: Int64(1.5 * Double(SpeechActivityGate.sampleRate)),
            samples: audio([(1.0, 0.2), (3.1, 0)])
        )

        #expect(segments.count == 1)
        #expect(segments.first?.startMilliseconds == 1_000)
        #expect(segments.first?.endMilliseconds == 3_020)
    }

    private func audio(_ spans: [(seconds: Double, amplitude: Float)]) -> [Float] {
        spans.flatMap { span in
            let count = Int((span.seconds * Double(SpeechActivityGate.sampleRate)).rounded())
            return (0..<count).map { index in
                span.amplitude == 0
                    ? 0
                    : (index.isMultiple(of: 2) ? span.amplitude : -span.amplitude)
            }
        }
    }
}
