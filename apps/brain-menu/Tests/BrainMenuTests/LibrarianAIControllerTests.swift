import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct LibrarianAIControllerTests {
    @Test
    func settingsKeepLibrarianCommandSeparateAndManualRunUsesSavedChoice() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: true,
                command: AILocalCLICommandTemplate.defaultCommand
            )
        )
        let processor = TestLibrarianProcessor()
        let providerFactory = TestLibrarianProviderFactory(state: .ready)
        let controller = LibrarianAIController(
            settings: settings,
            processor: processor,
            providerFactory: providerFactory,
            deploymentMode: { .local }
        )

        controller.command =
            "codex exec --skip-git-repo-check --model gpt-5.6-sol"
        #expect(controller.selectedModelName == "gpt-5.6-sol")
        #expect(controller.confirmedModelName == nil)
        await controller.testConnection()
        #expect(controller.testState == .result(.ready))
        #expect(controller.confirmedModelName == "gpt-5.6-sol")
        #expect(providerFactory.configurations.map(\.model) == ["gpt-5.6-sol"])
        controller.save()
        await controller.runNow()

        #expect(
            settings.configuration.command
                == "codex exec --skip-git-repo-check --model gpt-5.6-sol"
        )
        #expect(await processor.commands == [
            "codex exec --skip-git-repo-check --model gpt-5.6-sol",
        ])
        #expect(controller.state == .completed)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func deliveredCaptureSchedulesLocalLibrarianWhenAutomationIsEnabled() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: false,
                command: AILocalCLICommandTemplate.defaultCommand
            )
        )
        let processor = TestLibrarianProcessor()
        let controller = LibrarianAIController(
            settings: settings,
            processor: processor,
            deploymentMode: { .local },
            sleep: { duration in
                if duration == .seconds(15 * 60) {
                    try await Task.sleep(for: .seconds(3_600))
                }
            }
        )

        controller.start()
        controller.automaticProcessingEnabled = true
        controller.captureDelivered()
        await controller.waitForPendingWork()
        controller.stop()

        #expect(await processor.commands.count == 1)
        #expect(controller.state == .completed)
    }

    @Test
    func invalidCommandNeverCrossesTheProcessBoundary() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: true,
                command: AILocalCLICommandTemplate.defaultCommand
            )
        )
        let processor = TestLibrarianProcessor()
        let controller = LibrarianAIController(
            settings: settings,
            processor: processor,
            deploymentMode: { .local }
        )

        controller.command = "codex exec --model 'model; export SECRET'"
        await controller.runNow()

        #expect(await processor.commands.isEmpty)
        #expect(controller.errorMessage != nil)
    }

    @Test
    func legacyModelSettingMigratesToCommandTemplate() throws {
        let data = Data(
            #"{"automaticProcessingEnabled":true,"model":"gpt-5.4-mini"}"#.utf8
        )

        let configuration = try JSONDecoder().decode(
            LibrarianAIConfiguration.self,
            from: data
        )

        #expect(
            configuration.command
                == "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
    }
}

private final class TestLibrarianSettings: LibrarianAISettingsPersisting, @unchecked Sendable {
    var configuration: LibrarianAIConfiguration

    init(configuration: LibrarianAIConfiguration) {
        self.configuration = configuration
    }

    func load() -> LibrarianAIConfiguration {
        configuration
    }

    func save(_ configuration: LibrarianAIConfiguration) throws {
        self.configuration = configuration
    }
}

private actor TestLibrarianProcessor: LibrarianProcessing {
    private(set) var commands: [String] = []

    func process(command: String) async throws -> BrainJobCreated {
        commands.append(command)
        return BrainJobCreated(id: UUID().uuidString, state: .completed)
    }
}

private final class TestLibrarianProviderFactory: AIProviderMaking, @unchecked Sendable {
    let state: AIConnectionState
    private let lock = NSLock()
    private var storedConfigurations: [AIProviderConfiguration] = []

    init(state: AIConnectionState) {
        self.state = state
    }

    var configurations: [AIProviderConfiguration] {
        lock.withLock { storedConfigurations }
    }

    func makeProvider(configuration: AIProviderConfiguration) -> any AIProviding {
        lock.withLock {
            storedConfigurations.append(configuration)
        }
        return TestLibrarianProvider(state: state)
    }
}

private struct TestLibrarianProvider: AIProviding {
    let state: AIConnectionState

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        Data()
    }

    func testConnection() async -> AIConnectionState {
        state
    }
}
