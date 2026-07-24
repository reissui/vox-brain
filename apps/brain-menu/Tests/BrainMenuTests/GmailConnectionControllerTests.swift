import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct GmailConnectionControllerTests {
    @Test
    func startOpensBrowserAndPollsUntilRemoteAccountIsConnected() async throws {
        let authorizationURL = try #require(URL(string: "https://accounts.example.test/consent"))
        let api = FakeGmailAPI(
            authorizationURL: authorizationURL,
            statuses: [.disconnected, .connected(account: "owner@example.test")]
        )
        let opener = FakeGmailOpener()
        let controller = makeController(api: api, opener: opener)

        await controller.connect()

        #expect(controller.state == .connected(account: "owner@example.test"))
        #expect(controller.errorMessage == nil)
        #expect(opener.openedURLs == [authorizationURL])
        let calls = await api.calls
        #expect(calls == [.start, .status, .status])
    }

    @Test
    func pollingSurfacesDenialExpiryOutageAndTimeoutAsDistinctOutcomes() async {
        let cases: [([GmailRemoteStatus], Int, GmailConnectionState)] = [
            ([.denied], 2, .denied),
            ([.expired], 2, .expired),
            ([.originUnavailable], 2, .unavailable(
                detail: "The remote Brain instance cannot currently report Gmail status."
            )),
            ([.disconnected, .disconnected], 2, .timedOut),
        ]

        for (statuses, attempts, expected) in cases {
            let api = FakeGmailAPI(statuses: statuses)
            let controller = makeController(
                api: api,
                opener: FakeGmailOpener(),
                maximumPollingAttempts: attempts
            )

            await controller.connect()

            #expect(controller.state == expected)
        }
    }

    @Test
    func realGatewayStatusContractMakesDenialAndExpiryTerminal() async throws {
        let cases: [(String, GmailConnectionState)] = [
            ("denied", .denied),
            ("expired", .expired),
        ]

        for (wireStatus, expected) in cases {
            let suite = "GmailConnectionContractTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let baseURL = try #require(URL(string: "https://brain.example.test"))
            defaults.set(
                try JSONEncoder().encode(BrainInstanceMetadata(
                    baseURL: baseURL,
                    instanceID: "brain-owner",
                    deviceID: "device-1",
                    deviceName: "the owner Mac",
                    scopes: [.read, .control]
                )),
                forKey: BrainAPIClient.metadataDefaultsKey
            )
            GmailContractURLProtocol.install(status: wireStatus)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GmailContractURLProtocol.self]
            let client = try BrainAPIClient(
                baseURL: baseURL,
                session: URLSession(configuration: configuration),
                credentialStore: GmailMemoryCredentialStore(),
                defaults: defaults,
                requestTimeout: 2
            )
            let controller = GmailConnectionController(
                api: BrainGmailConnectionAPI(client: client),
                opener: FakeGmailOpener(),
                pollingInterval: .zero,
                maximumPollingAttempts: 2,
                sleep: { _ in }
            )

            await controller.connect()

            #expect(controller.state == expected)
            #expect(GmailContractURLProtocol.paths == ["/v1/gmail/start", "/v1/gmail/status"])
        }
    }

    @Test
    func refreshKeepsDisconnectedReconnectRequiredAndUnavailableDistinct() async {
        let cases: [(GmailRemoteStatus, GmailConnectionState)] = [
            (.disconnected, .disconnected),
            (.reconnectRequired, .reconnectRequired),
            (.originUnavailable, .unavailable(
                detail: "The remote Brain instance cannot currently report Gmail status."
            )),
        ]

        for (remote, expected) in cases {
            let api = FakeGmailAPI(statuses: [remote])
            let controller = makeController(api: api, opener: FakeGmailOpener())

            await controller.refresh()

            #expect(controller.state == expected)
            #expect(await api.calls == [.status])
        }
    }

    @Test
    func disconnectUsesOnlyRemoteAPIAndClearsDisplayedAccount() async {
        let api = FakeGmailAPI(statuses: [.connected(account: "owner@example.test")])
        let controller = makeController(api: api, opener: FakeGmailOpener())
        await controller.refresh()
        #expect(controller.state == .connected(account: "owner@example.test"))

        await controller.disconnect()

        #expect(controller.state == .disconnected)
        #expect(controller.errorMessage == nil)
        #expect(await api.calls == [.status, .disconnect])
    }

    @Test
    func browserFailureDoesNotPollAndReportsUnavailable() async {
        let api = FakeGmailAPI(statuses: [.connected(account: "owner@example.test")])
        let opener = FakeGmailOpener(result: false)
        let controller = makeController(api: api, opener: opener)

        await controller.connect()

        #expect(controller.state == .unavailable(
            detail: "Brain could not open the Google consent page in the default browser."
        ))
        #expect(await api.calls == [.start])
    }

    @Test
    func implementationHasNoFilePickerCommandRunnerOrLocalCredentialAccess() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = try String(contentsOf: packageRoot.appendingPathComponent(
            "Sources/BrainMenu/Gmail/GmailConnectionController.swift"
        ))
        let settings = try String(contentsOf: packageRoot.appendingPathComponent(
            "Sources/BrainMenu/Views/SettingsView.swift"
        ))

        for forbidden in [
            "CommandExecutor", "ProcessCommandExecutor", "stateDirectory", "credentialsURL",
            "scripts/brain", "FileManager",
        ] {
            #expect(controller.contains(forbidden) == false)
        }
        for forbidden in [
            ".fileImporter", "UniformTypeIdentifiers", "showGmailImporter", ".json",
            "local Gmail authorization", "local Google authorization",
        ] {
            #expect(settings.contains(forbidden) == false)
        }
    }

    private func makeController(
        api: FakeGmailAPI,
        opener: FakeGmailOpener,
        maximumPollingAttempts: Int = 3
    ) -> GmailConnectionController {
        GmailConnectionController(
            api: api,
            opener: opener,
            pollingInterval: .zero,
            maximumPollingAttempts: maximumPollingAttempts,
            sleep: { _ in }
        )
    }
}

