/// Deterministic, local evidence that an audio window contains sustained speech.
///
/// The gate deliberately uses only normalized mono samples. It performs no file
/// access and has no dependency on a transcription service, so callers can use
/// the same evidence at every point where an audio window might be transcribed.
struct SpeechActivityGate: Sendable {
    static let sampleRate = 16_000
    static let frameDurationMilliseconds = 30
    static let samplesPerFrame = sampleRate * frameDurationMilliseconds / 1_000

    static let minimumNoiseFloor: Float = 0.003
    static let maximumNoiseFloor: Float = 0.020
    static let minimumVoicedRMS: Float = 0.012
    static let noiseFloorMultiplier: Float = 2.5
    static let minimumVoicedPeak: Float = 0.030
    static let minimumVoicedMilliseconds = 300.0
    static let minimumVoicedRatio = 0.12
    static let minimumVoicedFrameCount = 10

    struct Result: Equatable, Sendable {
        let isSpeechBearing: Bool
        let frameCount: Int
        let maximumRMS: Float
        let estimatedNoiseFloor: Float
        let voicedMilliseconds: Double
        let voicedRatio: Double
    }

    /// Evaluates normalized mono `Float` samples recorded at 16 kHz.
    ///
    /// A final partial frame is evaluated over the samples it actually contains.
    /// It counts as one frame in `voicedRatio`, while `voicedMilliseconds` records
    /// its exact duration rather than rounding it up to 30 ms.
    func evaluate(_ samples: [Float]) -> Result {
        guard !samples.isEmpty else {
            return Result(
                isSpeechBearing: false,
                frameCount: 0,
                maximumRMS: 0,
                estimatedNoiseFloor: Self.minimumNoiseFloor,
                voicedMilliseconds: 0,
                voicedRatio: 0
            )
        }

        let frames = stride(from: 0, to: samples.count, by: Self.samplesPerFrame).map {
            frameMetrics(in: samples, from: $0)
        }
        let rmsValues = frames.map(\.rms)
        let noiseFloor = Self.percentile20(rmsValues)
            .clamped(to: Self.minimumNoiseFloor...Self.maximumNoiseFloor)
        let voicedRMSThreshold = max(
            Self.minimumVoicedRMS,
            noiseFloor * Self.noiseFloorMultiplier
        )
        let voicedFrames = frames.filter {
            $0.rms >= voicedRMSThreshold && $0.peak >= Self.minimumVoicedPeak
        }
        let voicedMilliseconds = voicedFrames.reduce(0.0) { total, frame in
            total + Double(frame.sampleCount) * 1_000 / Double(Self.sampleRate)
        }
        let voicedRatio = Double(voicedFrames.count) / Double(frames.count)
        let isSpeechBearing = voicedMilliseconds >= Self.minimumVoicedMilliseconds
            && voicedFrames.count >= Self.minimumVoicedFrameCount
            && voicedRatio >= Self.minimumVoicedRatio

        return Result(
            isSpeechBearing: isSpeechBearing,
            frameCount: frames.count,
            maximumRMS: rmsValues.max() ?? 0,
            estimatedNoiseFloor: noiseFloor,
            voicedMilliseconds: voicedMilliseconds,
            voicedRatio: voicedRatio
        )
    }

    private func frameMetrics(
        in samples: [Float],
        from startIndex: Int
    ) -> (rms: Float, peak: Float, sampleCount: Int) {
        let endIndex = min(startIndex + Self.samplesPerFrame, samples.count)
        var squareSum = 0.0
        var peak: Float = 0

        for index in startIndex..<endIndex {
            // Non-finite values are not meaningful normalized samples. Treating
            // them as silence keeps all reported metrics finite and repeatable.
            let sample = samples[index].isFinite ? samples[index] : 0
            squareSum += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
        }

        let sampleCount = endIndex - startIndex
        return (
            rms: Float((squareSum / Double(sampleCount)).squareRoot()),
            peak: peak,
            sampleCount: sampleCount
        )
    }

    /// The empirical 20th percentile uses the nearest-rank definition. This
    /// always selects an observed frame RMS and avoids platform rounding drift.
    private static func percentile20(_ values: [Float]) -> Float {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let rank = max(1, (sorted.count + 4) / 5)
        return sorted[rank - 1]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
