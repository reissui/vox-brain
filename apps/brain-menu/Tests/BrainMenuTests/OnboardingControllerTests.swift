import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct OnboardingControllerTests {
    @Test
    func checksStayInRequiredOrderAndExposeOneExactAction() async throws {
        let fixture = try OnboardingFixture()
        await fixture.permissions.set(.notDetermined, for: .microphone)
        await fixture.permissions.set(.denied, for: .systemAudio)
        await fixture.permissions.set(.unavailable, for: .accessibility)

        await fixture.controller.refresh()

        #expect(fixture.controller.checks.map(\.id) == OnboardingCheckID.allCases)
        #expect(fixture.controller.check(.microphone).state == .actionNeeded)
        #expect(fixture.controller.check(.microphone).action == .requestPermission(.microphone))
        #expect(fixture.controller.check(.systemAudio).state == .denied)
        #expect(
            fixture.controller.check(.systemAudio).action == .openSystemSettings(.systemAudio)
        )
        #expect(fixture.controller.check(.accessibility).state == .unavailable)
        #expect(fixture.controller.check(.accessibility).action != nil)
        #expect(fixture.controller.checks.allSatisfy { check in
            check.state == .ready ? check.action == nil : check.action != nil
        })
    }

    @Test
    func refreshNeverPromptsAndExplicitButtonsRequestOnlyMatchingPermissions() async throws {
        let fixture = try OnboardingFixture()
        await fixture.permissions.set(.notDetermined, for: .microphone)
        await fixture.permissions.set(.notDetermined, for: .systemAudio)
        await fixture.permissions.set(.authorized, for: .accessibility)

        await fixture.controller.refresh()
        await fixture.controller.refresh()
        #expect(await fixture.permissions.requests == [])

        await fixture.permissions.queue(.authorized, for: .microphone)
        await fixture.controller.perform(.requestPermission(.microphone))
        #expect(await fixture.permissions.requests == [.microphone])
        #expect(fixture.controller.check(.microphone).state == .ready)
        #expect(fixture.controller.check(.systemAudio).state == .actionNeeded)
    }

    @Test
    func denialUsesCorrectDeepLinkAndNeverLoopsThePrompt() async throws {
        let fixture = try OnboardingFixture()
        await fixture.permissions.set(.notDetermined, for: .microphone)
        await fixture.permissions.queue(.denied, for: .microphone)
        await fixture.controller.refresh()

        await fixture.controller.perform(.requestPermission(.microphone))
        #expect(fixture.controller.check(.microphone).state == .denied)
        #expect(
            fixture.controller.check(.microphone).action == .openSystemSettings(.microphone)
        )
        #expect(await fixture.permissions.requests == [.microphone])

        await fixture.controller.perform(.openSystemSettings(.microphone))
        await fixture.controller.refresh()
        #expect(await fixture.permissions.requests == [.microphone])
        #expect(fixture.opener.urls == [OnboardingPermission.microphone.systemSettingsURL])
    }

    @Test
    func checkAgainRechecksMutableHealthWithoutCausingAnAction() async throws {
        let fixture = try OnboardingFixture()
        await fixture.voxType.setStatus(.unavailable(.daemonNotRunning))
        await fixture.controller.refresh()
        #expect(fixture.controller.check(.voxTypeDaemon).action == .recheck)

        await fixture.voxType.setStatus(Self.runningStatus)
        await fixture.controller.perform(.recheck)

        #expect(await fixture.voxType.inspectionCalls == 2)
        #expect(fixture.controller.check(.voxTypeDaemon).state == .ready)
        #expect(await fixture.permissions.requests == [])
        #expect(fixture.opener.urls == [])
        #expect(await fixture.models.installs == [])
    }

    @Test
    func installActionOpensOfficialPageAndSourceDoesNotBundleVoxType() async throws {
        let fixture = try OnboardingFixture(executableURL: nil)
        await fixture.controller.refresh()

        await fixture.controller.perform(.installVoxType)

        #expect(fixture.opener.urls == [OnboardingController.voxTypeInstallationURL])
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("OnboardingController.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("voxtype-tray"))
        #expect(!source.contains("URLSession"))
        #expect(!source.contains("downloadTask"))
    }

    @Test
    func readsVoxTypeShortcutAndSendsModelManagementBackToVoxType() async throws {
        let fixture = try OnboardingFixture(readyModels: [])
        await fixture.controller.refresh()

        #expect(fixture.controller.check(.voxTypeHotkey).state == .ready)
        #expect(fixture.controller.check(.voxTypeHotkey).detail.contains("Fn (push-to-talk)"))
        #expect(fixture.controller.check(.voxTypeHotkey).detail.contains("will not change"))

        #expect(fixture.controller.check(.dictationModel).action == .openVoxTypeGuide)
        #expect(fixture.controller.check(.meetingModel).action == .openVoxTypeGuide)
        #expect(fixture.controller.check(.dictationModel).state == .optional)
        #expect(fixture.controller.check(.meetingModel).state == .optional)

        await fixture.controller.perform(.openVoxTypeGuide)
        #expect(fixture.opener.urls == [OnboardingController.voxTypeInstallationURL])
        #expect(await fixture.models.installs.isEmpty)

        #expect(await fixture.models.installs.isEmpty)
    }

    @Test
    func missingModelsNeverStartInstallationInsideBrain() async throws {
        let fixture = try OnboardingFixture(readyModels: [])
        await fixture.permissions.set(.notDetermined, for: .microphone)
        await fixture.controller.refresh()

        let microphone = try #require(fixture.controller.check(.microphone).action)
        #expect(fixture.controller.check(.dictationModel).action == .openVoxTypeGuide)
        #expect(fixture.controller.check(.meetingModel).action == .openVoxTypeGuide)
        #expect(fixture.controller.canPerform(microphone))
        #expect(await fixture.models.installs.isEmpty)
    }

    @Test
    func unreadableHotkeyConfigDoesNotBlockOrOfferMutation() async throws {
        let unreadable = try OnboardingFixture(hotkeyConfiguration: nil)
        await unreadable.controller.refresh()

        #expect(unreadable.controller.check(.voxTypeHotkey).state == .ready)
        #expect(unreadable.controller.check(.voxTypeHotkey).action == nil)
        #expect(unreadable.controller.isComplete)
    }

    @Test
    func completionPersistsOnlySchemaAndDateButMutableHealthAlwaysRechecks() async throws {
        let completedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let fixture = try OnboardingFixture(now: { completedAt })

        await fixture.controller.refresh()

        #expect(fixture.controller.isComplete)
        #expect(fixture.controller.completionDate == completedAt)
        #expect(
            fixture.defaults.integer(forKey: OnboardingController.schemaVersionKey)
                == OnboardingController.schemaVersion
        )
        #expect(
            fixture.defaults.object(forKey: OnboardingController.completionDateKey) as? Date
                == completedAt
        )
        let onboardingKeys = fixture.defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("BrainMenu.onboarding.")
        }
        #expect(Set(onboardingKeys) == [
            OnboardingController.schemaVersionKey,
            OnboardingController.completionDateKey,
        ])

        let resumed = fixture.makeController(now: { Date.distantFuture })
        await fixture.permissions.set(.denied, for: .microphone)
        await resumed.refresh()

        #expect(await fixture.voxType.inspectionCalls == 2)
        #expect(await fixture.models.refreshCalls >= 2)
        #expect(!resumed.isComplete)
        #expect(resumed.completionDate == nil)
        #expect(fixture.defaults.object(forKey: OnboardingController.schemaVersionKey) == nil)
        #expect(fixture.defaults.object(forKey: OnboardingController.completionDateKey) == nil)
    }

    @Test
    func completionIgnoresOptionalMeetingModelButInvalidatesForRequiredHealth() async throws {
        let fixture = try OnboardingFixture()
        await fixture.controller.refresh()
        #expect(fixture.controller.isComplete)

        await fixture.voxType.setStatus(.unavailable(.daemonNotRunning))
        await fixture.controller.refresh()
        #expect(!fixture.controller.isComplete)
        #expect(fixture.controller.check(.voxTypeDaemon).state == .actionNeeded)
        #expect(fixture.defaults.object(forKey: OnboardingController.completionDateKey) == nil)

        await fixture.voxType.setStatus(Self.runningStatus)
        await fixture.models.set(.missing, id: SpeechEngineCatalog.multilingualFallbackModelID)
        let optionalMeeting = fixture.makeController(
            now: Date.init,
            meetingModelID: SpeechEngineCatalog.multilingualFallbackModelID
        )
        await optionalMeeting.refresh()
        #expect(optionalMeeting.isComplete)
        #expect(optionalMeeting.check(.meetingModel).state == .optional)

        await fixture.models.set(.missing, id: OnboardingController.defaultDictationModelID)
        await optionalMeeting.refresh()
        #expect(optionalMeeting.isComplete)
        #expect(optionalMeeting.check(.dictationModel).state == .optional)
        #expect(optionalMeeting.check(.dictationModel).action == .openVoxTypeGuide)
    }

    @Test
    func accessibilityIsRequestedAloneAndInputMonitoringIsAbsent() async throws {
        let fixture = try OnboardingFixture()
        await fixture.permissions.set(.notDetermined, for: .accessibility)
        await fixture.permissions.queue(.denied, for: .accessibility)
        await fixture.controller.refresh()

        await fixture.controller.perform(.requestPermission(.accessibility))

        #expect(await fixture.permissions.requests == [.accessibility])
        #expect(fixture.controller.check(.accessibility).state == .denied)
        #expect(
            fixture.controller.check(.accessibility).action
                == .openSystemSettings(.accessibility)
        )

        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("OnboardingController.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("ListenEvent"))
        #expect(!source.contains("Input Monitoring"))
    }

    fileprivate static let runningStatus = VoxTypeStatus.available(
        VoxTypeStatusSnapshot(state: .idle, model: nil, device: nil, backend: nil)
    )

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Onboarding", isDirectory: true)
    }
}

