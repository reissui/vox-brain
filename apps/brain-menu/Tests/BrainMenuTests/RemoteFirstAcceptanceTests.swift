import Foundation
import SwiftUI
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct RemoteFirstAcceptanceTests {
    @Test
    func pairedModelsCompleteEveryRemoteFlowWithoutALocalCheckout() async throws {
        let fixture = try RemoteFirstAppFixture()
        defer { fixture.remove() }
        let client = fixture.client

        let metadata = try await client.pair(code: "acceptance-pairing-code")
        #expect(metadata.instanceID == "acceptance-brain")
        #expect(metadata.scopes == [.capture, .read, .control])
        #expect(client.pairedInstance == metadata)
        #expect(fixture.credentials.token == "acceptance-device-token")
        #expect(!FileManager.default.fileExists(atPath: fixture.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.cliURL.path))

        let store = BrainStore(
            client: client,
            now: { Date(timeIntervalSince1970: 1_784_193_000) }
        )
        await store.refresh()

        let knowledge = RemoteKnowledgeStore(api: client, debounce: .zero, sleep: { _ in })
        knowledge.search("remote-first")
        await knowledge.waitForPendingSearch()
        let document = await knowledge.select(path: "notes/Remote First.md")

        let interruptedChat = BrainChatController(
            client: client,
            defaults: fixture.defaults,
            pollInterval: .zero,
            sleep: { _ in throw BrainAPIError.transport },
            now: { Date(timeIntervalSince1970: 1_784_192_700) }
        )
        await interruptedChat.submit("What is remote-first?")
        #expect(fixture.defaults.data(forKey: BrainChatController.currentJobDefaultsKey) != nil)

        let relaunchedClient = try fixture.relaunchedClient()
        let relaunchedKnowledge = RemoteKnowledgeStore(
            api: relaunchedClient,
            debounce: .zero,
            sleep: { _ in }
        )
        await relaunchedKnowledge.refresh()
        let relaunchedDocument = await relaunchedKnowledge.select(path: "notes/Remote First.md")

        let chat = BrainChatController(
            client: relaunchedClient,
            defaults: fixture.defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )
        await chat.restore()

        let capture = CaptureController(
            api: fixture.captureAPI,
            makeUUID: fixture.nextCaptureUUID
        )
        capture.draft = .empty(kind: .note)
        capture.draft.noteText = "Remote acceptance note"
        await capture.submit()
        #expect(capture.submissionState == .queued(id: "capture-1"))

        capture.draft = .empty(kind: .link)
        capture.draft.url = "example.test/remote-first"
        capture.draft.comment = "Remote acceptance link"
        capture.draft.selectedText = "Selected remote context"
        await capture.submit()
        #expect(capture.submissionState == .queued(id: "capture-2"))

        capture.draft = .empty(kind: .image)
        capture.draft.image = CaptureImagePayload(
            data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x42]),
            mimeType: "image/png",
            filename: "remote.png"
        )
        capture.draft.imageContext = "A remote-first acceptance image"
        await capture.submit()
        #expect(capture.submissionState == .queued(id: "capture-3"))

        let actions = RemoteBrainController(
            api: client,
            defaults: fixture.defaults,
            sleep: { _ in }
        )
        // RemoteBrainController intentionally serializes mutations across all
        // windows. The package's controller stress suite runs in parallel with
        // this acceptance suite, so wait for its deliberately held job to
        // finish before exercising this app window's real confirmation flow.
        try await Task.sleep(for: .seconds(2))
        #expect(actions.request(.process) == .confirmationRequired(.process))
        _ = await actions.confirmPendingAction()
        #expect(actions.displayedState == .completed)
        #expect(actions.request(.digest) == .confirmationRequired(.digest))
        _ = await actions.confirmPendingAction()
        #expect(actions.displayedState == .completed)

        let gmail = GmailConnectionController(api: RemoteFirstGmailAPI(client: client))
        await gmail.refresh()
        #expect(gmail.state == .connected(account: "owner@example.test"))

        let launch = RemoteFirstLaunchService()
        let roots: [AnyView] = [
            AnyView(MenuBarView(store: store)),
            AnyView(DashboardView(store: store)),
            AnyView(CaptureView(controller: capture)),
            AnyView(KnowledgeView(store: knowledge)),
            AnyView(ChatView(controller: chat)),
            AnyView(ActionsView(store: store, controller: actions)),
            AnyView(MacMiniView(store: store, controller: actions)),
            AnyView(SettingsView(
                launchAtLogin: LaunchAtLoginController(
                    service: launch,
                    defaults: fixture.defaults,
                    openLoginItems: {}
                ),
                gmail: gmail
            )),
        ]

        #expect(roots.count == 8)
        #expect(store.snapshot?.health.overall == .activity)
        #expect(store.snapshot?.health.operations?.backlogCount == 1)
        #expect(store.snapshot?.health.operations?.process.state == "running")
        #expect(MacMiniView.recoveryCommands.map(\.id) == ["status", "doctor", "kickstart", "logs"])
        #expect(MacMiniView.recoveryCommands.allSatisfy { !$0.command.contains("token") })
        #expect(knowledge.results.map(\.relativePath) == ["notes/Remote First.md"])
        #expect(document?.readingBody == "# Remote First\n\nCanonical remote knowledge.")
        #expect(relaunchedKnowledge.results.map(\.relativePath) == ["notes/Remote First.md"])
        #expect(relaunchedDocument?.readingBody == document?.readingBody)
        #expect(chat.turns.first?.answer == "Remote answer grounded in [[Remote First]].")
        #expect(fixture.defaults.data(forKey: BrainChatController.currentJobDefaultsKey) == nil)
        #expect(fixture.server.acceptedCaptures.map { $0["type"] as? String } == [
            "note", nil, "design",
        ])
        #expect(fixture.server.jobKinds == ["ask", "process", "digest"])
        #expect(fixture.server.authenticatedRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer acceptance-device-token"
        })
        #expect(!fixture.server.renderedRequests.contains("~/dev/brain"))
        #expect(!fixture.server.renderedRequests.contains("/tmp/vox-brain-example"))
        #expect(!FileManager.default.fileExists(atPath: fixture.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.cliURL.path))
    }

    @Test
    func nativeMeetingUploadsFinalTranscriptWithoutVaultOrAudioAccess() async throws {
        let fixture = try RemoteFirstAppFixture()
        defer { fixture.remove() }
        _ = try await fixture.client.pair(code: "acceptance-pairing-code")

        let root = fixture.homeURL.appendingPathComponent("Meeting State", isDirectory: true)
        let meetingStore = MeetingStore(rootURL: root)
        let meeting = MeetingRecord(
            title: "Native standup",
            startedAt: Date(timeIntervalSince1970: 1_784_193_000),
            endedAt: Date(timeIntervalSince1970: 1_784_193_060),
            lifecycleState: .completed,
            speechEngine: "voxtype",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        let words = "Ship the native meeting path."
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: words,
            baseSpeakerID: "local"
        )
        try meetingStore.save(meeting, utterances: [utterance])
        let audio = root.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
            .appendingPathComponent("microphone.m4a")
        try Data("audio-must-remain-local-and-unread".utf8).write(to: audio)
        let controller = MeetingUploadController(
            meetingStore: meetingStore,
            analysisStore: FileMeetingAnalysisStore(rootURL: root),
            uploadStore: FileMeetingUploadStore(rootURL: root),
            api: fixture.captureAPI,
            sleep: { _ in throw CancellationError() }
        )

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        let transcriptAttempts = fixture.server.transcriptAttempts
        let accepted = fixture.server.acceptedCaptures.filter { $0["type"] as? String == "transcript" }
        #expect(transcriptAttempts.count == 1)
        #expect(accepted.count == 1)
        #expect((accepted[0]["transcript"] as? String)?.contains(words) == true)
        #expect(accepted[0]["source"] as? String == "Brain.app meeting")
        #expect(accepted[0]["image"] == nil)
        #expect(accepted[0]["audio"] == nil)
        #expect(try Data(contentsOf: audio) == Data("audio-must-remain-local-and-unread".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.cliURL.path))
    }

    @Test
    func captureNeedsAttentionDoesNotMasqueradeAsAgentGatewayOrAutomationFailure() async throws {
        let fixture = try RemoteFirstAppFixture()
        defer { fixture.remove() }
        _ = try await fixture.client.pair(code: "acceptance-pairing-code")
        let store = BrainStore(client: fixture.client)
        await store.refresh()
        let snapshot = try #require(store.snapshot)
        let groups = BrainPresentation.checkGroups(for: snapshot.health.checks)

        func group(_ scope: DashboardScope) throws -> DashboardCheckGroup {
            try #require(groups.first { $0.scope == scope })
        }

        #expect(BrainPresentation.state(for: try group(.captureDelivery), in: snapshot).label == "Activity")
        #expect(BrainPresentation.state(for: try group(.macMiniAgent), in: snapshot).label == "Healthy")
        #expect(BrainPresentation.state(for: try group(.gateway), in: snapshot).label == "Healthy")
        #expect(BrainPresentation.state(for: try group(.librarianAutomation), in: snapshot).label == "Healthy")

        let actualFailures = BrainPresentation.checkGroups(for: [
            check("agent.failed", scope: "mac_mini_agent", state: .failure),
            check("gateway.failed", scope: "gateway", state: .failure),
            check("automation.failed", scope: "automation", state: .failure),
            check("capture.needs_attention", scope: "capture", state: .activity),
        ])
        for scope in [DashboardScope.macMiniAgent, .gateway, .librarianAutomation] {
            let failure = try #require(actualFailures.first { $0.scope == scope })
            #expect(BrainPresentation.state(for: failure, in: snapshot).label == "Failure")
        }
    }

    private func check(
        _ id: String,
        scope: String,
        state: BrainCheckState
    ) -> BrainHealthCheck {
        BrainHealthCheck(
            id: id,
            scope: scope,
            state: state,
            summary: id,
            detail: id,
            remediation: nil
        )
    }
}

