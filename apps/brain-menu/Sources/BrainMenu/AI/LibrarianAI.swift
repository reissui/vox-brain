import Foundation
import Observation

struct LibrarianAIConfiguration: Codable, Equatable, Sendable {
    var automaticProcessingEnabled: Bool
    var command: String

    init(
        automaticProcessingEnabled: Bool = true,
        command: String = AILocalCLICommandTemplate.defaultCommand
    ) {
        self.automaticProcessingEnabled = automaticProcessingEnabled
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case automaticProcessingEnabled
        case command
        case model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automaticProcessingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticProcessingEnabled
        ) ?? true
        if let command = try container.decodeIfPresent(String.self, forKey: .command) {
            self.command = command
        } else {
            let legacyModel = try container.decodeIfPresent(String.self, forKey: .model)
            command = AILocalCLICommandTemplate.render(
                provider: .codex,
                model: legacyModel
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(automaticProcessingEnabled, forKey: .automaticProcessingEnabled)
        try container.encode(command, forKey: .command)
    }
}

protocol LibrarianAISettingsPersisting: Sendable {
    func load() -> LibrarianAIConfiguration
    func save(_ configuration: LibrarianAIConfiguration) throws
}

final class LibrarianAISettingsStore: LibrarianAISettingsPersisting, @unchecked Sendable {
    static let defaultsKey = "BrainMenu.librarianAISettings.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LibrarianAIConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let configuration = try? JSONDecoder().decode(
                  LibrarianAIConfiguration.self,
                  from: data
              ) else {
            return LibrarianAIConfiguration()
        }
        return configuration
    }

    func save(_ configuration: LibrarianAIConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.defaultsKey)
    }
}

protocol LibrarianProcessing: Sendable {
    func process(command: String) async throws -> BrainJobCreated
}

struct LocalLibrarianProcessor: LibrarianProcessing {
    func process(command: String) async throws -> BrainJobCreated {
        guard let configuration = BrainRuntime.configuration() else {
            throw LocalBrainError.invalidConfiguration
        }
        let template = try AILocalCLICommandTemplate.parse(command)
        guard template.provider == .codex else {
            throw AILocalCLICommandTemplateError.librarianRequiresCodex
        }
        let client = try LocalBrainClient(
            configuration: configuration,
            librarianModel: template.model
        )
        return try await client.createJob(kind: .process, question: nil)
    }
}

enum LibrarianAIRunState: Equatable, Sendable {
    case idle
    case scheduled
    case running
    case completed
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Ready"
        case .scheduled: "Queued"
        case .running: "Organising"
        case .completed: "Up to date"
        case .failed: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "checkmark.circle"
        case .scheduled: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
@Observable
final class LibrarianAIController {
    static let automaticInterval: Duration = .seconds(15 * 60)
    static let captureDebounce: Duration = .seconds(3)

    var automaticProcessingEnabled: Bool
    var command: String {
        didSet {
            guard command != oldValue else { return }
            testState = .untested
            lastTestedCommand = nil
            savedMessage = nil
            errorMessage = nil
        }
    }

