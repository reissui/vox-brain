import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum OnboardingCheckID: String, CaseIterable, Identifiable, Sendable {
    case voxTypeExecutable
    case voxTypeVersion
    case voxTypeDaemon
    case voxTypeHotkey
    case dictationModel
    case meetingModel
    case microphone
    case systemAudio
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .voxTypeExecutable: "VoxType installed"
        case .voxTypeVersion: "VoxType compatible"
        case .voxTypeDaemon: "VoxType running"
        case .voxTypeHotkey: "VoxType shortcut"
        case .dictationModel: "Dictation model"
        case .meetingModel: "Meeting model (optional)"
        case .microphone: "Microphone"
        case .systemAudio: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        }
    }
}

enum OnboardingCheckState: String, Equatable, Sendable {
    case checking
    case installing
    case ready
    case optional
    case actionNeeded
    case denied
    case unavailable

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .installing: "Installing…"
        case .ready: "Ready"
        case .optional: "Optional"
        case .actionNeeded: "Action needed"
        case .denied: "Denied"
        case .unavailable: "Unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "clock"
        case .installing: "arrow.down.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .optional: "info.circle.fill"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }
}

enum OnboardingPermission: String, CaseIterable, Equatable, Sendable {
    case microphone
    case systemAudio
    case accessibility

    var systemSettingsURL: URL {
        let pane: String = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )!
    }
}

enum OnboardingAction: Equatable, Sendable {
    case installVoxType
    case openVoxTypeGuide
    case recheck
    case requestPermission(OnboardingPermission)
    case openSystemSettings(OnboardingPermission)

    var label: String {
        switch self {
        case .installVoxType: "Install VoxType"
        case .openVoxTypeGuide: "Open VoxType Guide"
        case .recheck: "Check Again"
        case .requestPermission(let permission):
            switch permission {
            case .microphone: "Allow Microphone"
            case .systemAudio: "Allow System Audio"
            case .accessibility: "Allow Accessibility"
            }
        case .openSystemSettings:
            "Open System Settings"
        }
    }
}

struct OnboardingCheck: Identifiable, Equatable, Sendable {
    let id: OnboardingCheckID
    let state: OnboardingCheckState
    let detail: String
    let action: OnboardingAction?
}

enum OnboardingAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

protocol OnboardingPermissionProviding: Sendable {
    func status(for permission: OnboardingPermission) async -> OnboardingAuthorizationStatus
    func request(_ permission: OnboardingPermission) async -> OnboardingAuthorizationStatus
}

struct SystemOnboardingPermissionProvider: OnboardingPermissionProviding {
    func status(for permission: OnboardingPermission) async -> OnboardingAuthorizationStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: .notDetermined
            case .authorized: .authorized
            case .denied: .denied
            case .restricted: .unavailable
            @unknown default: .unavailable
            }
        case .systemAudio:
            CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
        case .accessibility:
            AXIsProcessTrusted() ? .authorized : .notDetermined
        }
    }

    func request(_ permission: OnboardingPermission) async -> OnboardingAuthorizationStatus {
        switch permission {
        case .microphone:
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            return allowed ? .authorized : .denied
        case .systemAudio:
            return CGRequestScreenCaptureAccess() ? .authorized : .denied
        case .accessibility:
            // The exported CFString global is not concurrency-annotated in the
            // SDK. This is its documented stable key value.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
        }
    }
}

struct OnboardingVoxTypeInspection: Equatable, Sendable {
    let executableURL: URL?
    let version: VoxTypeVersion?
    let status: VoxTypeStatus
    let hotkeyConfiguration: VoxTypeHotkeyConfiguration?
}

protocol OnboardingVoxTypeInspecting: Sendable {
    func inspect() async -> OnboardingVoxTypeInspection
}

struct SystemOnboardingVoxTypeInspector: OnboardingVoxTypeInspecting {
    func inspect() async -> OnboardingVoxTypeInspection {
        guard let client = try? VoxTypeClient.discover() else {
            return OnboardingVoxTypeInspection(
                executableURL: nil,
                version: nil,
                status: .unavailable(.launchFailed),
                hotkeyConfiguration: nil
            )
        }
        return OnboardingVoxTypeInspection(
            executableURL: client.executableURL,
            version: try? await client.version(),
            status: await client.status(),
            hotkeyConfiguration: try? await client.hotkeyConfiguration()
        )
    }
}

protocol OnboardingModelManaging: Sendable {
    func refresh() async -> ModelInventorySnapshot
}

