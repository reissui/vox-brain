import Foundation
import Observation

struct LibrarianAIConfiguration: Codable, Equatable, Sendable {
    var automaticProcessingEnabled: Bool
    var model: String?

    init(
        automaticProcessingEnabled: Bool = true,
        model: String? = nil
    ) {
        self.automaticProcessingEnabled = automaticProcessingEnabled
        self.model = model
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
    func process(model: String?) async throws -> BrainJobCreated
}

struct LocalLibrarianProcessor: LibrarianProcessing {
    func process(model: String?) async throws -> BrainJobCreated {
        guard BrainRuntime.deploymentMode() == .local,
              let configuration = BrainRuntime.localConfiguration() else {
            throw LocalBrainError.invalidConfiguration
        }
        let client = try LocalBrainClient(
            configuration: configuration,
            librarianModel: model
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
    var model: String

    private(set) var state: LibrarianAIRunState = .idle
    private(set) var savedMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let settings: any LibrarianAISettingsPersisting
    @ObservationIgnored private let processor: any LibrarianProcessing
    @ObservationIgnored private let deploymentMode: @MainActor () -> BrainDeploymentMode?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var savedConfiguration: LibrarianAIConfiguration
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(
        settings: any LibrarianAISettingsPersisting = LibrarianAISettingsStore(),
        processor: any LibrarianProcessing = LocalLibrarianProcessor(),
        deploymentMode: @escaping @MainActor () -> BrainDeploymentMode? = {
            BrainRuntime.deploymentMode()
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.settings = settings
        self.processor = processor
        self.deploymentMode = deploymentMode
        self.sleep = sleep
        let loaded = settings.load()
        savedConfiguration = loaded
        automaticProcessingEnabled = loaded.automaticProcessingEnabled
        model = loaded.model ?? ""
    }

    var isWorking: Bool {
        state == .running || state == .scheduled
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
            let validatedModel = try AIProviderValidation.validatedModel(model)
            let configuration = LibrarianAIConfiguration(
                automaticProcessingEnabled: automaticProcessingEnabled,
                model: validatedModel
            )
            try settings.save(configuration)
            savedConfiguration = configuration
            model = validatedModel ?? ""
            savedMessage = "Librarian AI settings saved."
            errorMessage = nil
        } catch {
            savedMessage = nil
            errorMessage = "Enter a valid Codex model identifier, or leave the model blank."
        }
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
              deploymentMode() == .local,
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
        guard deploymentMode() == .local, processingTask == nil else {
            if state == .scheduled { state = .idle }
            return
        }
        let configuration = savedConfiguration
        state = .running
        errorMessage = nil
        let task = Task { [processor] in
            try await processor.process(model: configuration.model)
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
}
