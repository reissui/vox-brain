import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LaunchAtLoginState: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required"
        case .notRegistered: "Not registered"
        case .unavailable: "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            "Brain opens automatically when you log in."
        case .requiresApproval:
            "Allow Brain in System Settings → General → Login Items."
        case .notRegistered:
            "Brain will not open automatically when you log in."
        case .unavailable:
            "This copy of Brain is not available to register as a login item."
        }
    }

    var symbolName: String {
        switch self {
        case .enabled: "checkmark.circle.fill"
        case .requiresApproval: "exclamationmark.triangle.fill"
        case .notRegistered: "minus.circle"
        case .unavailable: "xmark.circle"
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class MainAppLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    static let registrationAttemptedKey = "BrainMenu.didAttemptInitialLaunchAtLoginRegistration"

    private(set) var state: LaunchAtLoginState
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openLoginItems: () -> Void

    init(
        service: any LaunchAtLoginServicing = MainAppLaunchAtLoginService(),
        defaults: UserDefaults = .standard,
        openLoginItems: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.service = service
        self.defaults = defaults
        self.openLoginItems = openLoginItems
        state = Self.state(for: service.status)
    }

    static func state(for status: LaunchAtLoginServiceStatus) -> LaunchAtLoginState {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        }
    }

    func registerOnFirstLaunchIfNeeded() {
        guard !defaults.bool(forKey: Self.registrationAttemptedKey) else {
            refresh()
            return
        }

        // Persist before calling the service. A denial or thrown error must not
        // cause another system prompt on every subsequent view refresh/launch.
        defaults.set(true, forKey: Self.registrationAttemptedKey)
        register()
    }

    func register() {
        errorMessage = nil
        do {
            try service.register()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func unregister() {
        errorMessage = nil
        do {
            try service.unregister()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        state = Self.state(for: service.status)
    }

    func openLoginItemsSettings() {
        openLoginItems()
    }
}
