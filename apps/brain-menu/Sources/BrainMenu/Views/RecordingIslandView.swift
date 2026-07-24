import SwiftUI

@MainActor
struct RecordingIslandView: View {
    @Bindable var controller: RecordingIslandController
    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

    private var reduceMotion: Bool {
        controller.reduceMotionEnabled || environmentReduceMotion
    }

    var body: some View {
        Group {
            switch controller.presentation {
            case .hidden:
                Color.clear
            case .dictation(let presentation):
                dictation(presentation)
            case .meeting(let presentation):
                meeting(presentation)
            }
        }
        .padding(14)
        .frame(
            width: controller.presentationSize.width,
            height: controller.presentationSize.height
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func dictation(_ value: RecordingIslandDictationPresentation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 13) {
                HStack(spacing: 12) {
                    statusSymbol(for: value.phase)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(color(for: value.phase))
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(value.phase.title)
                            .font(.headline)
                            .brainAccessibleStatus(value.phase.accessibilityState)
                        if value.phase == .error, let message = value.errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .brainAccessibleStatus(.failed, detail: message)
                        } else {
                            HStack(spacing: 5) {
                                Text(elapsed(from: value.startedAt, to: context.date))
                                    .monospacedDigit()
                                if let shortcut = value.shortcutDescription {
                                    Text("·")
                                    Text(shortcut)
                                        .accessibilityLabel("VoxType shortcut \(shortcut)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if let level = value.level,
                       value.phase == .listening || value.phase == .locked {
                        RecordingWaveform(level: level, reduceMotion: reduceMotion)
                            .frame(width: 88, height: 30)
                            .accessibilityLabel("Microphone level")
                            .accessibilityValue("\(Int(level * 100)) percent")
                    }
                }

                controlRow
            }
        }
    }

    private func meeting(_ value: RecordingIslandMeetingPresentation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(meetingPhaseColor(value.phase))
                        .frame(width: 10, height: 10)
                        .opacity(value.phase == .finalizing ? 0.45 : 1)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(value.title)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let application = value.applicationName {
                                Text(application)
                                Text("·")
                            }
                            Text(value.phase.title)
                            Text("·")
                            Text(elapsed(from: value.startedAt, to: context.date))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if value.phase == .saved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Meeting saved")
                    } else {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let microphone = value.microphone {
                                microphonePicker(microphone, phase: value.phase)
                            }
                            RecordingLevelRow(
                                label: "Mic",
                                level: value.microphoneLevel,
                                samples: value.microphoneHistory,
                                signalState: value.microphoneSignalState,
                                color: .green,
                                reduceMotion: reduceMotion
                            )
                            RecordingLevelRow(
                                label: "Computer",
                                level: value.systemLevel,
                                samples: value.systemHistory,
                                signalState: value.systemSignalState,
                                color: .cyan,
                                reduceMotion: reduceMotion
                            )
                        }
                    }
                }

                Text(value.latestTranscriptLine?.nilIfBlank ?? value.audioStatusText)
                    .font(.callout)
                    .foregroundStyle(
                        value.latestTranscriptLine?.nilIfBlank == nil && value.isReceivingAudio
                            ? Color.green
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        value.latestTranscriptLine?.nilIfBlank == nil
                            ? "Meeting audio status"
                            : "Latest transcript"
                    )
                    .accessibilityValue(value.latestTranscriptLine?.nilIfBlank ?? value.audioStatusText)

                if let guidance = value.guidance {
                    Label(guidance, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Meeting audio warning. \(guidance)")
                }

                if let message = value.microphone?.switchErrorMessage {
                    Label(message, systemImage: "mic.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Microphone change failed. \(message)")
                }

                controlRow
            }
        }
    }

    private func microphonePicker(
        _ microphone: RecordingIslandMicrophonePresentation,
        phase: RecordingIslandMeetingPhase
    ) -> some View {
        let canChange = [.recording, .paused, .stopSuggested].contains(phase)
            && !microphone.switchState.isSwitching
            && !microphone.availableDevices.isEmpty
        return Menu {
            Button {
                controller.selectMicrophone(.systemDefault)
            } label: {
                Label(
                    systemDefaultTitle(microphone),
                    systemImage: microphone.selectedPreference == .systemDefault
                        ? "checkmark"
                        : "gearshape"
                )
            }
            .disabled(microphone.defaultDevice == nil)

            Divider()

            ForEach(microphone.availableDevices) { device in
                let selection = MeetingMicrophoneSelection.device(uid: device.id)
                Button {
                    controller.selectMicrophone(selection)
                } label: {
                    Label(
                        deviceTitle(device, microphone: microphone),
                        systemImage: microphone.selectedPreference == selection
                            ? "checkmark"
                            : device.id == microphone.activeDevice?.id
                                ? "mic.fill"
                                : "mic"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                if microphone.switchState.isSwitching {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(
                        systemName: microphone.switchErrorMessage == nil
                            ? "mic.fill"
                            : "mic.slash.fill"
                    )
                }
                Text(microphone.activeDeviceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(
                microphone.switchErrorMessage == nil ? Color.secondary : Color.red
            )
            .frame(width: 150, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .disabled(!canChange)
        .help("Active microphone: \(microphone.activeDeviceName)")
        .accessibilityLabel("Active microphone")
        .accessibilityValue(microphone.accessibilityValue)
        .accessibilityHint(
            canChange
                ? "Opens the available microphone choices."
                : "Microphone changes are not currently available."
        )
    }

    private func systemDefaultTitle(
        _ microphone: RecordingIslandMicrophonePresentation
    ) -> String {
        guard let name = microphone.defaultDevice?.name else {
            return "System Default — Unavailable"
        }
        return "System Default — \(name)"
    }

    private func deviceTitle(
        _ device: MeetingMicrophoneDevice,
        microphone: RecordingIslandMicrophonePresentation
    ) -> String {
        device.id == microphone.activeDevice?.id
            ? "\(device.name) — Active"
            : device.name
    }

    @ViewBuilder
    private var controlRow: some View {
        if !controller.controls.isEmpty {
            HStack(spacing: 8) {
                Spacer()
                ForEach(controller.controls, id: \.self) { action in
                    actionButton(action)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: RecordingIslandAction) -> some View {
        if action == .stop {
            Button(buttonTitle(for: action)) { controller.perform(action) }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("Stop active recording")
                .accessibilityHint("Stops and finalizes the active recording")
        } else if action == .cancel {
            Button(buttonTitle(for: action)) { controller.perform(action) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel active dictation")
                .accessibilityHint("Discards the active dictation")
        } else {
            Button(buttonTitle(for: action)) { controller.perform(action) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("\(buttonTitle(for: action)) active recording")
        }
    }

    @ViewBuilder
    private func statusSymbol(for phase: RecordingIslandDictationPhase) -> some View {
        switch phase {
        case .listening: Image(systemName: "waveform")
        case .locked: Image(systemName: "lock.fill")
        case .transcribing: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill")
        case .error: Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private func color(for phase: RecordingIslandDictationPhase) -> Color {
        switch phase {
        case .listening, .locked: .accentColor
        case .transcribing: .secondary
        case .succeeded: .green
        case .error: .red
        }
    }

    private func meetingPhaseColor(_ phase: RecordingIslandMeetingPhase) -> Color {
        switch phase {
        case .paused: .orange
        case .saved: .green
        case .starting, .recording, .stopSuggested, .finalizing: .red
        }
    }

    private func buttonTitle(for action: RecordingIslandAction) -> String {
        switch action {
        case .cancel: "Cancel"
        case .pause: "Pause"
        case .resume: "Resume"
        case .stop: "Stop"
        case .keepRecording: "Keep Recording"
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private extension RecordingIslandDictationPhase {
    var accessibilityState: BrainWorkflowAccessibilityState {
        switch self {
        case .listening: .listening
        case .locked: .locked
        case .transcribing: .transcribing
        case .succeeded: .delivered
        case .error: .failed
        }
    }
}

private struct RecordingLevelRow: View {
    let label: String
    let level: Float?
    let samples: [Float]
    let signalState: MeetingAudioSignalState
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(signalState == .active ? color : .secondary)
                .frame(width: 52, alignment: .trailing)
            MeetingLevelWaveform(
                samples: samples,
                currentLevel: level,
                color: color,
                reduceMotion: reduceMotion
            )
            .frame(width: 92, height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let status = switch signalState {
        case .waiting: "Waiting"
        case .quiet: "Quiet"
        case .active: "Active"
        }
        return level.map { "\(status), \(Int(($0 * 100).rounded())) percent" }
            ?? status
    }
}

private struct RecordingWaveform: View {
    let level: Float
    let reduceMotion: Bool

    private let weights: [CGFloat] = [0.35, 0.6, 0.82, 1, 0.72, 0.5, 0.9, 0.42]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.45 + Double(level) * 0.45))
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 2,
                            maxHeight: max(2, geometry.size.height * max(0.12, CGFloat(level) * weight))
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: level)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
