import Foundation
import Observation
import SwiftUI

protocol AISettingsPersisting: Sendable {
    func load() -> AIProviderConfiguration
    func loadValidatedConfiguration() -> AIProviderConfiguration?
    func save(_ configuration: AIProviderConfiguration) throws
    func saveValidated(_ configuration: AIProviderConfiguration) throws
    func clear()
}

extension AISettingsPersisting {
    func loadValidatedConfiguration() -> AIProviderConfiguration? { nil }
    func saveValidated(_ configuration: AIProviderConfiguration) throws {
        try save(configuration)
    }
}

extension AISettingsStore: AISettingsPersisting {}

protocol AIProviderMaking: Sendable {
    func makeProvider(configuration: AIProviderConfiguration) -> any AIProviding
}

struct LocalAIProviderFactory: AIProviderMaking {
    func makeProvider(configuration: AIProviderConfiguration) -> any AIProviding {
        CLIProvider(configuration: configuration)
    }
}

enum AISettingsTestState: Equatable, Sendable {
    case untested
    case testing
    case result(AIConnectionState)

    var title: String {
        switch self {
        case .untested: "Not tested"
        case .testing: "Testing"
        case .result(.disabled): "Disabled"
        case .result(.missingExecutable): "Executable missing"
        case .result(.unauthenticated): "Sign-in required"
        case .result(.invalidModel): "Invalid model"
        case .result(.timeout): "Timed out"
        case .result(.schemaFailure): "Invalid response"
        case .result(.ready): "Ready"
        }
    }

    var detail: String {
        switch self {
        case .untested:
            "Test this exact configuration before saving it."
        case .testing:
            "Brain is sending a fixed, non-private connection test."
        case .result(.disabled):
            "AI analysis is off."
        case .result(.missingExecutable):
            "Choose an executable or install the selected provider CLI."
        case .result(.unauthenticated):
            "Sign in with the provider CLI, then test again."
        case .result(.invalidModel):
            "Choose a model available to this CLI account, or leave the model blank."
        case .result(.timeout):
            "The provider did not complete the bounded connection test in time."
        case .result(.schemaFailure):
            "The provider returned a response that did not match Brain's required structure."
        case .result(.ready):
            "This exact provider configuration passed the connection test and can be saved."
        }
    }

    var symbolName: String {
        switch self {
        case .untested: "questionmark.circle"
        case .testing: "hourglass"
        case .result(.disabled): "minus.circle"
        case .result(.ready): "checkmark.circle.fill"
        case .result:
            "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        "AI provider test state: \(title). \(detail)"
    }
}

@MainActor
@Observable
final class AISettingsController {
    var configuration: AIProviderConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            testState = configuration.provider == .disabled
                ? .result(.disabled)
                : .untested
            savedMessage = nil
            errorMessage = nil
        }
    }

    var customCommand: String = "" {
        didSet {
            guard customCommand != oldValue else { return }
            applyCustomCommand()
        }
    }

    private(set) var testState: AISettingsTestState
    private(set) var savedMessage: String?
    private(set) var errorMessage: String?
    private(set) var commandErrorMessage: String?

    @ObservationIgnored private let settings: any AISettingsPersisting
    @ObservationIgnored private let providerFactory: any AIProviderMaking
    @ObservationIgnored private var lastTestedConfiguration: AIProviderConfiguration?
    @ObservationIgnored private var suppressCommandApplication = true

    init(
        settings: any AISettingsPersisting,
        providerFactory: any AIProviderMaking = LocalAIProviderFactory(),
        executableResolver: any AIExecutableResolving = AIExecutableResolver()
    ) {
        self.settings = settings
        self.providerFactory = providerFactory
        _ = executableResolver
        let loaded = settings.load().canonicalized()
        configuration = loaded
        let validated = settings.loadValidatedConfiguration()?.canonicalized()
        if loaded.provider == .disabled {
            testState = .result(.disabled)
        } else if validated == loaded {
            testState = .result(.ready)
            lastTestedConfiguration = loaded
        } else {
            testState = .untested
        }
        customCommand = AILocalCLICommandTemplate.render(configuration: loaded)
        suppressCommandApplication = false
    }

    var canTestConnection: Bool {
        configuration.provider != .disabled
            && testState != .testing
            && commandErrorMessage == nil
            && !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        testState == .result(.ready)
            && lastTestedConfiguration == configuration
            && commandErrorMessage == nil
    }

    var testDetail: String {
        if testState == .result(.unauthenticated), configuration.provider == .codex {
            return "codex login --device-auth"
        }
        if testState == .result(.missingExecutable), configuration.provider == .codex {
            return "Codex CLI was not found. Install Codex or ChatGPT, then test again."
        }
        return testState.detail
    }

    var testAccessibilityLabel: String {
        "AI provider test state: \(testState.title). \(testDetail)"
    }

    var selectedModelName: String? {
        guard configuration.provider != .disabled,
              commandErrorMessage == nil else {
            return nil
        }
        return configuration.model ?? "CLI default"
    }

    var confirmedModelName: String? {
        guard testState == .result(.ready),
              lastTestedConfiguration == configuration else {
            return nil
        }
        return selectedModelName
    }

    func selectProvider(_ provider: AIProvider) {
        let previous = configuration
        switch provider {
        case .disabled:
            configuration = AIProviderConfiguration()
            customCommand = ""
        case .codex, .claude:
            configuration = AIProviderConfiguration(
                provider: provider,
                timeout: previous.timeout,
                contextChoice: previous.contextChoice
            )
            customCommand = AILocalCLICommandTemplate.render(
                provider: provider,
                model: nil
            )
        case .advanced:
            configuration = AIProviderConfiguration(
                provider: .advanced,
                timeout: previous.timeout,
                contextChoice: previous.contextChoice
            )
            customCommand = ""
        }
        commandErrorMessage = nil
    }

    func testConnection() async {
        guard canTestConnection else { return }
        let candidate = configuration.canonicalized()
        if candidate != configuration {
            configuration = candidate
        }
        testState = .testing
        savedMessage = nil
        errorMessage = nil

        let result = await providerFactory
            .makeProvider(configuration: candidate)
            .testConnection()
        guard configuration == candidate else { return }
        testState = .result(result)
        lastTestedConfiguration = result == .ready ? candidate : nil
    }

    func save() {
        guard canSave else { return }
        do {
            try settings.saveValidated(configuration)
            lastTestedConfiguration = configuration
            testState = .result(.ready)
            savedMessage = "Post-processing settings saved and ready."
            errorMessage = nil
        } catch {
            savedMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        settings.clear()
        configuration = AIProviderConfiguration()
        customCommand = ""
        commandErrorMessage = nil
        lastTestedConfiguration = nil
        testState = .result(.disabled)
        savedMessage = "AI settings cleared. CLI sign-ins and credentials were not changed."
        errorMessage = nil
    }

    private func applyCustomCommand() {
        guard !suppressCommandApplication else { return }
        guard configuration.provider != .disabled else { return }
        lastTestedConfiguration = nil
        testState = .untested
        savedMessage = nil
        errorMessage = nil

        let template: AILocalCLICommandTemplate
        do {
            template = try AILocalCLICommandTemplate.parse(customCommand)
        } catch {
            commandErrorMessage = error.localizedDescription
            return
        }

        commandErrorMessage = nil
        configuration = AIProviderConfiguration(
            provider: template.provider,
            model: template.model,
            timeout: configuration.timeout,
            contextChoice: configuration.contextChoice
        )
    }
}

