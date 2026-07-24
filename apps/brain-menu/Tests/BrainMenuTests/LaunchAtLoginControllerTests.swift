import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct LaunchAtLoginControllerTests {
    @Test
    func mapsEveryServiceStatusToAVisibleState() {
        #expect(LaunchAtLoginController.state(for: .enabled) == .enabled)
        #expect(LaunchAtLoginController.state(for: .requiresApproval) == .requiresApproval)
        #expect(LaunchAtLoginController.state(for: .notRegistered) == .notRegistered)
        #expect(LaunchAtLoginController.state(for: .notFound) == .unavailable)
    }

    @Test
    func firstLaunchRegistrationIsAttemptedOnlyOnce() throws {
        let service = LaunchAtLoginServiceDouble(status: .notRegistered)
        let defaults = try makeDefaults()
        let firstController = LaunchAtLoginController(service: service, defaults: defaults)

        firstController.registerOnFirstLaunchIfNeeded()
        firstController.registerOnFirstLaunchIfNeeded()
        LaunchAtLoginController(service: service, defaults: defaults)
            .registerOnFirstLaunchIfNeeded()

        #expect(service.registerCalls == 1)
        #expect(defaults.bool(forKey: LaunchAtLoginController.registrationAttemptedKey))
        #expect(firstController.state == .enabled)
    }

    @Test
    func deniedRegistrationRemainsVisibleWithoutBeingRetried() throws {
        let service = LaunchAtLoginServiceDouble(
            status: .notRegistered,
            statusAfterRegistration: .requiresApproval
        )
        let defaults = try makeDefaults()
        let controller = LaunchAtLoginController(service: service, defaults: defaults)

        controller.registerOnFirstLaunchIfNeeded()
        controller.registerOnFirstLaunchIfNeeded()
        controller.refresh()

        #expect(service.registerCalls == 1)
        #expect(controller.state == .requiresApproval)
    }

    @Test
    func explicitActionsRegisterUnregisterAndOpenSettings() throws {
        let service = LaunchAtLoginServiceDouble(status: .notRegistered)
        let defaults = try makeDefaults()
        var openCalls = 0
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            openLoginItems: { openCalls += 1 }
        )

        controller.register()
        controller.unregister()
        controller.openLoginItemsSettings()

        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 1)
        #expect(controller.state == .notRegistered)
        #expect(openCalls == 1)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }
}

@MainActor
private final class LaunchAtLoginServiceDouble: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerCalls = 0
    var unregisterCalls = 0

    private let statusAfterRegistration: LaunchAtLoginServiceStatus

    init(
        status: LaunchAtLoginServiceStatus,
        statusAfterRegistration: LaunchAtLoginServiceStatus = .enabled
    ) {
        self.status = status
        self.statusAfterRegistration = statusAfterRegistration
    }

    func register() throws {
        registerCalls += 1
        status = statusAfterRegistration
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}
