import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct BrainStoreTests {
    @Test(arguments: [
        BrainOverallState.healthy,
        BrainOverallState.activity,
        BrainOverallState.failure,
    ])
    func manualRefreshPublishesPairedRemoteStates(_ overall: BrainOverallState) async throws {
        let client = StoreAPI(overall: overall)
        let refreshedAt = Date(timeIntervalSince1970: 1_784_112_400)
        let store = BrainStore(client: client, now: { refreshedAt })

        await store.refresh()

        #expect(store.isPaired)
        #expect(store.snapshot?.health.overall == overall)
        #expect(store.snapshot?.refreshedAt == refreshedAt)
        #expect(store.isStale == false)
        #expect(store.errorMessage == nil)
        #expect(await client.requests == [.status, .health])
        #expect(await client.maximumConcurrentRequests == 1)
    }

    @Test
    func unpairedIsNeutralAndMakesNoRemoteRequest() async {
        let client = StoreAPI(paired: false)
        let store = BrainStore(client: client)

        await store.refresh()

        let presentation = BrainPresentation.state(
            for: store.snapshot,
            isPaired: store.isPaired
        )
        #expect(store.snapshot == nil)
        #expect(store.errorMessage == nil)
        #expect(await client.requests.isEmpty)
        #expect(presentation.label == "Not paired")
        #expect(presentation.tone == .neutral)
    }

    @Test
    func overlappingRefreshIsIgnoredAndAPIRequestsRemainSequential() async {
        let client = StoreAPI(delay: .milliseconds(100))
        let store = BrainStore(client: client)

        let first = Task { await store.refresh() }
        while await client.statusCalls == 0 {
            await Task.yield()
        }
        await store.refresh()
        await first.value

        #expect(await client.statusCalls == 1)
        #expect(await client.healthCalls == 1)
        #expect(await client.maximumConcurrentRequests == 1)
    }

    @Test
    func transportFailurePreservesLastSuccessAsStaleWithCurrentError() async throws {
        let client = StoreAPI()
        let lastSuccess = Date(timeIntervalSince1970: 1_784_112_400)
        let store = BrainStore(client: client, now: { lastSuccess })
        await store.refresh()
        let original = try #require(store.snapshot)
        await client.failStatus(with: "remote transport failed")

        await store.refresh()

        #expect(store.snapshot?.status == original.status)
        #expect(store.snapshot?.health == original.health)
        #expect(store.snapshot?.refreshedAt == lastSuccess)
        #expect(store.isStale)
        #expect(store.errorMessage == "remote transport failed")
        #expect(BrainPresentation.state(for: store.snapshot).tone == .warning)
    }

    @Test
    func gatewayStaleResponseUsesHistoricalTimestampAndPublishesOutageError() async throws {
        let snapshotAt = Date(timeIntervalSince1970: 1_784_112_335)
        let freshness = BrainReportFreshness(
            isStale: true,
            snapshotAt: snapshotAt,
            ageSeconds: 65
        )
        let client = StoreAPI(freshness: freshness)
        let store = BrainStore(
            client: client,
            now: { Date(timeIntervalSince1970: 1_784_112_999) }
        )

        await store.refresh()

        #expect(store.snapshot?.status.freshness == freshness)
        #expect(store.snapshot?.health.freshness == freshness)
        #expect(store.snapshot?.refreshedAt == snapshotAt)
        #expect(store.isStale)
        #expect(store.errorMessage == "The remote Brain origin is unavailable. Showing a cached status snapshot.")
        #expect(BrainPresentation.state(for: store.snapshot).tone == .warning)
    }

    @Test
    func startRefreshesOnLaunchAndAtTheConfiguredInterval() async throws {
        let client = StoreAPI()
        let store = BrainStore(client: client, refreshInterval: .milliseconds(20))

        store.start()
        for _ in 0..<100 where await client.healthCalls < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        store.stop()

        #expect(await client.statusCalls >= 2)
        #expect(await client.healthCalls >= 2)
        #expect(await client.maximumConcurrentRequests == 1)
    }

    @Test
    func fakeAPIRecordsOnlyTypedStatusAndHealthAccess() async {
        let client = StoreAPI()
        let store = BrainStore(client: client)

        await store.refresh()

        #expect(await client.requests == [.status, .health])
    }

    @Test
    func opensOnlyTheExactValidatedServerSuppliedPrivateSite() async throws {
        let destination = try #require(URL(string: "https://private.example.test/brain"))
        let opener = StorePrivateSiteOpener()
        let client = StoreAPI(siteURL: destination)
        let store = BrainStore(client: client, privateSiteOpener: opener)

        #expect(store.openPrivateSite() == false)
        await store.refresh()

        #expect(store.privateSiteURL == destination)
        #expect(store.openPrivateSite())
        #expect(opener.openedURLs == [destination])
    }

    @Test
    func statusDecodingToleratesMissingSiteAndRejectsEveryUnsafeDestination() throws {
        let missing = try decodeStatus(siteURL: nil)
        #expect(missing.siteURL == nil)

        let exact = "https://private.example.test/brain"
        #expect(try decodeStatus(siteURL: exact).siteURL?.absoluteString == exact)

        for unsafe in [
            "http://private.example.test",
            "https://user:secret@private.example.test",
            "https://private.example.test?token=secret",
            "https://private.example.test#fragment",
            "https://private.example.test\\@attacker.test",
            "https://private.example.test:99999",
            String(repeating: "x", count: BrainPrivateSiteURL.maximumUTF8Bytes + 1),
        ] {
            #expect(try decodeStatus(siteURL: unsafe).siteURL == nil)
        }

        var wrongType = statusJSONObject()
        wrongType["site_url"] = 42
        let data = try JSONSerialization.data(withJSONObject: wrongType)
        #expect(try JSONDecoder.brainDecoder().decode(BrainStatusReport.self, from: data).siteURL == nil)
    }

    @Test
    func decodesTypedMacMiniQueueAndProgressOperations() throws {
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-07-20T10:00:00Z","overall":"warning","counts":{"pass":2,"activity":0,"warning":1,"failure":0},"checks":[],"operations":{"last_successful_poll":"2026-07-20T09:59:58.000Z","poll_age_seconds":2,"backlog_count":1,"oldest_backlog_age_seconds":95,"process":{"state":"running","label":"capture:safe-id","started_at":"2026-07-20T09:59:00.000Z","progress_age_seconds":60,"declared_bound_seconds":3600},"automation":{"last_progress_at":"2026-07-20T09:30:00Z","progress_age_seconds":1800},"launchd":{"agent":"running","automation":"loaded"}}}
        """.utf8)

        let health = try JSONDecoder.brainDecoder().decode(BrainHealthReport.self, from: data)

        #expect(health.operations?.backlogCount == 1)
        #expect(health.operations?.oldestBacklogAgeSeconds == 95)
        #expect(health.operations?.process.state == "running")
        #expect(health.operations?.process.declaredBoundSeconds == 3_600)
        #expect(health.operations?.launchd.agent == "running")
        #expect(health.operations?.launchd.automation == "loaded")
    }

    @Test
    func decodesGitFreeLastRunAndPrivateSite() throws {
        let data = Data("""
        {"schema_version":1,"generated_at":"2026-07-20T13:50:17Z","vault":{"path":"/tmp/vox-brain-vault","state":"activity","dirty_paths":12},"counts":{"inbox":12,"sources":9,"notes":18,"people":5,"projects":5},"last_run":{"at":"2026-07-20T13:03:30Z","commit":null,"summary":"daily digest (2026-07-20)"},"services":[],"site_url":"https://brain-vault.example.pages.dev"}
        """.utf8)

        let status = try JSONDecoder.brainDecoder().decode(BrainStatusReport.self, from: data)

        #expect(status.lastRun?.commit == nil)
        #expect(status.siteURL?.absoluteString == "https://brain-vault.example.pages.dev")
    }
}

@MainActor
private final class StorePrivateSiteOpener: BrainPrivateSiteOpening, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

private func statusJSONObject() -> [String: Any] {
    [
        "schema_version": 1,
        "generated_at": "2026-07-20T10:00:00Z",
        "vault": ["path": "remote", "state": "clean", "dirty_paths": 0],
        "counts": ["inbox": 0, "sources": 0, "notes": 0, "people": 0, "projects": 0],
        "last_run": NSNull(),
        "services": [],
    ]
}

private func decodeStatus(siteURL: String?) throws -> BrainStatusReport {
    var object = statusJSONObject()
    if let siteURL { object["site_url"] = siteURL }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder.brainDecoder().decode(BrainStatusReport.self, from: data)
}

private enum StoreAPIError: Error, LocalizedError, Sendable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

private enum StoreRequest: Equatable, Sendable {
    case status
    case health
}

private actor StoreAPI: BrainStatusAPI {
    nonisolated let pairedInstance: BrainInstanceMetadata?

    private(set) var requests: [StoreRequest] = []
    private(set) var statusCalls = 0
    private(set) var healthCalls = 0
    private(set) var maximumConcurrentRequests = 0
    private var activeRequests = 0
    private let delay: Duration
    private let overall: BrainOverallState
    private let freshness: BrainReportFreshness
    private let siteURL: URL?
    private var statusFailure: String?

    init(
        paired: Bool = true,
        overall: BrainOverallState = .activity,
        delay: Duration = .zero,
        freshness: BrainReportFreshness = .fresh,
        siteURL: URL? = nil
    ) {
        pairedInstance = paired ? BrainInstanceMetadata(
            baseURL: URL(string: "https://brain.example.test")!,
            instanceID: "brain-test",
            deviceID: "device-test",
            deviceName: "Test Mac",
            scopes: [.read]
        ) : nil
        self.overall = overall
        self.delay = delay
        self.freshness = freshness
        self.siteURL = siteURL
    }

    func status() async throws -> BrainStatusReport {
        statusCalls += 1
        requests.append(.status)
        beginRequest()
        defer { endRequest() }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let statusFailure {
            throw StoreAPIError.failed(statusFailure)
        }
        return makeStatus(freshness: freshness, siteURL: siteURL)
    }

    func health() async throws -> BrainHealthReport {
        healthCalls += 1
        requests.append(.health)
        beginRequest()
        defer { endRequest() }
        return makeHealth(overall: overall, freshness: freshness)
    }

    func failStatus(with message: String) {
        statusFailure = message
    }

    private func beginRequest() {
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    }

    private func endRequest() {
        activeRequests -= 1
    }
}

private func makeStatus(
    freshness: BrainReportFreshness = .fresh,
    siteURL: URL? = nil
) -> BrainStatusReport {
    let generatedAt = Date(timeIntervalSince1970: 1_784_112_390)
    return BrainStatusReport(
        schemaVersion: 1,
        generatedAt: generatedAt,
        vault: BrainVaultStatus(path: "remote", state: .clean, dirtyPaths: 0),
        counts: BrainContentCounts(inbox: 1, sources: 42, notes: 17, people: 8, projects: 5),
        lastRun: BrainLastRun(at: generatedAt, commit: "0123456789", summary: "processed"),
        services: [],
        siteURL: siteURL,
        freshness: freshness
    )
}

private func makeHealth(
    overall: BrainOverallState,
    freshness: BrainReportFreshness = .fresh
) -> BrainHealthReport {
    BrainHealthReport(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 1_784_112_391),
        overall: overall,
        counts: BrainHealthCounts(
            pass: overall == .healthy ? 1 : 0,
            activity: overall == .activity ? 1 : 0,
            warning: overall == .warning ? 1 : 0,
            failure: overall == .failure ? 1 : 0
        ),
        checks: [
            BrainHealthCheck(
                id: "agent.heartbeat",
                scope: "mac_mini_agent",
                state: overall == .healthy ? .pass : BrainCheckState(rawValue: overall.rawValue) ?? .pass,
                summary: "Remote agent",
                detail: "Reported by the paired instance.",
                remediation: nil
            ),
        ],
        freshness: freshness
    )
}

extension DashboardScope {
    static let thisMac = DashboardScope.remoteVault
    static let macMini = DashboardScope.macMiniAgent
    static let cloud = DashboardScope.gateway
}
