import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case storage = "Storage & Mode"
    case general = "General"
    case captureShortcuts = "Capture Shortcuts"
    case speech = "Speech"
    case ai = "Post-Processing"
    case audioPrivacy = "Audio/Privacy"
    case gmail = "Gmail"
    case mcp = "MCP"
    case knowledge = "Knowledge"
    case chat = "Ask Brain"
    case actions = "Actions"
    case macMini = "Remote Runner"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .storage: "internaldrive"
        case .general: "gearshape"
        case .captureShortcuts: "keyboard"
        case .speech: "waveform.and.mic"
        case .ai: "sparkles"
        case .audioPrivacy: "lock.shield"
        case .gmail: "envelope"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .knowledge: "books.vertical"
        case .chat: "bubble.left.and.text.bubble.right"
        case .actions: "bolt"
        case .macMini: "network"
        }
    }

    var isDeferred: Bool { self == .gmail }
}

struct SettingsView: View {
    let store: BrainStore?

    @State private var launchAtLogin: LaunchAtLoginController
    @State private var gmail: GmailConnectionController
    @State private var knowledgeStore: RemoteKnowledgeStore
    @State private var captureHotkey: CaptureHotkeyController?
    @State private var regionCapture: RegionCaptureController?
    @State private var speech: SpeechSettingsController?
    @State private var ai: AISettingsController?
    @State private var audioRetention: AudioRetentionController
    @State private var onboarding: OnboardingController
    @State private var internalSelection: SettingsSection? = .general
    private let externalSelection: Binding<SettingsSection?>?

