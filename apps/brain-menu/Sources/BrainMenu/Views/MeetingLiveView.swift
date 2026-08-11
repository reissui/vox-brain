import Foundation
import Observation
import SwiftUI

enum MeetingLiveAction: String, CaseIterable, Equatable, Sendable {
    case pause
    case resume
    case stop
}

enum MeetingLiveTab: String, CaseIterable, Equatable, Sendable {
    case transcript = "Transcript"
    case notes = "Notes"
}

@MainActor
protocol MeetingLiveActionHandling: AnyObject {
    func pause() async
    func resume() async
    func stop() async
}

extension MeetingController: MeetingLiveActionHandling {}

struct MeetingSourceLevelModel: Equatable, Identifiable, Sendable {
    let source: MeetingAudioSource
    let level: Float

    var id: MeetingAudioSource { source }
    var title: String { source == .microphone ? "Microphone" : "System audio" }
    var accessibilityLabel: String {
        "\(title) level, \(Int((level * 100).rounded())) percent"
    }

    init(source: MeetingAudioSource, level: Float) {
        self.source = source
        self.level = min(max(level, 0), 1)
    }
}

struct MeetingLiveTranscriptRowModel: Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: String
    let speaker: String
    let text: String
    let source: MeetingAudioSource

    var accessibilityLabel: String { "\(timestamp), \(speaker): \(text)" }
}

enum MeetingLivePresentationState: Equatable, Sendable {
    case unavailable
    case active
    case finalizing
    case completed
    case failed(String)
}

struct MeetingLiveSnapshot: Equatable, Sendable {
    let meeting: MeetingRecord?
    let lifecycleState: MeetingLifecycleState
    let utterances: [MeetingUtterance]
    let previewLag: LiveTranscriptPreviewLagState
    let transcriptFailures: [LiveTranscriptFailure]
    let controllerFailure: MeetingControllerFailure?
    let levels: [MeetingAudioSource: Float]
    let signalStates: [MeetingAudioSource: MeetingAudioSignalState]
    let audioGuidance: [MeetingAudioSource: String]
    let now: Date

    init(
        meeting: MeetingRecord?,
        lifecycleState: MeetingLifecycleState,
        utterances: [MeetingUtterance],
        previewLag: LiveTranscriptPreviewLagState,
        transcriptFailures: [LiveTranscriptFailure],
        controllerFailure: MeetingControllerFailure?,
        levels: [MeetingAudioSource: Float],
        signalStates: [MeetingAudioSource: MeetingAudioSignalState] = [:],
        audioGuidance: [MeetingAudioSource: String] = [:],
        now: Date
    ) {
        self.meeting = meeting
        self.lifecycleState = lifecycleState
        self.utterances = utterances
        self.previewLag = previewLag
        self.transcriptFailures = transcriptFailures
        self.controllerFailure = controllerFailure
        self.levels = levels
        self.signalStates = signalStates
        self.audioGuidance = audioGuidance
        self.now = now
    }
}

struct MeetingLiveViewModel: Equatable, Sendable {
    let title: String
    let applicationName: String?
    let elapsedText: String
    let state: MeetingLivePresentationState
    let statusText: String
    let audioStatusText: String
    let isReceivingAudio: Bool
    let levels: [MeetingSourceLevelModel]
    let transcript: [MeetingLiveTranscriptRowModel]
    let previewMessage: String?
    let errorMessages: [String]
    let actions: [MeetingLiveAction]