private final class RemoteFirstAppFixture {
    let homeURL: URL
    let defaults: UserDefaults
    let defaultsSuite: String
    let credentials = RemoteFirstCredentialStore()
    let server = RemoteFirstFakeServer()
    let client: BrainAPIClient
    private let uuidBox = RemoteFirstLockedBox(0)

    var vaultURL: URL { homeURL.appendingPathComponent("dev/brain", isDirectory: true) }
    var cliURL: URL { vaultURL.appendingPathComponent("scripts/brain") }
    var captureAPI: RemoteFirstCaptureAPI { RemoteFirstCaptureAPI(client: client) }

    init() throws {
        homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFirstAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        defaultsSuite = "RemoteFirstAcceptance.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        RemoteFirstURLProtocol.install(server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteFirstURLProtocol.self]
        client = try BrainAPIClient(
            baseURL: URL(string: "https://brain.acceptance.test")!,
            session: URLSession(configuration: configuration),
            credentialStore: credentials,
            defaults: defaults,
            requestTimeout: 5
        )
    }

    func relaunchedClient() throws -> BrainAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteFirstURLProtocol.self]
        return try BrainAPIClient(
            baseURL: URL(string: "https://brain.acceptance.test")!,
            session: URLSession(configuration: configuration),
            credentialStore: credentials,
            defaults: defaults,
            requestTimeout: 5
        )
    }

    lazy var nextCaptureUUID: () -> UUID = { [uuidBox] in
        let next = uuidBox.withLock { value -> Int in
            value += 1
            return value
        }
        return UUID(uuidString: String(format: "64000000-0000-4000-8000-%012d", next))!
    }

    func remove() {
        RemoteFirstURLProtocol.reset()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: homeURL)
    }
}