    init(
        store: BrainStore? = nil,
        knowledgeStore: RemoteKnowledgeStore = RemoteKnowledgeStore(),
        selection: Binding<SettingsSection?>? = nil,
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        gmail: GmailConnectionController = GmailConnectionController(),
        captureHotkey: CaptureHotkeyController? = nil,
        regionCapture: RegionCaptureController? = nil,
        speech: SpeechSettingsController? = nil,
        ai: AISettingsController? = nil,
        audioRetention: AudioRetentionController = AudioRetentionController(),
        onboarding: OnboardingController = OnboardingController()
    ) {
        self.store = store
        self.externalSelection = selection
        _knowledgeStore = State(initialValue: knowledgeStore)
        _launchAtLogin = State(initialValue: launchAtLogin)
        _gmail = State(initialValue: gmail)
        _captureHotkey = State(initialValue: captureHotkey)
        _regionCapture = State(initialValue: regionCapture)
        _speech = State(initialValue: speech)
        _ai = State(initialValue: ai)
        _audioRetention = State(initialValue: audioRetention)
        _onboarding = State(initialValue: onboarding)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedSection) {
                Section("Brain") {
                    ForEach(coreSections) { section in
                        settingsRow(section)
                    }
                }
                if store?.deploymentMode == .remote {
                    Section("Remote") {
                        ForEach(remoteSections) { section in
                            settingsRow(section)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 175, ideal: 210)
        } detail: {
            switch selectedSection.wrappedValue ?? .general {
            case .storage:
                if let store {
                    DeploymentSettingsView(store: store)
                } else {
                    unavailable("Storage & Mode", "Open Settings from Brain.app to change where Brain runs.")
                }
            case .general:
                GeneralSettingsView(controller: launchAtLogin)
            case .captureShortcuts:
                if let captureHotkey {
                    CaptureShortcutSettingsView(
                        controller: captureHotkey,
                        regionCapture: regionCapture
                    )
                } else {
                    unavailable("Capture Shortcuts", "Open Settings from the Brain app dashboard to configure the shared shortcut.")
                }
            case .speech:
                if let speech {
                    SpeechSettingsView(controller: speech)
                } else {
                    unavailable("Speech", "Open Settings from the Brain app dashboard to inspect VoxType and model readiness.")
                }
            case .ai:
                if let ai {
                    AISettingsView(controller: ai)
                } else {
                    unavailable("Post-Processing", "Open Settings from the Brain app dashboard to configure a local CLI command.")
                }
            case .audioPrivacy:
                AudioPrivacySettingsView(
                    retention: audioRetention,
                    onboarding: onboarding
                )
            case .gmail:
                GmailSettingsView(controller: gmail)
            case .mcp:
                if let store {
                    MCPConnectionView(store: store)
                } else {
                    unavailable("MCP", "Open Settings from the paired Brain app to configure MCP.")
                }
            case .knowledge:
                KnowledgeView(store: knowledgeStore)
            case .chat:
                ChatView(openCitation: openCitation)
            case .actions:
                if let store {
                    ActionsView(store: store)
                } else {
                    unavailable("Actions", "Open Settings from the Brain app to run Librarian actions.")
                }
            case .macMini:
                if let store {
                    MacMiniView(store: store)
                } else {
                    unavailable("Remote Runner", "Open Settings from the paired Brain app to inspect the remote runner.")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var selectedSection: Binding<SettingsSection?> {
        externalSelection ?? $internalSelection
    }

    private var coreSections: [SettingsSection] {
        [
            .storage,
            .general,
            .captureShortcuts,
            .speech,
            .ai,
            .audioPrivacy,
            .knowledge,
            .chat,
            .actions,
        ]
    }

    private var remoteSections: [SettingsSection] {
        [.macMini, .mcp, .gmail]
    }

    private func settingsRow(_ section: SettingsSection) -> some View {
        HStack {
            Label(section.rawValue, systemImage: section.symbolName)
            Spacer()
            if section.isDeferred {
                Text("Deferred")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(section)
    }

    private func openCitation(_ url: URL) {
        selectedSection.wrappedValue = .knowledge
        Task { _ = await knowledgeStore.openNavigationURL(url) }
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "gearshape",
            description: Text(detail)
        )
    }
}

private struct DeploymentSettingsView: View {
    let store: BrainStore

    var body: some View {
        Form {
            Section("Current mode") {
                LabeledContent {
                    Label(
                        store.deploymentMode?.title ?? "Not configured",
                        systemImage: store.deploymentMode == .local ? "internaldrive" : "network"
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brain runs on")
                        Text(store.deploymentMode?.detail ?? "Choose a storage mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.deploymentMode == .local,
                   let configuration = BrainRuntime.localConfiguration() {
                    LabeledContent("Vault") {
                        Text(configuration.vaultPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Show Vault in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([configuration.vaultURL])
                    }
                } else if let instance = store.pairedInstance {
                    LabeledContent("Remote instance", value: instance.instanceID)
                    LabeledContent("Gateway", value: instance.baseURL.absoluteString)
                }
            }

            Section("Change mode") {
                Text("Switching changes where new captures, reads, and Librarian actions go. It never deletes the other vault.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Use This Mac") {
                        Task {
                            await store.configureLocal()
                        }
                    }
                    .disabled(store.deploymentMode == .local || store.isConfiguringLocal)

                    Button("Use Remote Brain") {
                        store.selectRemote()
                    }
                    .disabled(store.deploymentMode == .remote)
                }

                if store.isConfiguringLocal {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing the local vault…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = store.errorMessage {
                Section("Needs attention") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage & Mode")
    }
}

private struct GeneralSettingsView: View {
    @State var controller: LaunchAtLoginController
    private let buildInfo = BrainBuildInfo.current

    var body: some View {
        Form {
            Section("General") {
                LabeledContent {
                    Label(controller.state.title, systemImage: controller.state.symbolName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open Brain automatically")
                        Text(controller.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                HStack {
                    switch controller.state {
                    case .enabled:
                        Button("Turn Off", role: .destructive) { controller.unregister() }
                    case .notRegistered:
                        Button("Turn On") { controller.register() }
                    case .requiresApproval:
                        Button("Try Again") { controller.register() }
                    case .unavailable:
                        EmptyView()
                    }

                    Button("Open Login Items Settings") {
                        controller.openLoginItemsSettings()
                    }
                }
            }

            Section("Build") {
                if let buildInfo {
                    LabeledContent("Version", value: "\(buildInfo.version) (\(buildInfo.build))")
                    LabeledContent("Channel", value: buildInfo.channel.rawValue)
                    LabeledContent("Source SHA") {
                        Text(buildInfo.sourceSHA)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Built", value: buildInfo.buildDate)
                    Button("Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildInfo.diagnostics, forType: .string)
                    }
                    Text("These identifiers show exactly which Brain.app build is running on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Build provenance unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .task { controller.registerOnFirstLaunchIfNeeded() }
        .onAppear { controller.refresh() }
    }

}

private struct CaptureShortcutSettingsView: View {
    @State var controller: CaptureHotkeyController
    @State var regionCapture: RegionCaptureController?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Capture Shortcuts") {
                LabeledContent("Quick Capture") {
                    Text(shortcutName(controller.hotkey))
                        .font(.body.monospaced())
                }

                Text("The default is Control–Option–B. macOS dispatches only this registered shortcut; Brain reads clipboard text only after Quick Capture is visible in Link mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Use Control–Option–B") {
                        record(.controlOptionB)
                    }
                    Button("Use Command–Shift–K") {
                        record(CaptureHotkey(keyCode: 40, modifiers: [.command, .shift]))
                    }
                }

                Divider()

                LabeledContent("Region Screenshot") {
                    HStack(spacing: 7) {
                        Text("Control–Option–Z")
                            .font(.body.monospaced())
                        if let regionCapture {
                            Image(systemName: regionCapture.isRegistered
                                  ? "checkmark.circle.fill"
                                  : "exclamationmark.triangle.fill")
                                .foregroundStyle(regionCapture.isRegistered ? .green : .orange)
                                .accessibilityLabel(
                                    regionCapture.isRegistered
                                        ? "Region screenshot shortcut registered"
                                        : "Region screenshot shortcut unavailable"
                                )
                        }
                    }
                }

                Text("Press Control–Option–Z, drag over the area you want, and Brain uploads only that selected region as a screenshot capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = regionCapture?.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let message = errorMessage ?? controller.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture Shortcuts")
    }

    private func record(_ hotkey: CaptureHotkey) {
        do {
            try controller.record(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shortcutName(_ hotkey: CaptureHotkey) -> String {
        var parts: [String] = []
        if hotkey.modifiers.contains(.control) { parts.append("Control") }
        if hotkey.modifiers.contains(.option) { parts.append("Option") }
        if hotkey.modifiers.contains(.shift) { parts.append("Shift") }
        if hotkey.modifiers.contains(.command) { parts.append("Command") }
        let key = hotkey.keyCode == 11 ? "B" : hotkey.keyCode == 40 ? "K" : "Key \(hotkey.keyCode)"
        parts.append(key)
        return parts.joined(separator: "–")
    }
}

private struct AudioPrivacySettingsView: View {
    let retention: AudioRetentionController
    @State var onboarding: OnboardingController
    @State private var keepRecordings: Bool

    init(retention: AudioRetentionController, onboarding: OnboardingController) {
        self.retention = retention
        _onboarding = State(initialValue: onboarding)
        _keepRecordings = State(initialValue: retention.keepMeetingRecordings)
    }

    var body: some View {
        Form {
            Section("Audio/Privacy") {
                Toggle("Keep meeting recordings", isOn: $keepRecordings)
                    .onChange(of: keepRecordings) { _, value in
                        retention.keepMeetingRecordings = value
                    }
                Text("Off by default. Final transcript text may be delivered to your paired Brain; microphone and system audio never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                ForEach(permissionChecks) { check in
                    HStack {
                        Label(check.id.title, systemImage: check.state.symbolName)
                        Spacer()
                        Text(check.state.label).foregroundStyle(.secondary)
                        if let action = check.action {
                            Button(action.label) {
                                Task { await onboarding.perform(action) }
                            }
                        }
                    }
                }
                Button("Check Again") { Task { await onboarding.refresh() } }
                    .disabled(onboarding.isWorking)
            }
            Section("Dictation") {
                Label("VoxType owns dictation", systemImage: "waveform.and.mic")
                Text("Brain reads VoxType health and shortcut status but does not observe or post-process dictation output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio/Privacy")
        .task { await onboarding.refresh() }
    }

    private var permissionChecks: [OnboardingCheck] {
        [.microphone, .systemAudio, .accessibility].map(onboarding.check)
    }
}

private struct GmailSettingsView: View {
    @State var controller: GmailConnectionController
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section("Google Gmail — Deferred") {
                LabeledContent {
                    if controller.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(controller.state.title, systemImage: controller.state.symbolName)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Existing remote connection")
                        Text(controller.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Label(
                    "The Gmail connection and account stay on your remote Brain server. Brain.app receives only connection status.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Gmail feature expansion is deferred. These existing controls are preserved without storing mail on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                HStack {
                    switch controller.state {
                    case .checking, .authorizing:
                        EmptyView()
                    case .disconnected, .denied, .expired, .timedOut:
                        Button("Connect") { Task { await controller.connect() } }
                    case .connected, .reconnectRequired:
                        Button("Reconnect") { Task { await controller.connect() } }
                        Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    case .unavailable:
                        Button("Try Again") { Task { await controller.connect() } }
                    }

                    Button("Refresh") { Task { await controller.refresh() } }
                }
                .disabled(controller.isWorking)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Gmail — Deferred")
        .task { await controller.refresh() }
        .confirmationDialog("Disconnect Google Gmail?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await controller.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote Brain server will revoke its Gmail connection. Brain.app has no Gmail files to remove, and no email will be changed.")
        }
    }
}

struct FeaturePlaceholderView: View {
    let title: String
    let symbolName: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(detail)
        }
    }
}