private enum FakeGmailCall: Equatable, Sendable {
    case start
    case status
    case disconnect
}

private actor FakeGmailAPI: GmailConnectionAPI {
    private let authorizationURL: URL
    private var statuses: [GmailRemoteStatus]
    private(set) var calls: [FakeGmailCall] = []

    init(
        authorizationURL: URL = URL(string: "https://accounts.example.test/consent")!,
        statuses: [GmailRemoteStatus]
    ) {
        self.authorizationURL = authorizationURL
        self.statuses = statuses
    }

    func start() async throws -> URL {
        calls.append(.start)
        return authorizationURL
    }

    func status() async throws -> GmailRemoteStatus {
        calls.append(.status)
        guard !statuses.isEmpty else { throw BrainAPIError.invalidResponse }
        return statuses.removeFirst()
    }

    func disconnect() async throws {
        calls.append(.disconnect)
    }
}

@MainActor
private final class FakeGmailOpener: GmailAuthorizationOpening, @unchecked Sendable {
    private let result: Bool
    private(set) var openedURLs: [URL] = []

    init(result: Bool = true) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}

private final class GmailMemoryCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    func save(_ token: String, for account: String) throws {}
    func load(for account: String) throws -> String? { "stored-device-token" }
    func delete(for account: String) throws {}
}

private final class GmailLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&storage)
    }
}

private final class GmailContractURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var status = "denied"
        var paths: [String] = []
    }

    private static let state = GmailLockedBox(State())

    static var paths: [String] { state.value.paths }

    static func install(status: String) {
        state.withLock {
            $0.status = status
            $0.paths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let status = Self.state.withLock {
            $0.paths.append(path)
            return $0.status
        }
        let body: String
        switch path {
        case "/v1/gmail/start":
            body = #"{"authorization_url":"https://accounts.example.test/consent"}"#
        case "/v1/gmail/status":
            body = "{\"status\":\"\(status)\"}"
        default:
            body = #"{"status":"origin_unavailable"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