struct SystemOnboardingModelManager: OnboardingModelManaging {
    func refresh() async -> ModelInventorySnapshot {
        guard let client = try? VoxTypeClient.discover() else { return .unknown }
        return await ModelInventory(client: client).refresh()
    }

}

@MainActor
protocol OnboardingURLOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct SystemOnboardingURLOpener: OnboardingURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
@Observable
final class OnboardingController {
    static let schemaVersion = 1
    static let schemaVersionKey = "BrainMenu.onboarding.schemaVersion"
    static let completionDateKey = "BrainMenu.onboarding.completionDate"
    static let voxTypeInstallationURL = URL(string: "https://voxtype.io/docs/")!
    static let minimumVoxTypeVersion = VoxTypeVersion(
        major: 0,
        minor: 7,
        patch: 0,
        prerelease: nil
    )
    static let defaultDictationModelID = SpeechEngineCatalog.englishDefaultModelID
    static let defaultMeetingModelID = SpeechEngineCatalog.englishDefaultModelID
    static let requiredCheckIDs: Set<OnboardingCheckID> = [
        .voxTypeExecutable,
        .voxTypeVersion,
        .voxTypeDaemon,
        .microphone,
        .systemAudio,
        .accessibility,
    ]

    private(set) var checks: [OnboardingCheck]
    private(set) var isComplete = false
    private(set) var completionDate: Date?
    private(set) var isWorking = false

    @ObservationIgnored private let voxType: any OnboardingVoxTypeInspecting
    @ObservationIgnored private let models: any OnboardingModelManaging
    @ObservationIgnored private let permissions: any OnboardingPermissionProviding
    @ObservationIgnored private let opener: any OnboardingURLOpening
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let minimumVersion: VoxTypeVersion
    @ObservationIgnored private let dictationModelID: String
    @ObservationIgnored private let meetingModelID: String
    @ObservationIgnored private var deniedDuringSession = Set<OnboardingPermission>()

    init(
        voxType: any OnboardingVoxTypeInspecting = SystemOnboardingVoxTypeInspector(),
        models: any OnboardingModelManaging = SystemOnboardingModelManager(),
        permissions: any OnboardingPermissionProviding = SystemOnboardingPermissionProvider(),
        opener: any OnboardingURLOpening = SystemOnboardingURLOpener(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumVersion: VoxTypeVersion = OnboardingController.minimumVoxTypeVersion,
        dictationModelID: String = OnboardingController.defaultDictationModelID,
        meetingModelID: String = OnboardingController.defaultMeetingModelID
    ) {
        self.voxType = voxType
        self.models = models
        self.permissions = permissions
        self.opener = opener
        self.defaults = defaults
        self.now = now
        self.minimumVersion = minimumVersion
        self.dictationModelID = Self.catalogModelID(
            dictationModelID,
            fallback: Self.defaultDictationModelID
        )
        self.meetingModelID = Self.catalogModelID(
            meetingModelID,
            fallback: Self.defaultMeetingModelID
        )
        checks = Self.checkingChecks

        if defaults.integer(forKey: Self.schemaVersionKey) == Self.schemaVersion {
            completionDate = defaults.object(forKey: Self.completionDateKey) as? Date
        }
    }

    var firstIncompleteCheck: OnboardingCheck? {
        checks.first { Self.requiredCheckIDs.contains($0.id) && $0.state != .ready }
    }

    func check(_ id: OnboardingCheckID) -> OnboardingCheck {
        checks.first { $0.id == id }
            ?? OnboardingCheck(id: id, state: .checking, detail: "Checking…", action: nil)
    }

    func canPerform(_ action: OnboardingAction) -> Bool {
        guard !isWorking, checks.contains(where: { $0.action == action }) else {
            return false
        }
        return true
    }

    /// Re-evaluates all mutable prerequisites. This never requests a permission
    /// and never trusts a previously persisted completion marker as current health.
    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        checks = Self.checkingChecks
        defer { isWorking = false }

        let inspection = await voxType.inspect()
        let inventory = await models.refresh()
        let microphone = await effectivePermissionStatus(.microphone)
        let systemAudio = await effectivePermissionStatus(.systemAudio)
        let accessibility = await effectivePermissionStatus(.accessibility)

        var refreshed: [OnboardingCheck] = []
        refreshed.append(executableCheck(inspection.executableURL))
        refreshed.append(versionCheck(inspection))
        refreshed.append(daemonCheck(inspection))
        refreshed.append(hotkeyCheck(inspection))
        refreshed.append(modelCheck(
            id: .dictationModel,
            workflow: .dictation,
            modelID: dictationModelID,
            inventory: inventory
        ))
        refreshed.append(modelCheck(
            id: .meetingModel,
            workflow: .meetings,
            modelID: meetingModelID,
            inventory: inventory
        ))
        refreshed.append(permissionCheck(
            id: .microphone,
            permission: .microphone,
            status: microphone
        ))
        refreshed.append(permissionCheck(
            id: .systemAudio,
            permission: .systemAudio,
            status: systemAudio
        ))
        refreshed.append(permissionCheck(
            id: .accessibility,
            permission: .accessibility,
            status: accessibility
        ))

        checks = refreshed
        updateCompletion()
    }