@MainActor
struct AICommandEditor: View {
    @Binding var command: String
    let accessibilityLabel: String
    let canSave: Bool
    let save: () -> Void
    let canTestConnection: Bool
    let testConnection: () async -> Void
    let testState: AISettingsTestState
    let testDetail: String
    let selectedModelName: String?
    let confirmedModelName: String?
    let commandErrorMessage: String?
    let savedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("CLI command", text: $command)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .accessibilityLabel(accessibilityLabel)

                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave)
            }

            if let commandErrorMessage {
                Label(commandErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let confirmedModelName {
                Label(
                    "Connection confirmed — Model: \(confirmedModelName)",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            } else if let selectedModelName {
                Label(
                    "Model selected: \(selectedModelName)",
                    systemImage: "cpu"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(!canTestConnection)
                .accessibilityValue(canTestConnection ? "Enabled" : "Disabled")

                if testState == .testing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing AI connection")
                }

                Label(testState.title, systemImage: testState.symbolName)
                    .font(.caption)
                    .foregroundStyle(testStateColor)
            }

            if shouldShowTestDetail {
                Text(testDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shouldShowTestDetail: Bool {
        switch testState {
        case .result(.ready), .untested:
            false
        case .testing, .result:
            true
        }
    }

    private var testStateColor: Color {
        switch testState {
        case .result(.ready):
            .green
        case .result(.disabled), .untested, .testing:
            .secondary
        case .result:
            .orange
        }
    }
}

@MainActor
struct AISettingsView: View {
    @Bindable var controller: AISettingsController
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case primaryField
        case errorSummary
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meeting Post-Processing")
                            .font(.title3.weight(.semibold))
                        Text("Optional. Powers meeting titles, summaries, and transcript analysis.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                LabeledContent {
                    Picker("Current choice", selection: currentChoice) {
                        Text("Off").tag(false)
                        Text("Local CLI").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel("Current AI choice")
                    .accessibilityFocused($accessibilityFocus, equals: .primaryField)
                } label: {
                    settingLabel(
                        "Current choice",
                        detail: "Use a local command-line AI tool for post-processing."
                    )
                }

            }

            if controller.configuration.provider != .disabled {
                Section("CLI Command") {
                    AICommandEditor(
                        command: $controller.customCommand,
                        accessibilityLabel: "Meeting AI CLI command",
                        canSave: controller.canSave,
                        save: controller.save,
                        canTestConnection: controller.canTestConnection,
                        testConnection: controller.testConnection,
                        testState: controller.testState,
                        testDetail: controller.testDetail,
                        selectedModelName: controller.selectedModelName,
                        confirmedModelName: controller.confirmedModelName,
                        commandErrorMessage: controller.commandErrorMessage,
                        savedMessage: controller.savedMessage
                    )

                    if let errorMessage = controller.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("AI settings error: \(errorMessage)")
                            .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Setup")
        .onAppear { accessibilityFocus = .primaryField }
        .onChange(of: controller.errorMessage) { _, error in
            if error != nil { accessibilityFocus = .errorSummary }
        }
    }

    private var currentChoice: Binding<Bool> {
        Binding(
            get: { controller.configuration.provider != .disabled },
            set: { enabled in
                if enabled {
                    if controller.configuration.provider == .disabled {
                        controller.selectProvider(.codex)
                    }
                } else {
                    controller.clear()
                }
            }
        )
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
