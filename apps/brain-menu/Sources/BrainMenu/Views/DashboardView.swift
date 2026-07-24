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
    case overview = "Overview"
    case capture = "Capture"
    case activity = "Activity"
    case dictation = "Dictation"
    case meetings = "Meetings"
    case settings = "Settings"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .capture: "square.and.pencil"
        case .activity: "list.bullet.rectangle"
        case .dictation: "waveform.and.mic"
        case .meetings: "person.2.wave.2"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    let store: BrainStore
    let graph: BrainAppControllerGraph?

    @State private var knowledgeStore: RemoteKnowledgeStore
    @State private var selection: DashboardSection? = .overview
    @State private var settingsSelection: SettingsSection? = .general

    init(
        store: BrainStore,
        knowledgeStore: RemoteKnowledgeStore = RemoteKnowledgeStore(),
        graph: BrainAppControllerGraph? = nil
    ) {
        self.store = store
        self.graph = graph
        _knowledgeStore = State(initialValue: knowledgeStore)
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
                    switch selection ?? .overview {
                    case .overview:
                        OverviewView(store: store)
                    case .capture:
                        if let graph {
                            CaptureView(controller: graph.capture)
                        } else {
                            FeaturePlaceholderView(
                                title: "Capture",
                                symbolName: DashboardSection.capture.symbolName,
                                detail: "Open Brain.app to capture a note, link, design, or transcript."
                            )
                        }
                    case .activity:
                        if let graph {
                            CaptureActivityView(controller: graph.capture, store: store)
                        } else {
                            FeaturePlaceholderView(
                                title: "Activity",
                                symbolName: DashboardSection.activity.symbolName,
                                detail: "Open Brain.app to inspect capture delivery activity."
                            )
                        }
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
                    case .meetings:
                        if let graph {
                            MeetingsWorkspaceView(graph: graph)
                        } else {
                            MeetingsView()
                        }
                    case .settings:
                        if let graph {
                            SettingsView(
                                store: store,
                                knowledgeStore: knowledgeStore,
                                selection: $settingsSelection,
                                launchAtLogin: graph.launchAtLogin,
                                gmail: graph.gmail,
                                captureHotkey: graph.captureHotkey,
                                regionCapture: graph.regionCapture,
                                speech: graph.speechSettings,
                                ai: graph.aiSettings,
                                audioRetention: graph.audioRetention,
                                onboarding: graph.onboarding
                            )
                        } else {
                            SettingsView(
                                store: store,
                                knowledgeStore: knowledgeStore,
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
        .onReceive(NotificationCenter.default.publisher(for: .brainOpenMacMini)) { _ in
            settingsSelection = .macMini
            selection = .settings
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

                    if graph.meeting.isCapturingAudio {
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

                if let notice = graph.meetingSavedNotice {
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
                Divider()
                MeetingsView(controller: graph.meetings) { meetingID in
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
        if graph.meeting.state == .finalizing {
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
        graph.meeting.isCapturingAudio ? "Stop Meeting" : "Start Meeting"
    }

    private var meetingTitle: String {
        graph.meeting.currentMeeting?.title ?? "No active meeting"
    }

    private var meetingDetail: String {
        switch graph.meeting.state {
        case .idle, .completed: "Start manually; Brain never starts or stops a meeting automatically."
        case .startSuggested: "Brain noticed a possible meeting. Starting still requires your action."
        case .starting: "Starting microphone and system audio capture…"
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
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
