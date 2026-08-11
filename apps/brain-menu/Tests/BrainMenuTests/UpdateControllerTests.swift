import Foundation
import Testing
@testable import BrainMenu

struct UpdateControllerTests {
    @Test
    func semanticVersionsCompareByEachNumericComponent() throws {
        #expect(try #require(BrainSemanticVersion("1.2.3")) < #require(BrainSemanticVersion("1.2.4")))
        #expect(try #require(BrainSemanticVersion("1.9.9")) < #require(BrainSemanticVersion("2.0.0")))
        #expect(BrainSemanticVersion("1.2") == nil)
        #expect(BrainSemanticVersion("brain-v1.2.3") == nil)
    }

    @MainActor
    @Test
    func manualCheckFindsNewerReleaseAndPersistsCheckTime() async throws {
        let suite = "UpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checkedAt = Date(timeIntervalSince1970: 1_784_630_400)
        let release = BrainRelease(
            version: "1.3.0",
            pageURL: try #require(URL(string: "https://github.com/reissui/vox-brain/releases/tag/brain-v1.3.0")),
            archiveURL: try #require(URL(string: "https://github.com/reissui/vox-brain/releases/download/brain-v1.3.0/Brain-1.3.0.zip")),
            archiveSize: 42
        )
        let alertPresenter = RecordingUpdateAlertPresenter()
        let controller = UpdateController(
            service: FakeUpdateService(release: release),
            defaults: defaults,
            now: { checkedAt },
            buildInfo: BrainBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "123",
                "BrainSourceSHA": String(repeating: "a", count: 40),
                "BrainChannel": "release",
                "BrainBuildDate": "2026-07-24T12:00:00Z",
            ]),
            alertPresenter: alertPresenter
        )

        await controller.checkNow()

        #expect(controller.state == .available(release))
        #expect(controller.sidebarAlert == BrainUpdateSidebarAlert(
            title: "Update available",
            detail: "Brain 1.3.0"
        ))
        #expect(defaults.object(forKey: UpdateController.lastCheckDefaultsKey) as? Date == checkedAt)
        #expect(alertPresenter.presentedReleases == [release])
    }

    @MainActor
    @Test
    func repeatedChecksAlertOnlyOnceForTheSameRelease() async throws {
        let release = BrainRelease(
            version: "1.3.0",
            pageURL: try #require(URL(string: "https://example.test/brain-v1.3.0")),
            archiveURL: try #require(URL(string: "https://example.test/Brain-1.3.0.zip")),
            archiveSize: 42
        )
        let alertPresenter = RecordingUpdateAlertPresenter()
        let controller = UpdateController(
            service: FakeUpdateService(release: release),
            buildInfo: BrainBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "123",
                "BrainSourceSHA": String(repeating: "a", count: 40),
                "BrainChannel": "release",
                "BrainBuildDate": "2026-07-24T12:00:00Z",
            ]),
            alertPresenter: alertPresenter
        )

        await controller.checkNow()
        await controller.checkNow()

        #expect(alertPresenter.presentedReleases == [release])
        #expect(alertPresenter.installAction != nil)
    }

    @MainActor
    @Test
    func missingFirstReleaseIsAnUnavailableStateRatherThanAConnectionFailure() async {
        let controller = UpdateController(
            service: NoReleaseUpdateService(),
            defaults: UserDefaults.standard,
            buildInfo: BrainBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "123",
                "BrainSourceSHA": String(repeating: "a", count: 40),
                "BrainChannel": "release",
                "BrainBuildDate": "2026-07-24T12:00:00Z",
            ])
        )

        await controller.checkNow()

        #expect(controller.state == .unavailable("No Brain releases have been published yet."))
    }

    @MainActor
    @Test
    func automaticChecksContinueWhileTheAppRemainsOpen() async throws {
        let suite = "UpdateControllerTests.Automatic.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = BrainRelease(
            version: "1.2.3",
            pageURL: try #require(URL(string: "https://example.test/brain-v1.2.3")),
            archiveURL: try #require(URL(string: "https://example.test/Brain-1.2.3.zip")),
            archiveSize: 42
        )
        let service = CountingUpdateService(release: release)
        let sleeper = RecurringUpdateSleeper()
        let controller = UpdateController(
            service: service,
            defaults: defaults,
            sleep: { duration in
                try await sleeper.sleep(duration)
            },
            buildInfo: BrainBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "123",
                "BrainSourceSHA": String(repeating: "a", count: 40),
                "BrainChannel": "release",
                "BrainBuildDate": "2026-07-24T12:00:00Z",
            ])
        )

        controller.start()
        for _ in 0..<500 {
            if await service.checkCount >= 2, await sleeper.durations.count >= 2 {
                break
            }
            await Task.yield()
        }
        controller.stop()

        #expect(await service.checkCount == 2)
        #expect(await sleeper.durations == [
            .seconds(UpdateController.automaticCheckInterval),
            .seconds(UpdateController.automaticCheckInterval),
        ])
    }
}

private actor FakeUpdateService: BrainUpdateServing {
    let release: BrainRelease

    init(release: BrainRelease) {
        self.release = release
    }

    func latestRelease() async throws -> BrainRelease { release }

    func prepareInstallation(for release: BrainRelease) async throws -> BrainPreparedUpdate {
        throw BrainUpdateError.invalidApplication
    }
}

private actor NoReleaseUpdateService: BrainUpdateServing {
    func latestRelease() async throws -> BrainRelease {
        throw BrainUpdateError.noReleasePublished
    }

    func prepareInstallation(for release: BrainRelease) async throws -> BrainPreparedUpdate {
        throw BrainUpdateError.noReleasePublished
    }
}

private actor CountingUpdateService: BrainUpdateServing {
    let release: BrainRelease
    private(set) var checkCount = 0

    init(release: BrainRelease) {
        self.release = release
    }

    func latestRelease() async throws -> BrainRelease {
        checkCount += 1
        return release
    }

    func prepareInstallation(for release: BrainRelease) async throws -> BrainPreparedUpdate {
        throw BrainUpdateError.invalidApplication
    }
}

private actor RecurringUpdateSleeper {
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if durations.count == 1 { return }
        try await Task.sleep(for: .seconds(3_600))
    }
}

@MainActor
private final class RecordingUpdateAlertPresenter: BrainUpdateAlertPresenting {
    private(set) var presentedReleases: [BrainRelease] = []
    private(set) var installAction: (() -> Void)?

    func presentUpdateAvailable(
        _ release: BrainRelease,
        install: @escaping @MainActor () -> Void
    ) {
        presentedReleases.append(release)
        installAction = install
    }
}
