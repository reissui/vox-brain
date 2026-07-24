import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct BrainAPIClientTests {
    @Test
    func acceptsOnlyOneRootHTTPSOriginAndBoundsTimeouts() throws {
        for invalid in [
            "http://brain.example.test",
            "https://user:password@brain.example.test",
            "https://brain.example.test/prefix",
            "https://brain.example.test?origin=other",
            "https://brain.example.test/#fragment",
        ] {
            #expect(throws: BrainAPIError.invalidBaseURL) {
                _ = try BrainAPIClient(baseURL: try #require(URL(string: invalid)))
            }
        }
        #expect(throws: BrainAPIError.invalidBaseURL) {
            _ = try BrainAPIClient(
                baseURL: try #require(URL(string: "https://brain.example.test")),
                requestTimeout: BrainAPIClient.maximumRequestTimeout + 1
            )
        }

        let client = try BrainAPIClient(
            baseURL: try #require(URL(string: "https://BRAIN.example.test/")),
            requestTimeout: 7
        )
        #expect(client.baseURL.absoluteString == "https://brain.example.test")
        #expect(client.requestTimeout == 7)
    }

    @Test
    func pairingClaimsCodeWithoutBearerAndStoresTokenOnlyInCredentialStore() async throws {
        let requests = LockedBox<[URLRequest]>([])
        TestURLProtocol.install { request in
            requests.withLock { $0.append(request) }
            return Self.jsonResponse(
                request,
                status: 200,
                body: """
                {"instance_id":"brain-owner","device_id":"device-1","device_name":"the owner Mac","scopes":["capture","read","control"],"token":"returned-device-token"}
                """
            )
        }
        defer { TestURLProtocol.reset() }
        let (defaults, suite) = try testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentialStore()
        let client = try makeClient(defaults: defaults, credentials: credentials)

        let metadata = try await client.pair(code: "  one-time-code  ")

        #expect(metadata.instanceID == "brain-owner")
        #expect(metadata.deviceID == "device-1")
        #expect(metadata.scopes == [.capture, .read, .control])
        #expect(credentials.token == "returned-device-token")
        #expect(client.pairedInstance == metadata)
        let request = try #require(requests.value.first)
        #expect(request.url?.path == "/v1/pair/claim")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 9)
        #expect(try jsonObject(request.httpBody) == ["code": "one-time-code"])
        let defaultsText = String(describing: defaults.dictionaryRepresentation())
        #expect(defaultsText.contains("returned-device-token") == false)
    }

    @Test
    func typedMethodsUseExactVersionedPathsMethodsQueriesJSONAndAuth() async throws {
        let requests = LockedBox<[URLRequest]>([])
        TestURLProtocol.install { request in
            requests.withLock { $0.append(request) }
            let path = request.url?.path ?? ""
            let body: String
            switch path {
            case "/v1/status":
                body = fixtureText("status-healthy")
            case "/v1/health":
                body = fixtureText("health-activity")
            case "/v1/knowledge/search":
                body = #"{"query":"Agents & Brain","results":[{"title":"Agents","path":"notes/Agents.md","snippet":"A result"}]}"#
            case "/v1/knowledge/document":
                body = ##"{"path":"notes/Agents & Brain.md","title":"Agents","content":"# Agents"}"##
            case "/v1/jobs" where request.httpMethod == "POST":
                body = #"{"id":"job-1","state":"queued"}"#
            case "/v1/jobs/job-1":
                body = #"{"id":"job-1","kind":"ask","state":"completed","output":"[[notes/Agents]]","created_at":"2026-07-15T10:00:00.000Z","started_at":"2026-07-15T10:00:01.000Z","finished_at":"2026-07-15T10:00:02.000Z","updated_at":"2026-07-15T10:00:02.000Z"}"#
            case "/v1/captures":
                body = #"{"id":"capture-1","state":"queued"}"#
            case "/v1/captures/11111111-2222-4333-8444-555555555555":
                body = #"{"id":"11111111-2222-4333-8444-555555555555","state":"processing","retryable":false,"error":null,"created_at":"2026-07-15T10:00:00.000Z","updated_at":"2026-07-15T10:00:02.000Z","delivered_at":null}"#
            case "/v1/gmail/start":
                body = #"{"authorization_url":"https://accounts.google.com/o/oauth2/v2/auth?state=safe"}"#
            case "/v1/gmail/status":
                body = #"{"status":"connected","account":"owner@example.test"}"#
            case "/v1/gmail/disconnect":
                body = #"{"status":"disconnected"}"#
            case "/v1/pair/revoke":
                body = #"{"revoked":true,"device_id":"device-1"}"#
            case "/health":
                body = #"{"ok":true}"#
            default:
                return Self.jsonResponse(request, status: 404, body: #"{"error":"not_found"}"#)
            }
            return Self.jsonResponse(request, status: 200, body: body)
        }
        defer { TestURLProtocol.reset() }
        let fixture = try pairedClient()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        _ = try await fixture.client.status()
        _ = try await fixture.client.health()
        let search = try await fixture.client.searchKnowledge(query: "Agents & Brain", limit: 3)
        let document = try await fixture.client.knowledgeDocument(path: "notes/Agents & Brain.md")
        _ = try await fixture.client.createJob(kind: .ask, question: "What do I know?")
        let job = try await fixture.client.jobStatus(id: "job-1")
        _ = try await fixture.client.capture(
            BrainCaptureRequest(type: .note, text: "Remember this", source: "Brain.app"),
            idempotencyKey: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )
        let captureStatus = try await fixture.client.captureStatus(
            id: "11111111-2222-4333-8444-555555555555"
        )
        _ = try await fixture.client.startGmailConnection()
        _ = try await fixture.client.gmailStatus()
        _ = try await fixture.client.disconnectGmail()
        _ = try await fixture.client.revokeDevice()
        _ = try await fixture.client.healthProbe()

        #expect(search.results.first?.path == "notes/Agents.md")
        #expect(document.content == "# Agents")
        #expect(job.output == "[[notes/Agents]]")
        #expect(captureStatus.state == .processing)
        #expect(captureStatus.retryable == false)
        #expect(captureStatus.error == nil)
        #expect(captureStatus.deliveredAt == nil)
        let recorded = requests.value
        #expect(recorded.map { $0.url?.path ?? "" } == [
            "/v1/status", "/v1/health", "/v1/knowledge/search",
            "/v1/knowledge/document", "/v1/jobs", "/v1/jobs/job-1",
            "/v1/captures", "/v1/captures/11111111-2222-4333-8444-555555555555",
            "/v1/gmail/start", "/v1/gmail/status",
            "/v1/gmail/disconnect", "/v1/pair/revoke", "/health",
        ])
        #expect(recorded.dropLast().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer stored-device-token"
        })
        #expect(recorded.last?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(recorded.allSatisfy { $0.timeoutInterval == 9 })
        #expect(URLComponents(url: recorded[2].url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "q", value: "Agents & Brain"),
            URLQueryItem(name: "limit", value: "3"),
        ])
        #expect(URLComponents(url: recorded[3].url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "path", value: "notes/Agents & Brain.md"),
        ])
        #expect(try jsonObject(recorded[4].httpBody) == [
            "kind": "ask", "question": "What do I know?",
        ])
        #expect(recorded[6].value(forHTTPHeaderField: "Idempotency-Key") == "11111111-2222-4333-8444-555555555555")
        #expect(try jsonObject(recorded[6].httpBody) == [
            "type": "note", "text": "Remember this", "source": "Brain.app",
        ])
        #expect(recorded[7].httpMethod == "GET")
        #expect(recorded[7].httpBody == nil)
        #expect(recorded[7].url?.query == nil)
        #expect(recorded[8].httpMethod == "POST")
        #expect(try jsonObject(recorded[8].httpBody) == [:])
        #expect(try jsonObject(recorded[10].httpBody) == ["confirm": true])
        #expect(recorded[11].httpMethod == "POST")
    }

    @Test
    func captureStatusRejectsAnythingExceptOneCanonicalUUIDPath() async throws {
        let fixture = try pairedClient()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        for identifier in [
            "",
            "capture/other",
            "00000000-0000-0000-0000-000000000000",
            "11111111-2222-4333-8444-555555555555?instance=other",
            "{11111111-2222-4333-8444-555555555555}",
        ] {
            do {
                _ = try await fixture.client.captureStatus(id: identifier)
                Issue.record("Expected unsafe capture ID to be rejected")
            } catch let error as BrainAPIError {
                #expect(error == .invalidRequest)
            }
        }
    }

    @Test
    func decodesGatewayStaleSnapshotMetadataFromStatusAndHealth() async throws {
        let snapshotAt = "2026-07-15T08:58:55Z"
        let statusBody = try staleFixtureText("status-healthy", snapshotAt: snapshotAt, ageSeconds: 65)
        let healthBody = try staleFixtureText("health-activity", snapshotAt: snapshotAt, ageSeconds: 65)
        TestURLProtocol.install { request in
            let body = request.url?.path == "/v1/status" ? statusBody : healthBody
            return Self.jsonResponse(
                request,
                status: 200,
                body: body,
                headers: [
                    "X-Brain-Snapshot": "stale",
                    "X-Brain-Snapshot-Age-Seconds": "65",
                ]
            )
        }
        defer { TestURLProtocol.reset() }
        let fixture = try pairedClient()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let status = try await fixture.client.status()
        let health = try await fixture.client.health()
        let expectedDate = try #require(ISO8601DateFormatter().date(from: snapshotAt))

        #expect(status.freshness == BrainReportFreshness(
            isStale: true, snapshotAt: expectedDate, ageSeconds: 65
        ))
        #expect(health.freshness == status.freshness)
    }

    @Test
    func bearerRedirectsStayOnTheExactOriginAndNeverLeakCrossOrigin() throws {
        let origin = try #require(URL(string: "https://brain.example.test"))
        let delegate = BrainRedirectDelegate(origin: origin, authorization: "Bearer top-secret")
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: origin)
        let response = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "/v1/status"]
        ))

        var sameOrigin: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://brain.example.test/v1/status")!)
        ) { sameOrigin = $0 }
        #expect(sameOrigin?.value(forHTTPHeaderField: "Authorization") == "Bearer top-secret")

        var otherOrigin: URLRequest??
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://attacker.invalid/steal")!)
        ) { otherOrigin = $0 }
        #expect(otherOrigin != nil)
        #expect(otherOrigin! == nil)
    }

    @Test
    func decodesPublicErrorsAndNeverReflectsTokensOrRawBodiesInTransportText() async throws {
        let fixture = try pairedClient()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }
        TestURLProtocol.install { request in
            Self.jsonResponse(
                request,
                status: 422,
                body: #"{"error":"invalid_query","private":"raw-response-secret"}"#,
                headers: ["X-Request-ID": "request-1"]
            )
        }
        do {
            _ = try await fixture.client.status()
            Issue.record("Expected HTTP error")
        } catch let error as BrainAPIError {
            #expect(error == .http(status: 422, code: "invalid_query", message: nil, requestID: "request-1"))
            #expect(error.localizedDescription.contains("stored-device-token") == false)
            #expect(error.localizedDescription.contains("raw-response-secret") == false)
        }

        TestURLProtocol.install { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await fixture.client.status()
            Issue.record("Expected transport error")
        } catch let error as BrainAPIError {
            #expect(error == .transport)
            #expect(error.localizedDescription == "Could not reach Brain.")
            #expect(error.localizedDescription.contains("stored-device-token") == false)
        }
        TestURLProtocol.reset()
    }

    @Test
    func disconnectAttemptsRevocationThenAlwaysClearsLocalPairingOnOutage() async throws {
        let requests = LockedBox<[URLRequest]>([])
        TestURLProtocol.install { request in
            requests.withLock { $0.append(request) }
            throw URLError(.networkConnectionLost)
        }
        defer { TestURLProtocol.reset() }
        let fixture = try pairedClient()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite) }

        let result = await fixture.client.disconnect()

        #expect(result == BrainDisconnectResult(remoteRevoked: false, localCredentialRemoved: true))
        #expect(fixture.client.pairedInstance == nil)
        #expect(fixture.credentials.token == nil)
        #expect(requests.value.first?.url?.path == "/v1/pair/revoke")
        #expect(requests.value.first?.value(forHTTPHeaderField: "Authorization") == "Bearer stored-device-token")
    }

    private static func jsonResponse(
        _ request: URLRequest,
        status: Int,
        body: String,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        var fields = ["Content-Type": "application/json"]
        fields.merge(headers) { _, new in new }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields
        )!
        return (response, Data(body.utf8))
    }
}

