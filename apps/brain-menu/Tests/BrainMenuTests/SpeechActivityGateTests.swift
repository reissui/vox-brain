import Testing
@testable import BrainMenu

struct SpeechActivityGateTests {
    private let gate = SpeechActivityGate()

    @Test
    func silenceDoesNotPassAndReportsClampedNoiseFloor() {
        let result = gate.evaluate(samples(frameCount: 40, value: 0))

        #expect(!result.isSpeechBearing)
        #expect(result.frameCount == 40)
        #expect(result.maximumRMS == 0)
        #expect(result.estimatedNoiseFloor == SpeechActivityGate.minimumNoiseFloor)
        #expect(result.voicedMilliseconds == 0)
        #expect(result.voicedRatio == 0)
    }

    @Test
    func steadyFanNoiseDoesNotPass() {
        let result = gate.evaluate(samples(frameCount: 40, value: 0.010))

        #expect(!result.isSpeechBearing)
        #expect(isClose(result.maximumRMS, 0.010))
        #expect(isClose(result.estimatedNoiseFloor, 0.010))
        #expect(result.voicedMilliseconds == 0)
    }

    @Test
    func oneLoudSampleDoesNotPass() {
        var input = samples(frameCount: 40, value: 0)
        input[SpeechActivityGate.samplesPerFrame * 20] = 1

        let result = gate.evaluate(input)

        #expect(!result.isSpeechBearing)
        #expect(result.maximumRMS > 0.045)
        #expect(result.voicedMilliseconds == 30)
        #expect(isClose(result.voicedRatio, 1.0 / 40.0))
    }

    @Test
    func sparseImpulsesCannotAccumulateEnoughVoicedFrames() {
        var input = samples(frameCount: 80, value: 0)
        for frame in stride(from: 0, to: 80, by: 10) {
            input[frame * SpeechActivityGate.samplesPerFrame] = 1
        }

        let result = gate.evaluate(input)

        #expect(!result.isSpeechBearing)
        #expect(result.voicedMilliseconds == 240)
        #expect(isClose(result.voicedRatio, 0.10))
    }

    @Test
    func sustainedSpeechLikeSamplesPass() {
        var input = samples(frameCount: 50, value: 0.006)
        replaceFrames(10..<30, in: &input, with: 0.080)

        let result = gate.evaluate(input)

        #expect(result.isSpeechBearing)
        #expect(result.frameCount == 50)
        #expect(isClose(result.maximumRMS, 0.080))
        #expect(isClose(result.estimatedNoiseFloor, 0.006))
        #expect(result.voicedMilliseconds == 600)
        #expect(isClose(result.voicedRatio, 0.40))
    }

    @Test
    func peakThresholdIsInclusive() {
        var input = samples(frameCount: 80, value: 0)
        for frame in 0..<10 {
            let start = frame * SpeechActivityGate.samplesPerFrame
            input.replaceSubrange(
                start..<(start + 96),
                with: repeatElement(SpeechActivityGate.minimumVoicedPeak, count: 96)
            )
        }

        let atBoundary = gate.evaluate(input)
        #expect(atBoundary.isSpeechBearing)

        let belowPeak = input.map { sample in
            sample == SpeechActivityGate.minimumVoicedPeak
                ? SpeechActivityGate.minimumVoicedPeak.nextDown
                : sample
        }
        #expect(!gate.evaluate(belowPeak).isSpeechBearing)
    }

    @Test
    func inclusiveDurationAndRatioBoundariesPass() {
        var input = samples(frameCount: 80, value: 0)
        replaceFrames(0..<10, in: &input, with: 0.080)

        let result = gate.evaluate(input)

        #expect(result.isSpeechBearing)
        #expect(result.voicedMilliseconds == 300)
        #expect(isClose(result.voicedRatio, 0.125))
    }

    @Test
    func tenVoicedFramesFailWhenRatioIsBelowTwelvePercent() {
        var input = samples(frameCount: 84, value: 0)
        replaceFrames(0..<10, in: &input, with: 0.080)

        let result = gate.evaluate(input)

        #expect(!result.isSpeechBearing)
        #expect(result.voicedMilliseconds == 300)
        #expect(result.voicedRatio < SpeechActivityGate.minimumVoicedRatio)
    }

    @Test
    func fewerThanTenVoicedFramesCannotPassEvenWhenRatioIsHigh() {
        let result = gate.evaluate(samples(frameCount: 9, value: 0.080))

        #expect(!result.isSpeechBearing)
        #expect(result.estimatedNoiseFloor == SpeechActivityGate.maximumNoiseFloor)
        #expect(result.voicedMilliseconds == 270)
        #expect(result.voicedRatio == 1)
    }

    @Test
    func partialFinalFrameUsesActualSamplesAndDuration() {
        var input = samples(frameCount: 9, value: 0.080)
        input.append(0.080)

        let result = gate.evaluate(input)

        #expect(result.frameCount == 10)
        #expect(!result.isSpeechBearing)
        #expect(isClose(result.voicedMilliseconds, 270.0625))
        #expect(result.voicedRatio == 1)
    }

    @Test
    func metricsAreRepeatable() {
        var input = samples(frameCount: 40, value: 0.007)
        replaceFrames(5..<20, in: &input, with: 0.065)
        input.append(contentsOf: [0.2, -0.2, 0.2])

        let first = gate.evaluate(input)

        for _ in 0..<20 {
            #expect(gate.evaluate(input) == first)
        }
    }

    private func samples(frameCount: Int, value: Float) -> [Float] {
        [Float](
            repeating: value,
            count: frameCount * SpeechActivityGate.samplesPerFrame
        )
    }

    private func replaceFrames(
        _ frames: Range<Int>,
        in samples: inout [Float],
        with value: Float
    ) {
        let sampleRange = (frames.lowerBound * SpeechActivityGate.samplesPerFrame)..<(
            frames.upperBound * SpeechActivityGate.samplesPerFrame
        )
        samples.replaceSubrange(
            sampleRange,
            with: repeatElement(value, count: sampleRange.count)
        )
    }

    private func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.000_001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func isClose(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 0.000_001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
