import SwiftUI

struct MeetingLevelWaveformModel: Equatable, Sendable {
    static let defaultBarCount = 24

    let displaySamples: [Float]

    init(
        samples: [Float],
        currentLevel: Float?,
        barCount: Int = defaultBarCount
    ) {
        let count = max(1, barCount)
        var values = Array(samples.suffix(count))
        if values.isEmpty, let currentLevel {
            values = [currentLevel]
        }
        if values.count < count {
            values.insert(contentsOf: repeatElement(0, count: count - values.count), at: 0)
        }
        displaySamples = values.map { min(max($0, 0), 1) }
    }
}

struct MeetingLevelWaveform: View {
    let samples: [Float]
    let currentLevel: Float?
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        let model = MeetingLevelWaveformModel(samples: samples, currentLevel: currentLevel)
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(model.displaySamples.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(color.opacity(sample > 0 ? 0.9 : 0.2))
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 2,
                            maxHeight: max(2, geometry.size.height * max(0.08, CGFloat(sample)))
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: model.displaySamples
            )
        }
        .accessibilityHidden(true)
    }
}

/// Reusable labelled channel treatment for the dashboard's larger live-audio view.
struct MeetingAudioChannelWaveform: View {
    let source: MeetingAudioSource
    let level: Float?
    let samples: [Float]
    let signalState: MeetingAudioSignalState
    let status: String
    let reduceMotion: Bool

    private var title: String {
        source == .microphone ? "Your microphone" : "Computer audio"
    }

    private var color: Color {
        source == .microphone ? .green : .cyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(signalState == .active ? color : .secondary)
            }
            MeetingLevelWaveform(
                samples: samples,
                currentLevel: level,
                color: color,
                reduceMotion: reduceMotion
            )
            .frame(height: 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            "\(status), level \(level.map { String(Int(($0 * 100).rounded())) } ?? "unavailable") percent"
        )
    }
}