private func pairedClient() throws -> (
    client: BrainAPIClient,
    credentials: MemoryCredentialStore,
    defaults: UserDefaults,
    defaultsSuite: String
) {
    let (defaults, suite) = try testDefaults()
    let credentials = MemoryCredentialStore(token: "stored-device-token")
    let baseURL = try #require(URL(string: "https://brain.example.test"))
    let metadata = BrainInstanceMetadata(
        baseURL: baseURL,
        instanceID: "brain-owner",
        deviceID: "device-1",
        deviceName: "the owner Mac",
        scopes: [.capture, .read, .control]
    )
    defaults.set(try JSONEncoder().encode(metadata), forKey: BrainAPIClient.metadataDefaultsKey)
    return (
        try makeClient(defaults: defaults, credentials: credentials),
        credentials,
        defaults,
        suite
    )
}

private func makeClient(
    defaults: UserDefaults,
    credentials: MemoryCredentialStore
) throws -> BrainAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return try BrainAPIClient(
        baseURL: URL(string: "https://brain.example.test")!,
        session: URLSession(configuration: configuration),
        credentialStore: credentials,
        defaults: defaults,
        requestTimeout: 9
    )
}

private func testDefaults() throws -> (UserDefaults, String) {
    let suite = "BrainAPIClientTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

private func jsonObject(_ data: Data?) throws -> [String: AnyHashable] {
    let data = try #require(data)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
    return object
}

private func fixtureText(_ name: String) -> String {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! String(contentsOf: url, encoding: .utf8)
}

private func staleFixtureText(
    _ name: String,
    snapshotAt: String,
    ageSeconds: Int
) throws -> String {
    let data = Data(fixtureText(name).utf8)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["stale"] = true
    object["snapshot_at"] = snapshotAt
    object["age_seconds"] = ageSeconds
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private final class MemoryCredentialStore: DeviceCredentialStoring, @unchecked Sendable {
    private let box: LockedBox<String?>

    init(token: String? = nil) { box = LockedBox(token) }
    var token: String? { box.value }

    func save(_ token: String, for account: String) throws {
        box.withLock { $0 = token }
    }

    func load(for account: String) throws -> String? { box.value }

    func delete(for account: String) throws {
        box.withLock { $0 = nil }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
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

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handler = LockedBox<Handler?>(nil)

    static func install(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    static func reset() {
        handler.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            var handledRequest = request
            if handledRequest.httpBody == nil, let stream = handledRequest.httpBodyStream {
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
                handledRequest.httpBody = body
            }
            let (response, data) = try handler(handledRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
