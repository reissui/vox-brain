import Foundation

/// Builds bounded, conversational preview windows on the shared capture timeline.
///
/// Each input source owns an independent state machine. A window starts when a
/// voiced analysis frame is observed, carrying at most 500 ms of preceding
/// context. Once a window has collected four seconds, a 1.2 second pause closes
/// it; continuously voiced windows are capped at twenty seconds. Every emitted
/// window must pass the same `SpeechActivityGate` used by the rest of the speech
/// pipeline.
struct LivePreviewSegmenter: Sendable {
    static let leadingContextMilliseconds: Int64 = 500
    static let trailingContextMilliseconds: Int64 = 500
    static let minimumCaptureMilliseconds: Int64 = 4_000
    static let closingSilenceMilliseconds: Int64 = 1_200
    static let maximumCaptureMilliseconds: Int64 = 20_000

    struct Segment: Equatable, Sendable {
        let source: MeetingAudioSource
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let samples: [Float]
    }

    private static let sampleRate = SpeechActivityGate.sampleRate
    private static let analysisFrameCount = SpeechActivityGate.samplesPerFrame
    private static let leadingFrameCount = frames(for: leadingContextMilliseconds)
    private static let trailingFrameCount = frames(for: trailingContextMilliseconds)
    private static let minimumCaptureFrameCount = frames(for: minimumCaptureMilliseconds)
    private static let closingSilenceFrameCount = frames(for: closingSilenceMilliseconds)
    private static let maximumCaptureFrameCount = frames(for: maximumCaptureMilliseconds)

    private let gate: SpeechActivityGate
    private var sources: [MeetingAudioSource: SourceState] = [:]

    init(gate: SpeechActivityGate = SpeechActivityGate()) {
        self.gate = gate
    }

    /// Appends normalized Float32 mono samples at their absolute capture frame.
    /// Returned windows are already speech-gated and safe to offer to VoxType.
    mutating func append(
        source: MeetingAudioSource,
        startFrame: Int64,
        samples: [Float]
    ) -> [Segment] {
        guard startFrame >= 0, !samples.isEmpty else { return [] }
        var state = sources[source] ?? SourceState()
        let emitted = state.append(
            source: source,
            startFrame: startFrame,
            samples: samples,
            gate: gate
        )
        sources[source] = state
        return emitted
    }

    /// Flushes a short stop/pause tail only when the shared gate finds sustained
    /// speech. Merely buffered leading context is never emitted.
    mutating func flush(source: MeetingAudioSource? = nil) -> [Segment] {
        let selected = source.map { [$0] } ?? MeetingAudioSource.allCases
        var emitted: [Segment] = []
        for source in selected {
            guard var state = sources[source] else { continue }
            emitted.append(contentsOf: state.flush(source: source, gate: gate))
            sources[source] = state
        }
        return emitted.sorted(by: Self.precedes)
    }

    /// Drops active and contextual audio without producing a tail.
    mutating func cancel() {
        sources.removeAll(keepingCapacity: false)
    }

    private static func frames(for milliseconds: Int64) -> Int {
        Int(milliseconds) * sampleRate / 1_000
    }

    private static func milliseconds(for frame: Int64) -> Int64 {
        Int64((Double(frame) * 1_000 / Double(sampleRate)).rounded())
    }