    init(snapshot: MeetingLiveSnapshot) {
        title = snapshot.meeting?.title ?? "Live Meeting"
        applicationName = snapshot.meeting?.detectedApplication
        if let start = snapshot.meeting?.startedAt {
            elapsedText = MeetingsController.durationText(from: start, to: snapshot.now)
        } else {
            elapsedText = "0:00"
        }
        state = Self.presentationState(
            lifecycle: snapshot.lifecycleState,
            failure: snapshot.controllerFailure
        )
        statusText = Self.statusText(snapshot.lifecycleState)
        let audioReception = MeetingAudioReceptionState(receivedSources:
            MeetingAudioSource.allCases.filter { snapshot.signalStates[$0] == .active }
        )
        let hasConnectedAudio = snapshot.signalStates.values.contains { $0 != .waiting }
        audioStatusText = Self.audioStatusText(
            lifecycle: snapshot.lifecycleState,
            reception: audioReception,
            hasConnectedAudio: hasConnectedAudio
        )
        isReceivingAudio = Self.isReceivingAudio(
            lifecycle: snapshot.lifecycleState,
            reception: audioReception
        )
        levels = MeetingAudioSource.allCases.map {
            MeetingSourceLevelModel(source: $0, level: snapshot.levels[$0] ?? 0)
        }
        transcript = snapshot.utterances
            .filter { !$0.suppressed }
            .sorted(by: Self.transcriptOrder)
            .map {
                MeetingLiveTranscriptRowModel(
                    id: $0.id,
                    timestamp: Self.timestamp($0.startMilliseconds),
                    speaker: $0.humanName
                        ?? SpeakerEditor.defaultDisplayName(for: $0.baseSpeakerID),
                    text: $0.text,
                    source: $0.source
                )
            }
        previewMessage = Self.previewMessage(snapshot.previewLag)
        errorMessages = snapshot.transcriptFailures.map {
            "\($0.source == .microphone ? "Microphone" : "System audio") preview: \($0.message)"
        } + MeetingAudioSource.allCases.compactMap { snapshot.audioGuidance[$0] }
        actions = Self.actions(snapshot.lifecycleState)
    }

    @MainActor
    func dispatch(_ action: MeetingLiveAction, to handler: any MeetingLiveActionHandling) async {
        guard actions.contains(action) else { return }
        switch action {
        case .pause: await handler.pause()
        case .resume: await handler.resume()
        case .stop: await handler.stop()
        }
    }

    private static func presentationState(
        lifecycle: MeetingLifecycleState,
        failure: MeetingControllerFailure?
    ) -> MeetingLivePresentationState {
        if let failure { return .failed(failureMessage(failure)) }
        return switch lifecycle {
        case .starting, .recording, .paused, .stopSuggested: .active
        case .finalizing: .finalizing
        case .completed: .completed
        case .sourceSelectionRequired:
            .failed("Choose a different microphone, then start the recording again.")
        case .failed: .failed("The meeting recording failed.")
        case .idle, .startSuggested: .unavailable
        }
    }

    private static func statusText(_ state: MeetingLifecycleState) -> String {
        switch state {
        case .starting: "Starting recording"
        case .sourceSelectionRequired: "Choose microphone"
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopSuggested: "Recording — stop suggested"
        case .finalizing: "Finalizing transcript"
        case .completed: "Meeting complete"
        case .failed: "Recording failed"
        case .idle: "No active meeting"
        case .startSuggested: "Waiting to start"
        }
    }

    private static func audioStatusText(
        lifecycle: MeetingLifecycleState,
        reception: MeetingAudioReceptionState,
        hasConnectedAudio: Bool
    ) -> String {
        switch lifecycle {
        case .sourceSelectionRequired: "Choose a different microphone before trying again."
        case .paused: "Audio capture paused."
        case .finalizing: "Processing captured audio."
        case .completed: "Audio capture complete."
        case .failed: "Audio capture stopped."
        case .idle, .startSuggested, .starting, .recording, .stopSuggested:
            reception == .waiting && hasConnectedAudio
                ? "Connected — waiting for sound."
                : reception.statusText
        }
    }

    private static func isReceivingAudio(
        lifecycle: MeetingLifecycleState,
        reception: MeetingAudioReceptionState
    ) -> Bool {
        switch lifecycle {
        case .starting, .recording, .stopSuggested: reception.isReceiving
        case .idle, .startSuggested, .sourceSelectionRequired, .paused, .finalizing, .completed, .failed: false
        }
    }

    private static func actions(_ state: MeetingLifecycleState) -> [MeetingLiveAction] {
        switch state {
        case .starting: [.stop]
        case .recording, .stopSuggested: [.pause, .stop]
        case .paused: [.resume, .stop]
        default: []
        }
    }

    private static func previewMessage(_ lag: LiveTranscriptPreviewLagState) -> String? {
        guard case .lagging(let dropped) = lag else { return nil }
        let details = MeetingAudioSource.allCases.compactMap { source -> String? in
            guard let count = dropped[source], count > 0 else { return nil }
            let label = source == .microphone ? "microphone" : "system audio"
            return "\(count) \(label) chunk\(count == 1 ? "" : "s")"
        }
        return "Preview is behind; skipped " + details.joined(separator: " and ") + ". Final transcription is unaffected."
    }