@MainActor
private final class OnboardingFixture {
    let defaults: UserDefaults
    let voxType: FakeOnboardingVoxType
    let models: FakeOnboardingModels
    let permissions: FakeOnboardingPermissions
    let opener = FakeOnboardingOpener()
    private let suiteName: String
    private let clock: @Sendable () -> Date

    lazy var controller = makeController(now: clock)

    init(
        executableURL: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/voxtype"),
        hotkeyConfiguration: VoxTypeHotkeyConfiguration? = VoxTypeHotkeyConfiguration(
            key: "FN",
            modifiers: [],
            mode: "PushToTalk"
        ),
        readyModels: Set<String> = [
            OnboardingController.defaultDictationModelID,
            OnboardingController.defaultMeetingModelID,
        ],
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        suiteName = "OnboardingControllerTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        clock = now
        voxType = FakeOnboardingVoxType(
            inspection: OnboardingVoxTypeInspection(
                executableURL: executableURL,
                version: executableURL == nil ? nil : VoxTypeVersion(
                    major: 0,
                    minor: 7,
                    patch: 5,
                    prerelease: nil
                ),
                status: executableURL == nil
                    ? .unavailable(.launchFailed)
                    : OnboardingControllerTests.runningStatus,
                hotkeyConfiguration: executableURL == nil ? nil : hotkeyConfiguration
            )
        )
        models = FakeOnboardingModels(ready: readyModels)
        permissions = FakeOnboardingPermissions()
    }

