import SwiftUI

@MainActor
struct MeetingAudioPlayerView: View {
    let controller: MeetingAudioPlaybackController

    var body: some View {
        HStack(spacing: 8) {
            Button(action: controller.toggle) {
                Image(systemName: controller.state == .playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!canControl)
            .accessibilityLabel(controller.state == .playing ? "Pause meeting recording" : "Play meeting recording")

            Text(time(controller.elapsedMilliseconds))
                .monospacedDigit()
                .accessibilityLabel("Elapsed time \(time(controller.elapsedMilliseconds))")
            Slider(value: Binding(
                get: { Double(controller.elapsedMilliseconds) },
                set: { controller.seek(to: Int64($0.rounded())) }
            ), in: 0...Double(max(1, controller.durationMilliseconds)))
            .disabled(!canControl)
            .accessibilityLabel("Meeting recording position")
            Text(time(controller.durationMilliseconds))
                .monospacedDigit()
                .accessibilityLabel("Duration \(time(controller.durationMilliseconds))")
        }
        .font(.caption)
        .controlSize(.small)
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }

    private var canControl: Bool {
        switch controller.state { case .ready, .playing, .paused, .ended: true; default: false }
    }

    private func time(_ milliseconds: Int64) -> String {
        String(format: "%d:%02d", milliseconds / 60_000, (milliseconds / 1_000) % 60)
    }
}