    private static func transcriptOrder(
        _ lhs: MeetingUtterance,
        _ rhs: MeetingUtterance
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
    }

    private static func failureMessage(_ failure: MeetingControllerFailure) -> String {
        switch failure {
        case .startFailed(let message): "Start failed: \(message)"
        case .microphoneSelectionRequired(let message): message
        case .pauseFailed(let message): "Pause failed: \(message)"
        case .resumeFailed(let message): "Resume failed: \(message)"
        case .stopFailed(let message): "Stop failed: \(message)"
        case .eightHourSafetyLimit:
            "The eight-hour safety limit was reached. Incomplete audio was preserved for recovery."
        }
    }
}

@MainActor
@Observable
final class MeetingLiveDashboardController {
    private(set) var levels: [MeetingAudioSource: Float] = [:]
    private(set) var signalStates: [MeetingAudioSource: MeetingAudioSignalState] = [:]

    @ObservationIgnored let meetingController: MeetingController
    let notesController: MeetingNotesController
    private(set) var transcriptController: LiveTranscriptController?
    private(set) var selectedTab: MeetingLiveTab = .transcript

    init(
        meetingController: MeetingController,
        notesController: MeetingNotesController = MeetingNotesController()
    ) {
        self.meetingController = meetingController
        self.notesController = notesController
        transcriptController = nil
    }

    init(
        meetingController: MeetingController,
        transcriptController: LiveTranscriptController,
        notesController: MeetingNotesController = MeetingNotesController()
    ) {
        self.meetingController = meetingController
        self.transcriptController = transcriptController
        self.notesController = notesController
    }

    func attachTranscript(_ transcriptController: LiveTranscriptController?) {
        if transcriptController != nil { selectedTab = .transcript }
        self.transcriptController = transcriptController
    }

    func attachSession(
        transcriptController: LiveTranscriptController,
        meetingID: UUID
    ) {
        selectedTab = .transcript
        self.transcriptController = transcriptController
        notesController.attach(meetingID: meetingID)
    }

    func selectTab(_ tab: MeetingLiveTab) {
        selectedTab = tab
    }

    func receive(_ level: MeetingAudioLevel) {
        // RMS is emitted as a normalized linear value by the writer. A stale
        // source remains visible rather than flickering out between samples.
        levels[level.source] = min(max(level.rms, 0), 1)
        signalStates[level.source] = level.rms > MeetingMicrophoneReadiness.audibleRMS
            ? .active
            : .quiet
    }

    func viewModel(now: Date = Date()) -> MeetingLiveViewModel {
        let currentLevels = levels.merging(meetingController.audioLevels) { _, native in native }
        let currentSignalStates = signalStates.merging(meetingController.audioSignalStates) {
            _, native in native
        }
        return MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: meetingController.currentMeeting,
            lifecycleState: meetingController.state,
            utterances: transcriptController?.utterances ?? [],
            previewLag: transcriptController?.previewLag ?? .current,
            transcriptFailures: transcriptController?.errors ?? [],
            controllerFailure: meetingController.failure,
            levels: currentLevels,
            signalStates: currentSignalStates,
            audioGuidance: meetingController.audioGuidance,
            now: now
        ))
    }

    func perform(_ action: MeetingLiveAction) async {
        await viewModel().dispatch(action, to: meetingController)
    }
}

struct MeetingLiveView: View {
    @State private var controller: MeetingLiveDashboardController
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?
    @FocusState private var notesEditorFocused: Bool

    private enum AccessibilityTarget: Hashable {
        case heading
        case errorSummary
    }