    /// Executes only the exact action currently presented by one check. Calling
    /// this with a stale or invented action is a no-op, which keeps model IDs
    /// catalog-bound and permission prompts tied to visible user buttons.
    func perform(_ action: OnboardingAction) async {
        guard checks.contains(where: { $0.action == action }) else { return }

        guard !isWorking else { return }
        if action == .recheck {
            await refresh()
            return
        }

        isWorking = true
        defer { isWorking = false }
        switch action {
        case .installVoxType, .openVoxTypeGuide:
            _ = opener.open(Self.voxTypeInstallationURL)
        case .recheck:
            break
        case .requestPermission(let permission):
            let result = await permissions.request(permission)
            recordExplicitPermissionResult(result, for: permission)
            replaceCheck(permissionCheck(
                id: Self.checkID(for: permission),
                permission: permission,
                status: result
            ))
        case .openSystemSettings(let permission):
            _ = opener.open(permission.systemSettingsURL)
        }

        updateCompletion()
    }

    private static var checkingChecks: [OnboardingCheck] {
        OnboardingCheckID.allCases.map {
            OnboardingCheck(id: $0, state: .checking, detail: "Checking…", action: nil)
        }
    }

    private static func catalogModelID(_ requested: String, fallback: String) -> String {
        SpeechEngineCatalog.model(id: requested) == nil ? fallback : requested
    }

    private static func checkID(for permission: OnboardingPermission) -> OnboardingCheckID {
        switch permission {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        case .accessibility: .accessibility
        }
    }

    private func executableCheck(_ executableURL: URL?) -> OnboardingCheck {
        guard let executableURL else {
            return OnboardingCheck(
                id: .voxTypeExecutable,
                state: .actionNeeded,
                detail: "Install VoxType from its official installation guide.",
                action: .installVoxType
            )
        }
        return OnboardingCheck(
            id: .voxTypeExecutable,
            state: .ready,
            detail: "Found \(executableURL.path).",
            action: nil
        )
    }

    private func versionCheck(_ inspection: OnboardingVoxTypeInspection) -> OnboardingCheck {
        guard inspection.executableURL != nil else {
            return unavailable(.voxTypeVersion, "Install VoxType before checking its version.")
        }
        guard let version = inspection.version else {
            return unavailable(.voxTypeVersion, "VoxType did not report a valid version.")
        }
        guard version >= minimumVersion else {
            return OnboardingCheck(
                id: .voxTypeVersion,
                state: .actionNeeded,
                detail: "VoxType \(version) is older than required \(minimumVersion).",
                action: .installVoxType
            )
        }
        return OnboardingCheck(
            id: .voxTypeVersion,
            state: .ready,
            detail: "VoxType \(version) is compatible.",
            action: nil
        )
    }

    private func daemonCheck(_ inspection: OnboardingVoxTypeInspection) -> OnboardingCheck {
        guard inspection.executableURL != nil else {
            return unavailable(.voxTypeDaemon, "Install VoxType before checking its daemon.")
        }
        guard case .available(let snapshot) = inspection.status,
              snapshot.daemonIsRunning else {
            return OnboardingCheck(
                id: .voxTypeDaemon,
                state: .actionNeeded,
                detail: "Start VoxType, then check again.",
                action: .recheck
            )
        }
        return OnboardingCheck(
            id: .voxTypeDaemon,
            state: .ready,
            detail: "The VoxType daemon is running.",
            action: nil
        )
    }

    private func hotkeyCheck(_ inspection: OnboardingVoxTypeInspection) -> OnboardingCheck {
        let detail: String
        if let hotkey = inspection.hotkeyConfiguration {
            detail = "VoxType owns \(hotkey.shortcutDescription). Brain will not change it."
        } else {
            detail = "VoxType keeps ownership of its shortcut. Brain will not change it."
        }
        return OnboardingCheck(
            id: .voxTypeHotkey,
            state: .ready,
            detail: detail,
            action: nil
        )
    }

