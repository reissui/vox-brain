import AppKit
import Foundation
import ServiceManagement

enum BundledVoxTypeLayout {
    static let bundleIdentifier = "app.voxbrain.voxtype"
    static let relativeApplicationPath = "Contents/Library/LoginItems/VoxType.app"
    static let relativeExecutablePath = "\(relativeApplicationPath)/Contents/MacOS/voxtype"

    static func applicationURL(in brainBundleURL: URL = Bundle.main.bundleURL) -> URL {
        brainBundleURL.appendingPathComponent(relativeApplicationPath, isDirectory: true)
    }

    static func executableURL(in brainBundleURL: URL = Bundle.main.bundleURL) -> URL {
        brainBundleURL.appendingPathComponent(relativeExecutablePath, isDirectory: false)
    }

    static func contains(
        executableURL: URL,
        brainBundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        executableURL.standardizedFileURL
            == self.executableURL(in: brainBundleURL).standardizedFileURL
    }
}

enum BundledVoxTypeServiceStatus: Equatable, Sendable {
    case unavailable
    case notRegistered
    case enabled
    case requiresApproval
}

enum BundledVoxTypeServiceError: LocalizedError {
    case unavailable
    case approvalRequired
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This copy of Brain does not contain its verified VoxType helper."
        case .approvalRequired:
            "Allow Brain's VoxType background item in System Settings, then check again."
        case .launchFailed:
            "Brain enabled VoxType but could not start it. Try again."
        }
    }
}

@MainActor
protocol BundledVoxTypeServicing: AnyObject {
    var status: BundledVoxTypeServiceStatus { get }
    func enableAndLaunch() async throws
    func openLoginItemsSettings()
}

@MainActor
final class SystemBundledVoxTypeService: BundledVoxTypeServicing {
    private let service: SMAppService
    private let applicationURL: URL
    private let executableURL: URL
    private let workspace: NSWorkspace
    private let fileManager: FileManager

    init(
        brainBundleURL: URL = Bundle.main.bundleURL,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        service = SMAppService.loginItem(identifier: BundledVoxTypeLayout.bundleIdentifier)
        applicationURL = BundledVoxTypeLayout.applicationURL(in: brainBundleURL)
        executableURL = BundledVoxTypeLayout.executableURL(in: brainBundleURL)
        self.workspace = workspace
        self.fileManager = fileManager
    }

    var status: BundledVoxTypeServiceStatus {
        guard fileManager.fileExists(atPath: applicationURL.path),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            return .unavailable
        }
        return switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func enableAndLaunch() async throws {
        switch status {
        case .unavailable:
            throw BundledVoxTypeServiceError.unavailable
        case .requiresApproval:
            throw BundledVoxTypeServiceError.approvalRequired
        case .notRegistered:
            try service.register()
        case .enabled:
            break
        }

        guard service.status != .requiresApproval else {
            throw BundledVoxTypeServiceError.approvalRequired
        }

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: BundledVoxTypeLayout.bundleIdentifier
        )
        guard running.allSatisfy(\.isTerminated) else { return }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.environment = ["RUST_LOG": "voxtype=info,warn"]
            _ = try await workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            )
        } catch {
            throw BundledVoxTypeServiceError.launchFailed
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
