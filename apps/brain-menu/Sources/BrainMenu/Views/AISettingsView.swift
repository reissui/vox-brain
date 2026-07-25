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
            "AI analysis is disabled. Use Clear to remove saved AI settings."
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
                    readinessBadge
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
                Section("CLI Template") {
                    LabeledContent {
                        TextField(
                            AILocalCLICommandTemplate.exampleCommand,
                            text: $controller.customCommand
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Meeting AI CLI template")
                    } label: {
                        settingLabel(
                            "Command",
                            detail: "Enter a Codex or Claude CLI template, including an optional model."
                        )
                    }

                    if let commandErrorMessage = controller.commandErrorMessage {
                        Label(commandErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Label(
                        "Brain adds its read-only safety and response-schema arguments. It never invokes a shell.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if controller.configuration.provider != .disabled {
                Section {
                    Button("Test Connection") {
                        Task { await controller.testConnection() }
                    }
                    .disabled(!controller.canTestConnection)
                    .accessibilityValue(controller.canTestConnection ? "Enabled" : "Disabled")

                    LabeledContent {
                        Label(controller.testState.title, systemImage: controller.testState.symbolName)
                            .accessibilityLabel(controller.testAccessibilityLabel)
                    } label: {
                        settingLabel("Readiness", detail: controller.testDetail)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Save") {
                        controller.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!controller.canSave)

                    Button("Clear", role: .destructive) {
                        controller.clear()
                    }
                    .help("Removes only Brain's AI settings. It does not log out or delete CLI credentials.")
                    .accessibilityHint("Removes Brain's AI command setting but keeps CLI credentials")

                    Spacer()
                }

                Text("Clear removes only Brain's AI command setting. It never logs out of Codex or Claude and never deletes CLI credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let savedMessage = controller.savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .accessibilityLabel("AI settings status: \(savedMessage)")
                }
                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("AI settings error: \(errorMessage)")
                        .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
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
                    controller.selectProvider(.disabled)
                }
            }
        )
    }

    private var readinessBadge: some View {
        Label(controller.testState.title, systemImage: controller.testState.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(readinessColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(readinessColor.opacity(0.1), in: Capsule())
            .accessibilityLabel(controller.testAccessibilityLabel)
    }

    private var readinessColor: Color {
        switch controller.testState {
        case .result(.ready):
            .green
        case .result(.disabled), .untested, .testing:
            .secondary
        case .result:
            .orange
        }
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
