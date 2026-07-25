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
    static let cliTools: [AIProvider] = [.codex, .claude, .advanced]

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
    @ObservationIgnored private let executableResolver: any AIExecutableResolving
    @ObservationIgnored private var lastTestedConfiguration: AIProviderConfiguration?

    init(
        settings: any AISettingsPersisting,
        providerFactory: any AIProviderMaking = LocalAIProviderFactory(),
        executableResolver: any AIExecutableResolving = AIExecutableResolver()
    ) {
        self.settings = settings
        self.providerFactory = providerFactory
        self.executableResolver = executableResolver
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
        var renderedArguments = loaded.arguments
        if loaded.provider == .advanced, let model = loaded.model {
            renderedArguments.append(contentsOf: ["--model", model])
        }
        customCommand = AICommandLine.render(
            executable: loaded.executableURL,
            arguments: renderedArguments
        )
    }

    var canTestConnection: Bool {
        configuration.provider != .disabled
            && testState != .testing
            && commandErrorMessage == nil
            && (!exposesManualConfiguration || configuration.executableURL != nil)
    }

    var canSave: Bool {
        testState == .result(.ready)
            && lastTestedConfiguration == configuration
            && commandErrorMessage == nil
    }

    var usesPreset: Bool {
        configuration.provider == .codex || configuration.provider == .claude
    }

    var exposesManualConfiguration: Bool {
        configuration.provider == .advanced
    }

    var resolvedExecutablePath: String? {
        guard usesPreset else { return nil }
        return executableResolver.resolveExecutable(for: configuration.provider)?.path
    }

    var commandPreview: String? {
        configuration.provider.commandPreview(
            executablePath: resolvedExecutablePath,
            model: configuration.model
        )
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

    var providerHelp: String {
        switch configuration.provider {
        case .disabled:
            "Meeting AI is off. Existing raw transcripts can still be completed and uploaded."
        case .codex:
            "Uses your existing Codex CLI sign-in with Brain's fixed, read-only command and your optional model choice."
        case .claude:
            "Uses your existing Claude CLI sign-in with your optional model choice. Brain never reads or stores Claude credentials."
        case .advanced:
            "Parses this command into literal arguments and runs the executable directly—never through a shell."
        }
    }

    var executablePath: String {
        get { configuration.executableURL?.path ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.executableURL = trimmed.isEmpty
                ? nil
                : URL(fileURLWithPath: trimmed, isDirectory: false)
        }
    }

    var model: String {
        get { configuration.model ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.model = trimmed.isEmpty ? nil : trimmed
        }
    }

    var timeout: TimeInterval {
        get { configuration.timeout }
        set { configuration.timeout = AIProviderConfiguration.boundedTimeout(newValue) }
    }

    func chooseExecutable(_ url: URL) {
        guard configuration.provider == .advanced else { return }
        configuration.executableURL = url.standardizedFileURL
        customCommand = AICommandLine.render(
            executable: configuration.executableURL,
            arguments: configuration.arguments
        )
    }

    func selectProvider(_ provider: AIProvider) {
        let previous = configuration
        if provider == .advanced {
            configuration = AIProviderConfiguration(
                provider: .advanced,
                timeout: previous.timeout,
                contextChoice: previous.contextChoice
            )
            customCommand = ""
        } else {
            var selected = previous
            selected.provider = provider
            configuration = selected.canonicalized()
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
        guard configuration.provider == .advanced else { return }
        lastTestedConfiguration = nil
        testState = .untested
        savedMessage = nil
        errorMessage = nil

        let tokens: [String]
        do {
            tokens = try AICommandLine.parse(customCommand)
        } catch AICommandLineError.empty {
            commandErrorMessage = nil
            configuration.executableURL = nil
            configuration.arguments = []
            configuration.model = nil
            return
        } catch {
            commandErrorMessage = error.localizedDescription
            return
        }

        let executableToken = tokens[0]
        let executableURL: URL?
        if executableToken.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executableToken, isDirectory: false)
                .standardizedFileURL
        } else {
            executableURL = executableResolver.resolveExecutable(named: executableToken)
        }

        guard let executableURL else {
            commandErrorMessage = "The command executable “\(executableToken)” was not found."
            configuration.executableURL = nil
            configuration.arguments = Array(tokens.dropFirst())
            configuration.model = nil
            return
        }

        commandErrorMessage = nil
        configuration.executableURL = executableURL
        configuration.arguments = Array(tokens.dropFirst())
        configuration.model = nil
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

                if controller.configuration.provider != .disabled {
                    LabeledContent {
                        Picker("CLI Tool", selection: Binding(
                            get: { controller.configuration.provider },
                            set: { controller.selectProvider($0) }
                        )) {
                            ForEach(AISettingsController.cliTools, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel("CLI tool")
                    } label: {
                        settingLabel(
                            "CLI Tool",
                            detail: "Choose a preset or enter a custom command."
                        )
                    }

                    Text(controller.providerHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if controller.configuration.provider != .disabled {
                Section {
                    if controller.usesPreset {
                        LabeledContent {
                            TextField(
                                "Provider default",
                                text: Binding(
                                    get: { controller.model },
                                    set: { controller.model = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .accessibilityLabel("Optional provider model")
                        } label: {
                            settingLabel(
                                "Model",
                                detail: "Leave blank to use the CLI provider default."
                            )
                        }
                    }

                    LabeledContent {
                        if controller.usesPreset {
                            Text(controller.commandPreview ?? "Executable not found")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(
                                    controller.resolvedExecutablePath == nil ? .secondary : .primary
                                )
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    controller.commandPreview.map {
                                        "Post-processing command: \($0)"
                                    } ?? "Post-processing command: executable not found"
                                )
                        } else {
                            TextField(
                                "codex exec --skip-git-repo-check --model gpt-5.4-mini -",
                                text: $controller.customCommand
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Custom CLI command")
                        }
                    } label: {
                        settingLabel(
                            "Command",
                            detail: controller.usesPreset
                                ? "Brain supplies its response schema and sends the prompt on stdin."
                                : "The command is parsed into literal arguments; the prompt is sent on stdin."
                        )
                    }

                    if let commandErrorMessage = controller.commandErrorMessage {
                        Label(commandErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    LabeledContent {
                        HStack {
                            TextField(
                                "Seconds",
                                value: Binding(
                                    get: { controller.timeout },
                                    set: { controller.timeout = $0 }
                                ),
                                format: .number.precision(.fractionLength(0))
                            )
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Provider timeout in seconds")
                            Text("seconds")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        settingLabel(
                            "Timeout",
                            detail: "Maximum time to wait for a response, up to 900 seconds."
                        )
                    }

                    Label(
                        "Runs a command on this Mac. The command may contact its own service.",
                        systemImage: "arrow.up.right.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Label(AIProvider.providerNote, systemImage: "exclamationmark.bubble")
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
                    .accessibilityHint("Removes Brain's provider settings but keeps CLI credentials")

                    Spacer()
                }

                Text("Clear removes only Brain's provider, command, model, timeout, and context settings. It never logs out of Codex or Claude and never deletes CLI credentials.")
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

            if controller.configuration.provider != .disabled {
                Section("Transcript Context") {
                    Picker("Context sent to AI", selection: $controller.configuration.contextChoice) {
                        Text("Rich transcript").tag(AIContextChoice.rich)
                        Text("Plain transcript").tag(AIContextChoice.plain)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Transcript context sent to the provider")

                    Text("Rich transcripts include timestamps and available speaker labels. Plain transcripts send only the spoken text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