    private(set) var state: LibrarianAIRunState = .idle
    private(set) var testState: AISettingsTestState = .untested
    private(set) var savedMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let settings: any LibrarianAISettingsPersisting
    @ObservationIgnored private let processor: any LibrarianProcessing
    @ObservationIgnored private let providerFactory: any AIProviderMaking
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var savedConfiguration: LibrarianAIConfiguration
    @ObservationIgnored private var lastTestedCommand: String?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(
        settings: any LibrarianAISettingsPersisting = LibrarianAISettingsStore(),
        processor: any LibrarianProcessing = LocalLibrarianProcessor(),
        providerFactory: any AIProviderMaking = LocalAIProviderFactory(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.settings = settings
        self.processor = processor
        self.providerFactory = providerFactory
        self.sleep = sleep
        let loaded = settings.load()
        savedConfiguration = loaded
        automaticProcessingEnabled = loaded.automaticProcessingEnabled
        command = loaded.command
    }

    var isWorking: Bool {
        state == .running || state == .scheduled
    }

    var commandErrorMessage: String? {
        do {
            _ = try validatedTemplate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canSave: Bool {
        !isWorking && commandErrorMessage == nil
    }

    var canTestConnection: Bool {
        !isWorking && testState != .testing && commandErrorMessage == nil
    }

    var selectedModelName: String? {
        guard let template = try? validatedTemplate() else { return nil }
        return template.model ?? "CLI default"
    }

    var confirmedModelName: String? {
        let candidate = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard testState == .result(.ready),
              lastTestedCommand == candidate else {
            return nil
        }
        return selectedModelName
    }

    var testDetail: String {
        if testState == .result(.unauthenticated) {
            return "codex login --device-auth"
        }
        if testState == .result(.missingExecutable) {
            return "Codex CLI was not found. Install Codex or ChatGPT, then test again."
        }
        return testState.detail
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        scheduleAutomaticRun(after: Self.captureDebounce)
        periodicTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.sleep(Self.automaticInterval)
                } catch {
                    return
                }
                self.scheduleAutomaticRun(after: .zero)
            }
        }
    }

    func stop() {
        isStarted = false
        scheduledTask?.cancel()
        scheduledTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        processingTask?.cancel()
        processingTask = nil
        if isWorking { state = .idle }
    }

    func captureDelivered() {
        scheduleAutomaticRun(after: Self.captureDebounce)
    }

    func save() {
        do {
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try validatedTemplate(trimmedCommand)
            let configuration = LibrarianAIConfiguration(
                automaticProcessingEnabled: automaticProcessingEnabled,
                command: trimmedCommand
            )
            try settings.save(configuration)
            savedConfiguration = configuration
            command = trimmedCommand
            savedMessage = "Librarian AI settings saved."
            errorMessage = nil
        } catch {
            savedMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func testConnection() async {
        guard canTestConnection else { return }
        let candidate = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let template: AILocalCLICommandTemplate
        do {
            template = try validatedTemplate(candidate)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        testState = .testing
        savedMessage = nil
        errorMessage = nil
        let result = await providerFactory.makeProvider(configuration: AIProviderConfiguration(
            provider: .codex,
            model: template.model
        )).testConnection()
        guard command.trimmingCharacters(in: .whitespacesAndNewlines) == candidate else {
            return
        }
        testState = .result(result)
        lastTestedCommand = result == .ready ? candidate : nil
    }

    func runNow() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard processingTask == nil else { return }
        save()
        guard errorMessage == nil else { return }
        await processSavedConfiguration()
    }

    func waitForPendingWork() async {
        await scheduledTask?.value
        await processingTask?.value
    }

    private func scheduleAutomaticRun(after delay: Duration) {
        guard isStarted,
              automaticProcessingEnabled,
              processingTask == nil else {
            return
        }
        scheduledTask?.cancel()
        state = .scheduled
        scheduledTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(delay)
            } catch {
                if self.state == .scheduled { self.state = .idle }
                return
            }
            self.scheduledTask = nil
            await self.processSavedConfiguration()
        }
    }

    private func processSavedConfiguration() async {
        guard processingTask == nil else {
            if state == .scheduled { state = .idle }
            return
        }
        let configuration = savedConfiguration
        state = .running
        errorMessage = nil
        let task = Task { [processor] in
            try await processor.process(command: configuration.command)
        }
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let job = try await task.value
                if job.state == .completed {
                    self.state = .completed
                    self.savedMessage = "The Librarian finished organising the inbox."
                } else {
                    self.state = .failed("The Librarian process did not complete.")
                    self.errorMessage = "The Librarian process did not complete."
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                let message = error.localizedDescription
                self.state = .failed(message)
                self.errorMessage = message
            }
            self.processingTask = nil
        }
        await processingTask?.value
    }

    private func validatedTemplate(
        _ candidate: String? = nil
    ) throws -> AILocalCLICommandTemplate {
        let template = try AILocalCLICommandTemplate.parse(
            candidate ?? command.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard template.provider == .codex else {
            throw AILocalCLICommandTemplateError.librarianRequiresCodex
        }
        return template
    }
}