    func makeController(
        now: @escaping @Sendable () -> Date,
        dictationModelID: String = OnboardingController.defaultDictationModelID,
        meetingModelID: String = OnboardingController.defaultMeetingModelID
    ) -> OnboardingController {
        OnboardingController(
            voxType: voxType,
            models: models,
            permissions: permissions,
            opener: opener,
            defaults: defaults,
            now: now,
            dictationModelID: dictationModelID,
            meetingModelID: meetingModelID
        )
    }
}

private actor FakeOnboardingVoxType: OnboardingVoxTypeInspecting {
    private var inspection: OnboardingVoxTypeInspection
    private(set) var inspectionCalls = 0

    init(inspection: OnboardingVoxTypeInspection) {
        self.inspection = inspection
    }

    func inspect() -> OnboardingVoxTypeInspection {
        inspectionCalls += 1
        return inspection
    }

    func setStatus(_ status: VoxTypeStatus) {
        inspection = OnboardingVoxTypeInspection(
            executableURL: inspection.executableURL,
            version: inspection.version,
            status: status,
            hotkeyConfiguration: inspection.hotkeyConfiguration
        )
    }
}

private actor FakeOnboardingModels: OnboardingModelManaging {
    private var snapshot: ModelInventorySnapshot
    private(set) var refreshCalls = 0
    private(set) var installs: [String] = []
    private var shouldBlockNextInstall = false
    private var installContinuation: CheckedContinuation<Void, Never>?
    private var installStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(ready: Set<String>) {
        snapshot = ModelInventorySnapshot(availabilityByModelID: Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map {
                ($0.id, ready.contains($0.id) ? .ready : .missing)
            }
        ))
    }

    func refresh() -> ModelInventorySnapshot {
        refreshCalls += 1
        return snapshot
    }

    func installCatalogModel(id: String) async throws -> ModelInventorySnapshot {
        guard SpeechEngineCatalog.model(id: id) != nil else {
            throw ModelInventoryError.unknownModel
        }
        installs.append(id)
        installStartWaiters.forEach { $0.resume() }
        installStartWaiters.removeAll()
        if shouldBlockNextInstall {
            await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
        }
        snapshot = snapshot.replacing(.ready, for: id)
        return snapshot
    }

    func blockNextInstall() {
        shouldBlockNextInstall = true
    }

    func waitForInstallToStart() async {
        guard installs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            installStartWaiters.append(continuation)
        }
    }

    func finishBlockedInstall() {
        shouldBlockNextInstall = false
        installContinuation?.resume()
        installContinuation = nil
    }

    func set(_ availability: ModelAvailability, id: String) {
        snapshot = snapshot.replacing(availability, for: id)
    }
}