    private func replaceCheck(_ replacement: OnboardingCheck) {
        guard let index = checks.firstIndex(where: { $0.id == replacement.id }) else {
            return
        }
        checks[index] = replacement
    }

    private func modelCheck(
        id: OnboardingCheckID,
        workflow: SpeechWorkflow,
        modelID: String,
        inventory: ModelInventorySnapshot
    ) -> OnboardingCheck {
        let modelName = SpeechEngineCatalog.model(id: modelID)?.displayName ?? modelID
        switch inventory.availability(for: modelID) {
        case .ready:
            return OnboardingCheck(
                id: id,
                state: .ready,
                detail: "\(modelName) is ready.",
                action: nil
            )
        case .missing:
            return OnboardingCheck(
                id: id,
                state: .optional,
                detail: "Configure \(modelName) in VoxType, then check again. Brain will not install or activate VoxType models.",
                action: .openVoxTypeGuide
            )
        case .incompatible:
            return OnboardingCheck(
                id: id,
                state: .optional,
                detail: "Replace \(modelName) in VoxType, then check again. Brain will not install or activate VoxType models.",
                action: .openVoxTypeGuide
            )
        case .installing:
            return OnboardingCheck(
                id: id,
                state: .installing,
                detail: "Installing \(modelName)…",
                action: nil
            )
        case .unknown:
            return OnboardingCheck(
                id: id,
                state: .optional,
                detail: "VoxType could not report \(modelName) readiness. Manage models in VoxType.",
                action: .openVoxTypeGuide
            )
        }
    }

    private func permissionCheck(
        id: OnboardingCheckID,
        permission: OnboardingPermission,
        status: OnboardingAuthorizationStatus
    ) -> OnboardingCheck {
        let purpose = permission == .accessibility
            ? "selected-text context and paste-related features"
            : nil
        switch status {
        case .authorized:
            return OnboardingCheck(
                id: id,
                state: .ready,
                detail: purpose.map { "Brain can use \($0)." } ?? "Brain is authorized.",
                action: nil
            )
        case .notDetermined:
            return OnboardingCheck(
                id: id,
                state: .actionNeeded,
                detail: purpose.map {
                    "Allow Accessibility only for \($0)."
                } ?? "Brain will ask only when you choose to allow access.",
                action: .requestPermission(permission)
            )
        case .denied:
            return OnboardingCheck(
                id: id,
                state: .denied,
                detail: "Allow Brain in Privacy & Security in System Settings.",
                action: .openSystemSettings(permission)
            )
        case .unavailable:
            return OnboardingCheck(
                id: id,
                state: .unavailable,
                detail: "This permission is unavailable on this Mac.",
                action: .openSystemSettings(permission)
            )
        }
    }

    private func unavailable(_ id: OnboardingCheckID, _ detail: String) -> OnboardingCheck {
        OnboardingCheck(id: id, state: .unavailable, detail: detail, action: .recheck)
    }

    private func effectivePermissionStatus(
        _ permission: OnboardingPermission
    ) async -> OnboardingAuthorizationStatus {
        let current = await permissions.status(for: permission)
        if current == .authorized {
            deniedDuringSession.remove(permission)
            return .authorized
        }
        if current == .notDetermined, deniedDuringSession.contains(permission) {
            return .denied
        }
        return current
    }

    private func recordExplicitPermissionResult(
        _ result: OnboardingAuthorizationStatus,
        for permission: OnboardingPermission
    ) {
        if result == .denied {
            deniedDuringSession.insert(permission)
        } else if result == .authorized {
            deniedDuringSession.remove(permission)
        }
    }

    private func updateCompletion() {
        isComplete = checks.allSatisfy {
            !Self.requiredCheckIDs.contains($0.id) || $0.state == .ready
        }
        if isComplete {
            if defaults.integer(forKey: Self.schemaVersionKey) == Self.schemaVersion,
               let existing = defaults.object(forKey: Self.completionDateKey) as? Date {
                completionDate = existing
            } else {
                let completedAt = now()
                defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
                defaults.set(completedAt, forKey: Self.completionDateKey)
                completionDate = completedAt
            }
        } else {
            defaults.removeObject(forKey: Self.schemaVersionKey)
            defaults.removeObject(forKey: Self.completionDateKey)
            completionDate = nil
        }
    }
}