private struct RemoteFirstTranscriptAttempt: Equatable {
    let idempotencyKey: String
    let body: Data
}

private final class RemoteFirstFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var capturesStorage: [[String: Any]] = []
    private var jobsStorage: [String: String] = [:]
    private var jobReadsStorage: [String: Int] = [:]
    private var jobKindsStorage: [String] = []
    private var requestsStorage: [URLRequest] = []
    private var transcriptAttemptsStorage: [RemoteFirstTranscriptAttempt] = []

    var acceptedCaptures: [[String: Any]] { withLock { capturesStorage } }
    var jobKinds: [String] { withLock { jobKindsStorage } }
    var transcriptAttempts: [RemoteFirstTranscriptAttempt] { withLock { transcriptAttemptsStorage } }
    var authenticatedRequests: [URLRequest] {
        withLock {
            requestsStorage.filter {
                $0.url?.path != "/v1/pair/claim" && $0.url?.path != "/health"
            }
        }
    }
    var renderedRequests: String { String(describing: withLock { requestsStorage }) }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        withLock { requestsStorage.append(request) }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"

        if path == "/v1/pair/claim", method == "POST" {
            return response(request, status: 200, body: """
            {"instance_id":"acceptance-brain","device_id":"acceptance-device","device_name":"Acceptance Mac","scopes":["capture","read","control"],"token":"acceptance-device-token"}
            """)
        }
        if path == "/health" {
            return response(request, status: 200, body: #"{"ok":true}"#)
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer acceptance-device-token" else {
            return response(request, status: 401, body: #"{"error":"unauthorized"}"#)
        }

        switch (method, path) {
        case ("GET", "/v1/status"):
            return response(request, status: 200, body: """
            {"schema_version":1,"generated_at":"2026-07-16T09:00:00Z","vault":{"path":"remote","state":"clean","dirty_paths":0},"counts":{"inbox":7,"sources":6,"notes":5,"people":4,"projects":3},"last_run":{"at":"2026-07-16T08:59:00Z","commit":"acceptance","summary":"remote acceptance"},"services":[]}
            """)
        case ("GET", "/v1/health"):
            return response(request, status: 200, body: """
            {"schema_version":1,"generated_at":"2026-07-16T09:00:01Z","overall":"activity","counts":{"pass":3,"activity":1,"warning":0,"failure":0},"checks":[{"id":"agent.heartbeat","scope":"mac_mini_agent","state":"pass","summary":"Agent current","detail":"The remote agent heartbeat is current.","remediation":null},{"id":"gateway.health","scope":"gateway","state":"pass","summary":"Gateway healthy","detail":"Gateway is reachable.","remediation":null},{"id":"automation.schedule","scope":"automation","state":"pass","summary":"Automation loaded","detail":"The Librarian schedule is loaded.","remediation":null},{"id":"capture.needs_attention","scope":"capture","state":"activity","summary":"One delivered capture needs attention","detail":"Old unresolved content is waiting, but delivery and agent heartbeat are healthy.","remediation":"Process the item when convenient."}],"operations":{"last_successful_poll":"2026-07-16T09:00:00.000Z","poll_age_seconds":1,"backlog_count":1,"oldest_backlog_age_seconds":30,"process":{"state":"running","label":"capture:safe-id","started_at":"2026-07-16T09:00:00.000Z","progress_age_seconds":1,"declared_bound_seconds":3600},"automation":{"last_progress_at":"2026-07-16T08:59:00Z","progress_age_seconds":61},"launchd":{"agent":"running","automation":"loaded"}}}
            """)
        case ("GET", "/v1/knowledge/documents"):
            return response(request, status: 200, body: #"{"documents":[{"title":"Remote First","path":"notes/Remote First.md"}]}"#)
        case ("GET", "/v1/knowledge/search"):
            return response(request, status: 200, body: #"{"query":"remote-first","results":[{"title":"Remote First","path":"notes/Remote First.md","snippet":"Canonical remote knowledge."}]}"#)
        case ("GET", "/v1/knowledge/document"):
            return response(request, status: 200, body: ##"{"path":"notes/Remote First.md","title":"Remote First","content":"# Remote First\n\nCanonical remote knowledge."}"##)
        case ("GET", "/v1/gmail/status"):
            return response(request, status: 200, body: #"{"status":"connected","account":"owner@example.test"}"#)
        case ("POST", "/v1/captures"):
            let body = request.httpBody ?? Data()
            let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
            if decoded["type"] as? String == "transcript" {
                let attempt = RemoteFirstTranscriptAttempt(idempotencyKey: key, body: body)
                withLock {
                    transcriptAttemptsStorage.append(attempt)
                }
            }
            let id = withLock { () -> String in
                capturesStorage.append(decoded)
                return "capture-\(capturesStorage.count)"
            }
            return response(request, status: 202, body: "{\"id\":\"\(id)\",\"state\":\"queued\"}")
        case ("POST", "/v1/jobs"):
            let value = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let kind = value?["kind"] as? String ?? ""
            let id = withLock { () -> String in
                jobKindsStorage.append(kind)
                let value = "\(kind)-job-\(jobKindsStorage.count)"
                jobsStorage[value] = kind
                return value
            }
            return response(request, status: 202, body: "{\"id\":\"\(id)\",\"state\":\"queued\"}")
        case ("GET", _) where path.hasPrefix("/v1/jobs/"):
            let id = String(path.dropFirst("/v1/jobs/".count))
            guard let kind = withLock({ jobsStorage[id] }) else {
                return response(request, status: 404, body: #"{"error":"not_found"}"#)
            }
            let reads = withLock { () -> Int in
                let value = (jobReadsStorage[id] ?? 0) + 1
                jobReadsStorage[id] = value
                return value
            }
            if kind == "ask", reads == 1 {
                return response(request, status: 200, body: """
                {"id":"\(id)","kind":"ask","state":"queued","output":null,"error":null,"detail":null,"truncated":false,"created_at":"2026-07-16T09:00:00Z","started_at":null,"finished_at":null,"updated_at":"2026-07-16T09:00:00Z"}
                """)
            }
            let output = kind == "ask"
                ? "Remote answer grounded in [[Remote First]]."
                : "Remote \(kind) completed."
            return response(request, status: 200, body: """
            {"id":"\(id)","kind":"\(kind)","state":"completed","output":"\(output)","error":null,"detail":null,"truncated":false,"created_at":"2026-07-16T09:00:00Z","started_at":"2026-07-16T09:00:01Z","finished_at":"2026-07-16T09:00:02Z","updated_at":"2026-07-16T09:00:02Z"}
            """)
        default:
            return response(request, status: 404, body: #"{"error":"not_found"}"#)
        }
    }

    private func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class RemoteFirstCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let box = RemoteFirstLockedBox<String?>(nil)
    var token: String? { box.value }

    func save(_ token: String, for account: String) throws { box.withLock { $0 = token } }
    func load(for account: String) throws -> String? { box.value }
    func delete(for account: String) throws { box.withLock { $0 = nil } }
}

private final class RemoteFirstLockedBox<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()
    init(_ value: Value) { storage = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func withLock<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&storage)
    }
}

private final class RemoteFirstURLProtocol: URLProtocol, @unchecked Sendable {
    private static let server = RemoteFirstLockedBox<RemoteFirstFakeServer?>(nil)
    static func install(_ value: RemoteFirstFakeServer) { server.withLock { $0 = value } }
    static func reset() { server.withLock { $0 = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            var normalized = request
            if normalized.httpBody == nil, let stream = normalized.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4_096)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(buffer, count: count)
                }
                normalized.httpBody = body
            }
            let (response, data) = try server.handle(normalized)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct RemoteFirstGmailAPI: GmailConnectionAPI {
    let client: BrainAPIClient
    func start() async throws -> URL { try await client.startGmailConnection().authorizationURL }
    func status() async throws -> GmailRemoteStatus {
        let value = try await client.gmailStatus()
        return switch value.status {
        case .disconnected: .disconnected
        case .connected: .connected(account: value.account ?? "")
        case .reconnectRequired: .reconnectRequired
        case .denied: .denied
        case .expired: .expired
        case .originUnavailable: .originUnavailable
        }
    }
    func disconnect() async throws { _ = try await client.disconnectGmail() }
}

private struct RemoteFirstCaptureAPI: BrainCaptureAPI {
    let client: BrainAPIClient
    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        try await client.capture(capture, idempotencyKey: idempotencyKey)
    }
}

@MainActor
private final class RemoteFirstLaunchService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus = .enabled
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}