    private static func precedes(_ lhs: Segment, _ rhs: Segment) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private struct SourceState: Sendable {
        private var nextInputFrame: Int64?
        private var analysisStartFrame: Int64?
        private var analysisSamples: [Float] = []
        private var contextStartFrame: Int64?
        private var contextSamples: [Float] = []
        private var active: ActiveWindow?

        mutating func append(
            source: MeetingAudioSource,
            startFrame: Int64,
            samples: [Float],
            gate: SpeechActivityGate
        ) -> [Segment] {
            var incomingStart = startFrame
            var incoming = samples
            var emitted: [Segment] = []

            if let expectedStart = nextInputFrame {
                if incomingStart < expectedStart {
                    let obsolete = min(incoming.count, Int(expectedStart - incomingStart))
                    incoming.removeFirst(obsolete)
                    incomingStart += Int64(obsolete)
                } else if incomingStart > expectedStart {
                    emitted.append(contentsOf: appendGap(
                        source: source,
                        from: expectedStart,
                        to: incomingStart,
                        gate: gate
                    ))
                }
            }
            guard !incoming.isEmpty else {
                emitted.append(contentsOf: drainFrames(source: source, gate: gate))
                return emitted
            }

            if analysisStartFrame == nil { analysisStartFrame = incomingStart }
            analysisSamples.append(contentsOf: incoming)
            nextInputFrame = incomingStart + Int64(incoming.count)
            emitted.append(contentsOf: drainFrames(source: source, gate: gate))
            return emitted
        }

        mutating func flush(
            source: MeetingAudioSource,
            gate: SpeechActivityGate
        ) -> [Segment] {
            var emitted: [Segment] = []
            if !analysisSamples.isEmpty, let frameStart = analysisStartFrame {
                let frame = analysisSamples
                analysisSamples.removeAll(keepingCapacity: false)
                analysisStartFrame = nil
                if let segment = processFrame(
                    source: source,
                    startFrame: frameStart,
                    samples: frame,
                    gate: gate
                ) { emitted.append(segment) }
            }
            guard let candidate = active else {
                nextInputFrame = nil
                contextSamples.removeAll(keepingCapacity: false)
                contextStartFrame = nil
                return emitted
            }
            active = nil
            nextInputFrame = nil
            contextSamples.removeAll(keepingCapacity: false)
            contextStartFrame = nil
            let trailingEnd = min(
                candidate.startFrame + Int64(candidate.samples.count),
                candidate.lastVoicedEndFrame
                    + Int64(LivePreviewSegmenter.trailingFrameCount)
            )
            if let segment = makeSegment(
                source: source,
                window: candidate.ending(at: trailingEnd),
                gate: gate
            ) {
                emitted.append(segment)
            }
            return emitted
        }

        private mutating func appendGap(
            source: MeetingAudioSource,
            from startFrame: Int64,
            to endFrame: Int64,
            gate: SpeechActivityGate
        ) -> [Segment] {
            guard endFrame > startFrame else { return [] }
            if analysisStartFrame == nil { analysisStartFrame = startFrame }

            // No state machine needs more than one hard-cap interval to resolve
            // a gap. Bounding synthesis keeps timestamp jumps memory-safe.
            let relevant = max(
                LivePreviewSegmenter.maximumCaptureFrameCount
                    + LivePreviewSegmenter.closingSilenceFrameCount,
                LivePreviewSegmenter.leadingFrameCount
            )
            let gapCount = endFrame - startFrame
            if gapCount > Int64(relevant) {
                analysisSamples.append(contentsOf: repeatElement(0, count: relevant))
                let emitted = drainFrames(source: source, gate: gate)
                analysisSamples.removeAll(keepingCapacity: false)
                analysisStartFrame = endFrame
                contextSamples.removeAll(keepingCapacity: false)
                contextStartFrame = nil
                return emitted
            } else {
                analysisSamples.append(contentsOf: repeatElement(0, count: Int(gapCount)))
                return []
            }
        }

        private mutating func drainFrames(
            source: MeetingAudioSource,
            gate: SpeechActivityGate
        ) -> [Segment] {
            var emitted: [Segment] = []
            while analysisSamples.count >= LivePreviewSegmenter.analysisFrameCount,
                  let frameStart = analysisStartFrame {
                let frame = Array(analysisSamples.prefix(LivePreviewSegmenter.analysisFrameCount))
                analysisSamples.removeFirst(LivePreviewSegmenter.analysisFrameCount)
                analysisStartFrame = frameStart
                    + Int64(LivePreviewSegmenter.analysisFrameCount)
                if let segment = processFrame(
                    source: source,
                    startFrame: frameStart,
                    samples: frame,
                    gate: gate
                ) {
                    emitted.append(segment)
                }
            }
            if let window = active,
               !analysisSamples.isEmpty,
               window.samples.count + analysisSamples.count
                >= LivePreviewSegmenter.maximumCaptureFrameCount,
               let frameStart = analysisStartFrame {
                let needed = LivePreviewSegmenter.maximumCaptureFrameCount
                    - window.samples.count
                let frame = Array(analysisSamples.prefix(needed))
                analysisSamples.removeFirst(needed)
                analysisStartFrame = frameStart + Int64(needed)
                if let segment = processFrame(
                    source: source,
                    startFrame: frameStart,
                    samples: frame,
                    gate: gate
                ) {
                    emitted.append(segment)
                }
            }
            if analysisSamples.isEmpty { analysisStartFrame = nil }
            return emitted
        }

        private mutating func processFrame(
            source: MeetingAudioSource,
            startFrame: Int64,
            samples: [Float],
            gate: SpeechActivityGate
        ) -> Segment? {
            let voiced = isVoicedFrame(samples)
            var emitted: Segment?
            var contextOffset = 0

            if active == nil, voiced {
                active = ActiveWindow(
                    startFrame: contextStartFrame ?? startFrame,
                    samples: contextSamples,
                    lastVoicedEndFrame: startFrame
                )
                contextSamples.removeAll(keepingCapacity: true)
                contextStartFrame = nil
            }

            if var window = active {
                window.samples.append(contentsOf: samples)
                if voiced {
                    window.lastVoicedEndFrame = startFrame + Int64(samples.count)
                }
                active = window

                let captured = window.samples.count
                let silence = Int(startFrame + Int64(samples.count) - window.lastVoicedEndFrame)
                if captured >= LivePreviewSegmenter.maximumCaptureFrameCount {
                    let capped = window.capped(to: LivePreviewSegmenter.maximumCaptureFrameCount)
                    emitted = makeSegment(source: source, window: capped, gate: gate)
                    contextOffset = max(
                        0,
                        Int(capped.startFrame + Int64(capped.samples.count) - startFrame)
                    )
                    active = nil
                } else if captured >= LivePreviewSegmenter.minimumCaptureFrameCount,
                          silence >= LivePreviewSegmenter.closingSilenceFrameCount {
                    let trailingEnd = min(
                        window.startFrame + Int64(window.samples.count),
                        window.lastVoicedEndFrame
                            + Int64(LivePreviewSegmenter.trailingFrameCount)
                    )
                    emitted = makeSegment(
                        source: source,
                        window: window.ending(at: trailingEnd),
                        gate: gate
                    )
                    active = nil
                }
            }

            if active == nil, contextOffset < samples.count {
                appendContext(
                    startFrame: startFrame + Int64(contextOffset),
                    samples: Array(samples.dropFirst(contextOffset))
                )
            }
            return emitted
        }

        private mutating func appendContext(startFrame: Int64, samples: [Float]) {
            if contextStartFrame == nil { contextStartFrame = startFrame }
            contextSamples.append(contentsOf: samples)
            if contextSamples.count > LivePreviewSegmenter.leadingFrameCount {
                let overflow = contextSamples.count - LivePreviewSegmenter.leadingFrameCount
                contextSamples.removeFirst(overflow)
                contextStartFrame = (contextStartFrame ?? startFrame) + Int64(overflow)
            }
        }

        private func makeSegment(
            source: MeetingAudioSource,
            window: ActiveWindow,
            gate: SpeechActivityGate
        ) -> Segment? {
            guard !window.samples.isEmpty,
                  gate.evaluate(window.samples).isSpeechBearing else { return nil }
            return Segment(
                source: source,
                startMilliseconds: LivePreviewSegmenter.milliseconds(for: window.startFrame),
                endMilliseconds: LivePreviewSegmenter.milliseconds(
                    for: window.startFrame + Int64(window.samples.count)
                ),
                samples: window.samples
            )
        }

        private func isVoicedFrame(_ samples: [Float]) -> Bool {
            guard !samples.isEmpty else { return false }
            var squares = 0.0
            var peak: Float = 0
            for rawSample in samples {
                let sample = rawSample.isFinite ? rawSample : 0
                squares += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }
            let rms = Float((squares / Double(samples.count)).squareRoot())
            return rms >= SpeechActivityGate.minimumVoicedRMS
                && peak >= SpeechActivityGate.minimumVoicedPeak
        }
    }

    private struct ActiveWindow: Sendable {
        let startFrame: Int64
        var samples: [Float]
        var lastVoicedEndFrame: Int64

        func capped(to frameCount: Int) -> ActiveWindow {
            ActiveWindow(
                startFrame: startFrame,
                samples: Array(samples.prefix(frameCount)),
                lastVoicedEndFrame: min(
                    lastVoicedEndFrame,
                    startFrame + Int64(frameCount)
                )
            )
        }

        func ending(at endFrame: Int64) -> ActiveWindow {
            let count = max(0, min(samples.count, Int(endFrame - startFrame)))
            return ActiveWindow(
                startFrame: startFrame,
                samples: Array(samples.prefix(count)),
                lastVoicedEndFrame: min(lastVoicedEndFrame, endFrame)
            )
        }
    }
}
