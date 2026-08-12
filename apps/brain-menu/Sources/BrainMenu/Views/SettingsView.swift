import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case storage = "Vault"
    case general = "General"
    case shortcuts = "Shortcuts"
    case speech = "Speech"
    case audioPrivacy = "Privacy"
    case updates = "Updates"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .storage: "internaldrive"
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .speech: "waveform.and.mic"
        case .audioPrivacy: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

}

struct SettingsView: View {
    let store: BrainStore?

    @State private var launchAtLogin: LaunchAtLoginController
    @State private var meetingHotkey: MeetingHotkeyController?
    @State private var continuousDictation: ContinuousDictationController?
    @State private var speech: SpeechSettingsController?
    @State private var updates: UpdateController?
    @State private var onboarding: OnboardingController
    @State private var internalSelection: SettingsSection? = .general
    private let externalSelection: Binding<SettingsSection?>?

    init(
        store: BrainStore? = nil,
        selection: Binding<SettingsSection?>? = nil,
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        meetingHotkey: MeetingHotkeyController? = nil,
        continuousDictation: ContinuousDictationController? = nil,
        speech: SpeechSettingsController? = nil,
        updates: UpdateController? = nil,
        onboarding: OnboardingController = OnboardingController()
    ) {
        self.store = store
        self.externalSelection = selection
        _launchAtLogin = State(initialValue: launchAtLogin)
        _meetingHotkey = State(initialValue: meetingHotkey)
        _continuousDictation = State(initialValue: continuousDictation)
        _speech = State(initialValue: speech)
        _updates = State(initialValue: updates)
        _onboarding = State(initialValue: onboarding)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            HStack(spacing: 0) {
                List(visibleSections, selection: selectedSection) { section in
                    Label(section.rawValue, systemImage: section.symbolName)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 210)
                .accessibilityLabel("Settings areas")

                Divider()

                settingsContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: visibleSections) { _, sections in
            if let selected = selectedSection.wrappedValue,
               !sections.contains(selected) {
                selectedSection.wrappedValue = .general
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection.wrappedValue ?? .general {
        case .storage:
            if let store {
                DeploymentSettingsView(store: store)
            } else {
                unavailable("Vault", "Open Settings from Brain.app to inspect the local vault.")
            }
        case .general:
            GeneralSettingsView(controller: launchAtLogin)
        case .shortcuts:
            if let meetingHotkey, let continuousDictation {
                ShortcutSettingsView(
                    meeting: meetingHotkey,
                    liveDictation: continuousDictation
                )
            } else {
                unavailable("Shortcuts", "Open Settings from Brain.app to configure shortcuts.")
            }
        case .speech:
            if let speech {
                SpeechSettingsView(controller: speech)
            } else {
                unavailable("Speech", "Open Settings from the Brain app dashboard to inspect VoxType and model readiness.")
            }
        case .audioPrivacy:
            AudioPrivacySettingsView(onboarding: onboarding)
        case .updates:
            if let updates {
                UpdateSettingsView(controller: updates)
            } else {
                unavailable("Updates", "Update checks are available in the installed Brain app.")
            }
        }
    }

    private var selectedSection: Binding<SettingsSection?> {
        externalSelection ?? $internalSelection
    }

    private var visibleSections: [SettingsSection] {
        [
            .storage,
            .general,
            .shortcuts,
            .speech,
            .audioPrivacy,
            .updates,
        ]
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
            Section("Vault") {
                LabeledContent {
                    Label("On this Mac", systemImage: "internaldrive")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage")
                        Text("Your Markdown vault stays on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let configuration = BrainRuntime.localConfiguration() {
                    LabeledContent("Vault") {
                        Text(configuration.vaultPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Show Vault in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([configuration.vaultURL])
                    }
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
        .navigationTitle("Vault")
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

private struct ShortcutSettingsView: View {
    @State var meeting: MeetingHotkeyController
    @State var liveDictation: ContinuousDictationController
    @State private var meetingErrorMessage: String?
    @State private var dictationErrorMessage: String?

    var body: some View {
        Form {
            Section("Live Dictation shortcut") {
                LabeledContent("Current shortcut") {
                    Text(liveDictation.hotkey.displayName)
                        .font(.body.monospaced())
                }

                Picker("Shortcut", selection: dictationShortcutBinding) {
                    Text(CaptureHotkey.controlOptionD.displayName)
                        .tag(CaptureHotkey.controlOptionD)
                    Text(CaptureHotkey.commandShiftD.displayName)
                        .tag(CaptureHotkey.commandShiftD)
                    Text(CaptureHotkey.controlOptionL.displayName)
                        .tag(CaptureHotkey.controlOptionL)
                }

                Text("The shortcut starts or stops Live Dictation from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = dictationErrorMessage ?? liveDictation.shortcutErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if liveDictation.isShortcutRegistered {
                    Label("Shortcut is active.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Meeting shortcut") {
                Toggle("Use a global shortcut to start or stop a meeting", isOn: Binding(
                    get: { meeting.isEnabled },
                    set: { meeting.setEnabled($0) }
                ))

                LabeledContent("Current shortcut") {
                    Text(meeting.hotkey.displayName)
                        .font(.body.monospaced())
                }

                Picker("Shortcut", selection: meetingShortcutBinding) {
                    Text("Control–Option–M").tag(CaptureHotkey.controlOptionM)
                    Text("Command–Shift–M").tag(CaptureHotkey(
                        keyCode: 46,
                        modifiers: [.command, .shift]
                    ))
                    Text("Control–Option–R").tag(CaptureHotkey(
                        keyCode: 15,
                        modifiers: [.control, .option]
                    ))
                }
                .disabled(!meeting.isEnabled)

                Text("The shortcut toggles the meeting recorder from any app. Brain never starts a meeting automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = meetingErrorMessage ?? meeting.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if meeting.isEnabled && meeting.isRegistered {
                    Label("Shortcut is active.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    private var dictationShortcutBinding: Binding<CaptureHotkey> {
        Binding(
            get: { liveDictation.hotkey },
            set: { hotkey in
                do {
                    try liveDictation.record(
                        keyCode: hotkey.keyCode,
                        modifiers: hotkey.modifiers
                    )
                    dictationErrorMessage = nil
                } catch {
                    dictationErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private var meetingShortcutBinding: Binding<CaptureHotkey> {
        Binding(
            get: { meeting.hotkey },
            set: { hotkey in
                do {
                    try meeting.record(
                        keyCode: hotkey.keyCode,
                        modifiers: hotkey.modifiers
                    )
                    meetingErrorMessage = nil
                } catch {
                    meetingErrorMessage = error.localizedDescription
                }
            }
        )
    }
}

private struct AudioPrivacySettingsView: View {
    @State var onboarding: OnboardingController

    init(onboarding: OnboardingController) {
        _onboarding = State(initialValue: onboarding)
    }

    var body: some View {
        Form {
            Section("Audio/Privacy") {
                Label("Recordings stay on this Mac", systemImage: "internaldrive.fill")
                Text("After successful transcription, Brain saves compact AAC audio. Failed or interrupted attempts keep larger raw recovery audio until you retry or explicitly delete the recording or its item. Audio never leaves this Mac; only the final transcript is saved to your vault.")
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
                Text("Brain can start Live Dictation and show recording status. VoxType still owns audio, transcription, paste, and final output.")
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

private struct UpdateSettingsView: View {
    @State var controller: UpdateController

    var body: some View {
        Form {
            Section("Automatic updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $controller.automaticChecksEnabled
                )
                Text("Brain checks GitHub releases once a day. Updates are downloaded only when you choose Install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Brain version") {
                LabeledContent("Installed", value: controller.currentVersion)

                switch controller.state {
                case .idle:
                    Text("Check GitHub for the latest signed Brain release.")
                        .foregroundStyle(.secondary)
                case .checking:
                    statusRow("Checking GitHub…")
                case .upToDate(let date):
                    Label("Brain is up to date.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    LabeledContent("Checked") {
                        Text(date, style: .relative)
                    }
                case .available(let release):
                    Label(
                        "Brain \(release.version) is available.",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .font(.body.weight(.medium))
                    Button("Install Brain \(release.version)") {
                        Task { await controller.installAvailableUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                case .downloading(let release):
                    statusRow("Downloading and verifying Brain \(release.version)…")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .unavailable(let message):
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Check for Updates") {
                        Task { await controller.checkNow() }
                    }
                    .disabled(controller.isWorking)

                    if controller.availableRelease != nil {
                        Button("View Release Notes") {
                            controller.openReleasePage()
                        }
                    }
                }
            }

            Section("Update security") {
                Text("Before installing, Brain verifies the downloaded app's bundle identifier, version, macOS code signature, and Developer ID team. It then relaunches from the same Applications folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Updates")
        .task { controller.start() }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
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
