import SwiftUI

enum BrainRemoteKnowledgeNavigation {
    static let notification = Notification.Name("BrainRemoteKnowledgeOpen")
    static let pathKey = "path"

    @MainActor
    static func deliver(path: String, center: NotificationCenter = .default) {
        // Changing the split-view selection only schedules KnowledgeView's
        // render. Deliver on the next main-queue turn so its observer exists.
        DispatchQueue.main.async {
            center.post(
                name: notification,
                object: nil,
                userInfo: [pathKey: path]
            )
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case dictation = "Dictation"
    case voiceNotes = "Voice Notes"
    case meetings = "Meetings"
    case aiSetup = "AI Setup"
    case settings = "Settings"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .activity: "waveform.path.ecg"
        case .dictation: "waveform.and.mic"
        case .voiceNotes: "mic.circle"
        case .meetings: "person.2.wave.2"
        case .aiSetup: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    let store: BrainStore
    let graph: BrainAppControllerGraph?

    @State private var selection: DashboardSection? = .activity
    @State private var settingsSelection: SettingsSection? = .general

    init(
        store: BrainStore,
        graph: BrainAppControllerGraph? = nil
    ) {
        self.store = store
        self.graph = graph
    }

    var body: some View {
        Group {
            if store.isReady {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        List(DashboardSection.allCases, selection: $selection) { section in
                            Label(section.rawValue, systemImage: section.symbolName)
                            .tag(section)
                        }
                        Divider()
                        if let graph,
                           let alert = graph.updates.sidebarAlert {
                            Button {
                                settingsSelection = .updates
                                selection = .settings
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(alert.title)
                                            .font(.caption.weight(.semibold))
                                        Text(alert.detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                            .accessibilityHint("Opens the Updates screen")
                        }
                        Group {
                            if let buildInfo = BrainBuildInfo.current {
                                Text(buildInfo.versionLabel)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("Brain app \(buildInfo.versionLabel)")
                            } else {
                                Text("Build unavailable")
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("Brain app build provenance unavailable")
                            }
                        }
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle("Brain")
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    switch selection ?? .activity {
                    case .activity:
                        OverviewView(store: store, graph: graph)
                    case .dictation:
                        if let graph {
                            DictationHistoryView(
                                history: graph.dictationHistory,
                                speech: graph.speechSettings,
                                onboarding: graph.onboarding
                            )
                        } else {
                            FeaturePlaceholderView(
                                title: "Dictation",
                                symbolName: DashboardSection.dictation.symbolName,
                                detail: "Use the shortcut configured in VoxType to dictate."
                            )
                        }
                    case .voiceNotes:
                        if let graph {
                            VoiceNotesWorkspaceView(graph: graph)
                        } else {
                            MeetingsView(scope: .voiceNotes)
                        }
                    case .meetings:
                        if let graph {
                            MeetingsWorkspaceView(graph: graph)
                        } else {
                            MeetingsView()
                        }
                    case .aiSetup:
                        if let graph {
                            AISetupView(
                                librarian: graph.librarianAI,
                                meetings: graph.aiSettings
                            )
                        } else {
                            FeaturePlaceholderView(
                                title: "AI Setup",
                                symbolName: DashboardSection.aiSetup.symbolName,
                                detail: "Open Brain.app to configure Librarian and meeting AI."
                            )
                        }
                    case .settings:
                        if let graph {
                            SettingsView(
                                store: store,
                                selection: $settingsSelection,
                                launchAtLogin: graph.launchAtLogin,
                                gmail: graph.gmail,
                                meetingHotkey: graph.meetingHotkey,
                                speech: graph.speechSettings,
                                updates: graph.updates,
                                audioRetention: graph.audioRetention,
                                onboarding: graph.onboarding
                            )
                        } else {
                            SettingsView(
                                store: store,
                                selection: $settingsSelection
                            )
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else if store.deploymentMode == .remote {
                PairBrainView(store: store)
            } else {
                BrainSetupView(store: store)
            }
        }
    }
}

private struct MeetingsWorkspaceView: View {
    let graph: BrainAppControllerGraph
    @State private var path: [UUID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meetingTitle).font(.headline)
                            Text(meetingDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        meetingControl
                    }

                    if graph.meeting.isCapturingAudio && !isVoiceNoteActive {
                        HStack(spacing: 18) {
                            MeetingAudioChannelWaveform(
                                source: .microphone,
                                level: graph.meeting.audioLevels[.microphone],
                                samples: graph.meeting.audioHistories[.microphone] ?? [],
                                signalState: graph.meeting.audioSignalStates[.microphone] ?? .waiting,
                                status: audioStatus(for: .microphone),
                                reduceMotion: reduceMotion
                            )
                            MeetingAudioChannelWaveform(
                                source: .system,
                                level: graph.meeting.audioLevels[.system],
                                samples: graph.meeting.audioHistories[.system] ?? [],
                                signalState: graph.meeting.audioSignalStates[.system] ?? .waiting,
                                status: audioStatus(for: .system),
                                reduceMotion: reduceMotion
                            )
                        }
                    }
                }
                .padding()

                if let notice = graph.meetingSavedNotice, !notice.isVoiceNote {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Meeting added: \(notice.title)")
                                .font(.callout.weight(.semibold))
                            Text(notice.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") {
                            graph.dismissMeetingSavedNotice()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss meeting-added notification")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.08))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }

                if graph.meeting.state == .finalizing,
                   graph.meeting.currentMeeting?.isVoiceNote != true {
                    MeetingProcessingPlaceholder(
                        title: "Preparing your meeting",
                        detail: "Brain is saving the recording and completing the local transcript. The meeting will appear below when it is ready."
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                Divider()
                MeetingsView(controller: graph.meetings, scope: .meetings) { meetingID in
                    graph.meetings.markOpened(meetingID)
                    path.append(meetingID)
                }
            }
            .navigationDestination(for: UUID.self) { meetingID in
                MeetingDetailView(controller: MeetingDetailController(
                    meetingID: meetingID,
                    analysisController: SavedMeetingAnalysisControllerFactory().make()
                ))
            }
            .navigationTitle("Meetings")
        }
    }

    @ViewBuilder
    private var meetingControl: some View {
        if isVoiceNoteActive {
            Label("Voice Note in progress", systemImage: "mic.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if graph.meeting.state == .finalizing {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Saving Meeting…")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving meeting and finalizing transcript")
        } else {
            Button(meetingButtonTitle) {
                Task { await graph.toggleMeeting() }
            }
            .buttonStyle(.borderedProminent)
            .tint(graph.meeting.isCapturingAudio ? .red : nil)
            .accessibilityHint(
                graph.meeting.isCapturingAudio
                    ? "Stops recording immediately, then saves the final transcript"
                    : "Starts microphone and computer audio recording"
            )
        }
    }

    private var meetingButtonTitle: String {
        guard graph.meeting.isCapturingAudio else { return "Start Meeting" }
        return "Stop Meeting"
    }

    private var isVoiceNoteActive: Bool {
        graph.meeting.isCapturingAudio && graph.meeting.currentMeeting?.isVoiceNote == true
    }

    private var meetingTitle: String {
        guard graph.meeting.currentMeeting?.isVoiceNote != true else {
            return "No active meeting"
        }
        return graph.meeting.currentMeeting?.title ?? "No active meeting"
    }

    private var meetingDetail: String {
        if isVoiceNoteActive {
            return "A voice note is active. Manage it from Voice Notes."
        }
        return switch graph.meeting.state {
        case .idle, .completed: "Start manually; Brain never starts or stops a meeting automatically."
        case .startSuggested: "Brain noticed a possible meeting. Starting still requires your action."
        case .starting: "Starting microphone and system audio capture…"
        case .sourceSelectionRequired: "Choose another microphone before starting again."
        case .recording: "Recording microphone and system audio locally."
        case .paused: "Meeting is paused."
        case .stopSuggested: "Brain thinks the meeting may have ended; choose Stop or keep recording."
        case .finalizing: "Recording stopped. Saving the transcript and adding the meeting…"
        case .failed: "Meeting capture needs attention."
        }
    }

    private func audioStatus(for source: MeetingAudioSource) -> String {
        if graph.meeting.audioGuidance[source] != nil { return "Needs attention" }
        switch graph.meeting.state {
        case .starting:
            return signalStatus(for: source, waiting: "Connecting…")
        case .sourceSelectionRequired:
            return source == .microphone ? "Choose input" : "Off"
        case .recording, .stopSuggested:
            return signalStatus(for: source, waiting: "Waiting…")
        case .paused: return "Paused"
        case .finalizing: return "Saving…"
        case .idle, .startSuggested, .completed, .failed: return "Off"
        }
    }

    private func signalStatus(for source: MeetingAudioSource, waiting: String) -> String {
        switch graph.meeting.audioSignalStates[source] ?? .waiting {
        case .waiting: waiting
        case .quiet: "Connected — waiting for sound…"
        case .active: "Live"
        }
    }
}

private struct VoiceNotesWorkspaceView: View {
    let graph: BrainAppControllerGraph
    @State private var path: [UUID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(voiceNoteTitle).font(.headline)
                            Text(voiceNoteDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        voiceNoteControl
                    }

                    if isVoiceNoteActive {
                        MeetingAudioChannelWaveform(
                            source: .microphone,
                            level: graph.meeting.audioLevels[.microphone],
                            samples: graph.meeting.audioHistories[.microphone] ?? [],
                            signalState: graph.meeting.audioSignalStates[.microphone] ?? .waiting,
                            status: microphoneStatus,
                            reduceMotion: reduceMotion
                        )
                    }
                }
                .padding()

                if let notice = graph.meetingSavedNotice, notice.isVoiceNote {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice note added")
                                .font(.callout.weight(.semibold))
                            Text(notice.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") {
                            graph.dismissMeetingSavedNotice()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss voice-note-added notification")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.08))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }

                if graph.meeting.state == .finalizing,
                   graph.meeting.currentMeeting?.isVoiceNote == true {
                    MeetingProcessingPlaceholder(
                        title: "Preparing your voice note",
                        detail: "Brain is saving the recording and completing the local transcript. The voice note will appear below when it is ready."
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                Divider()
                MeetingsView(controller: graph.meetings, scope: .voiceNotes) { meetingID in
                    graph.meetings.markOpened(meetingID)
                    path.append(meetingID)
                }
            }
            .navigationDestination(for: UUID.self) { meetingID in
                MeetingDetailView(controller: MeetingDetailController(
                    meetingID: meetingID,
                    analysisController: SavedMeetingAnalysisControllerFactory().make()
                ))
            }
            .navigationTitle("Voice Notes")
        }
    }

    @ViewBuilder
    private var voiceNoteControl: some View {
        if isMeetingActive {
            Label("Meeting in progress", systemImage: "person.2.wave.2.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else if graph.meeting.state == .finalizing {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Saving Voice Note…")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving voice note and finalizing transcript")
        } else if isVoiceNoteActive {
            Button("Stop Voice Note") {
                Task { await graph.toggleMeeting() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityHint("Stops recording immediately, then saves the voice note")
        } else {
            Button("Record Voice Note", systemImage: "mic.circle") {
                Task { await graph.startVoiceNote() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Starts a long-form voice note")
        }
    }

    private var isVoiceNoteActive: Bool {
        graph.meeting.isCapturingAudio && graph.meeting.currentMeeting?.isVoiceNote == true
    }

    private var isMeetingActive: Bool {
        graph.meeting.isCapturingAudio && graph.meeting.currentMeeting?.isVoiceNote != true
    }

    private var voiceNoteTitle: String {
        isVoiceNoteActive ? "Recording voice note" : "Voice Notes"
    }

    private var voiceNoteDetail: String {
        if isMeetingActive {
            return "Finish the active meeting before recording a voice note."
        }
        return switch graph.meeting.state {
        case .starting: "Starting audio capture…"
        case .sourceSelectionRequired: "Choose another microphone before starting again."
        case .recording: "Recording locally on this Mac."
        case .paused: "Voice note is paused."
        case .stopSuggested: "Voice note is still recording."
        case .finalizing: "Recording stopped. Saving the transcript and voice note…"
        case .idle, .startSuggested, .completed, .failed:
            "Record a long-form thought and keep its transcript in Brain."
        }
    }

    private var microphoneStatus: String {
        if graph.meeting.audioGuidance[.microphone] != nil { return "Needs attention" }
        switch graph.meeting.state {
        case .starting:
            return signalStatus(waiting: "Connecting…")
        case .sourceSelectionRequired: return "Choose input"
        case .recording, .stopSuggested:
            return signalStatus(waiting: "Waiting…")
        case .paused: return "Paused"
        case .finalizing: return "Saving…"
        case .idle, .startSuggested, .completed, .failed: return "Off"
        }
    }

    private func signalStatus(waiting: String) -> String {
        switch graph.meeting.audioSignalStates[.microphone] ?? .waiting {
        case .waiting: waiting
        case .quiet: "Connected — waiting for sound…"
        case .active: "Live"
        }
    }
}

private struct MeetingProcessingPlaceholder: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct PairBrainView: View {
    let store: BrainStore

    @State private var address = ""
    @State private var code = ""

    private var canPair: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isPairing
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                store.returnToSetup()
            } label: {
                Label("Back to setup choices", systemImage: "chevron.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Returns to the This Mac or Remote Brain choice")

            VStack(spacing: 22) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text("Pair Brain")
                        .font(.largeTitle.bold())
                    Text("Connect this app to the gateway for your remote Brain runner.")
                        .foregroundStyle(.secondary)
                }

                Form {
                    TextField("Instance address", text: $address, prompt: Text("https://brain.example.com"))
                        .textContentType(.URL)
                        .accessibilityLabel("Remote Brain instance address")
                    SecureField("One-time pairing code", text: $code)
                        .accessibilityLabel("One-time Brain pairing code")
                }
                .formStyle(.grouped)
                .frame(width: 460)

                if let errorMessage = store.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await store.pair(address: address, code: code) }
                } label: {
                    if store.isPairing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Pairing Brain")
                    } else {
                        Text("Pair Brain")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canPair)

                Text("Status and health are requested only from the paired HTTPS instance.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
