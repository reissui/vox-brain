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
            ])
        )

        await controller.checkNow()

        #expect(controller.state == .available(release))
        #expect(defaults.object(forKey: UpdateController.lastCheckDefaultsKey) as? Date == checkedAt)
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
