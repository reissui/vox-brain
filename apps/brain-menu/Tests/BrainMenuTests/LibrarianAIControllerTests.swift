import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct LibrarianAIControllerTests {
    @Test
    func settingsKeepLibrarianModelSeparateAndManualRunUsesSavedChoice() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: true,
                model: nil
            )
        )
        let processor = TestLibrarianProcessor()
        let controller = LibrarianAIController(
            settings: settings,
            processor: processor,
            deploymentMode: { .local }
        )

        controller.model = "gpt-5.4-mini"
        controller.save()
        await controller.runNow()

        #expect(settings.configuration.model == "gpt-5.4-mini")
        #expect(await processor.models == ["gpt-5.4-mini"])
        #expect(controller.state == .completed)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func deliveredCaptureSchedulesLocalLibrarianWhenAutomationIsEnabled() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: false,
                model: nil
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

        #expect(await processor.models.count == 1)
        #expect(controller.state == .completed)
    }

    @Test
    func invalidModelNeverCrossesTheProcessBoundary() async {
        let settings = TestLibrarianSettings(
            configuration: LibrarianAIConfiguration(
                automaticProcessingEnabled: true,
                model: nil
            )
        )
        let processor = TestLibrarianProcessor()
        let controller = LibrarianAIController(
            settings: settings,
            processor: processor,
            deploymentMode: { .local }
        )

        controller.model = "model; export SECRET"
        await controller.runNow()

        #expect(await processor.models.isEmpty)
        #expect(controller.errorMessage?.contains("valid Codex model") == true)
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
    private(set) var models: [String?] = []

    func process(model: String?) async throws -> BrainJobCreated {
        models.append(model)
        return BrainJobCreated(id: UUID().uuidString, state: .completed)
    }
}