private actor FakeOnboardingPermissions: OnboardingPermissionProviding {
    private var statuses = Dictionary(
        uniqueKeysWithValues: OnboardingPermission.allCases.map {
            ($0, OnboardingAuthorizationStatus.authorized)
        }
    )
    private var queued: [OnboardingPermission: [OnboardingAuthorizationStatus]] = [:]
    private(set) var requests: [OnboardingPermission] = []

    func status(for permission: OnboardingPermission) -> OnboardingAuthorizationStatus {
        statuses[permission] ?? .unavailable
    }

    func request(_ permission: OnboardingPermission) -> OnboardingAuthorizationStatus {
        requests.append(permission)
        let result = queued[permission]?.isEmpty == false
            ? queued[permission]!.removeFirst()
            : statuses[permission] ?? .unavailable
        statuses[permission] = result
        return result
    }

    func set(_ status: OnboardingAuthorizationStatus, for permission: OnboardingPermission) {
        statuses[permission] = status
    }

    func queue(_ status: OnboardingAuthorizationStatus, for permission: OnboardingPermission) {
        queued[permission, default: []].append(status)
    }
}

@MainActor
private final class FakeOnboardingOpener: OnboardingURLOpening, @unchecked Sendable {
    private(set) var urls: [URL] = []

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return true
    }
}