    init(controller: MeetingLiveDashboardController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(controller.viewModel(now: context.date))
        }
        .navigationTitle("Live Meeting")
        .onAppear { accessibilityFocus = .heading }
        .onChange(of: controller.meetingController.failure != nil) { _, hasFailure in
            if hasFailure { accessibilityFocus = .errorSummary }
        }
        .onChange(of: controller.selectedTab) { _, tab in
            notesEditorFocused = tab == .notes
        }
        // Intentionally no onDisappear finalizer: closing this dashboard must
        // never stop an active recording. Only the visible Stop button does.
    }

    @ViewBuilder
    private func content(_ model: MeetingLiveViewModel) -> some View {
        switch model.state {
        case .unavailable:
            ContentUnavailableView(
                "No live meeting",
                systemImage: "waveform.slash",
                description: Text("Start recording from the meeting prompt or manual control.")
            )
        case .failed(let message):
            ContentUnavailableView(
                "Meeting recording failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .accessibilityLabel("Meeting recording failed")
            .accessibilityValue(message)
            .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
        case .active, .finalizing, .completed:
            dashboard(model)
        }
    }

    private func dashboard(_ model: MeetingLiveViewModel) -> some View {
        VStack(spacing: 0) {
            header(model)
            Divider()
            Picker("Live meeting content", selection: Binding(
                get: { controller.selectedTab },
                set: { controller.selectTab($0) }
            )) {
                Text("Transcript").tag(MeetingLiveTab.transcript)
                Text("Notes").tag(MeetingLiveTab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            switch controller.selectedTab {
            case .transcript:
                transcript(model)
            case .notes:
                notes
            }
            Divider()
            controls(model)
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: Binding(
                get: { controller.notesController.text },
                set: { controller.notesController.text = $0 }
            ))
            .font(.body)
            .focused($notesEditorFocused)
            .accessibilityLabel("Meeting notes")

            HStack {
                Spacer()
                switch controller.notesController.state {
                case .saved:
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .saving:
                    Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
        .padding()
    }

    private func header(_ model: MeetingLiveViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title).font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($accessibilityFocus, equals: .heading)
                    if let application = model.applicationName {
                        Text(application).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.elapsedText)
                    .font(.title.monospacedDigit())
                    .accessibilityLabel("Elapsed time \(model.elapsedText)")
            }

            Label(model.statusText, systemImage: "record.circle.fill")
                .foregroundStyle(model.statusText == "Paused" ? .orange : .red)
                .accessibilityLabel("Meeting status")
                .accessibilityValue(model.statusText)

            Label(
                model.audioStatusText,
                systemImage: model.isReceivingAudio ? "waveform.circle.fill" : "waveform.circle"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(model.isReceivingAudio ? .green : .secondary)
            .accessibilityLabel("Meeting audio status")
            .accessibilityValue(model.audioStatusText)

            ForEach(model.levels) { level in
                HStack {
                    Text(level.title).frame(width: 100, alignment: .leading)
                    ProgressView(value: level.level)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(level.accessibilityLabel)
            }

            if let preview = model.previewMessage {
                Label(preview, systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Transcript preview lag. \(preview)")
            }
            ForEach(model.errorMessages, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .brainAccessibleStatus(
                        error.localizedCaseInsensitiveContains("microphone")
                            ? .microphoneMissing
                            : .failed,
                        detail: error
                    )
                    .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func transcript(_ model: MeetingLiveViewModel) -> some View {
        if model.transcript.isEmpty {
            ContentUnavailableView(
                model.isReceivingAudio ? "Audio is being received" : "Waiting for audio",
                systemImage: model.isReceivingAudio ? "waveform.badge.checkmark" : "waveform",
                description: Text(
                    model.isReceivingAudio
                        ? "The transcript preview appears after enough speech has been collected."
                        : "Brain has not received microphone or system audio yet."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.transcript) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Text(row.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.speaker).font(.caption.bold())
                                Text(row.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
                .padding()
            }
        }
    }

    private func controls(_ model: MeetingLiveViewModel) -> some View {
        HStack {
            if model.actions.contains(.pause) {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await controller.perform(.pause) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Pause meeting recording")
            }
            if model.actions.contains(.resume) {
                Button("Resume", systemImage: "play.fill") {
                    Task { await controller.perform(.resume) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Resume meeting recording")
            }
            Spacer()
            if model.actions.contains(.stop) {
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    Task { await controller.perform(.stop) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Explicitly stop and finalize this meeting")
                .accessibilityLabel("Stop and finalize meeting recording")
                .accessibilityHint("Stops recording and begins final transcription")
            }
        }
        .padding()
    }
}
