import Foundation

struct BrainAPIClient: @unchecked Sendable {
    static let metadataDefaultsKey = "brain.remote.instance"
    static let defaultRequestTimeout: TimeInterval = 20
    static let maximumRequestTimeout: TimeInterval = 60

    let baseURL: URL
    let requestTimeout: TimeInterval

    private let session: URLSession
    private let credentialStore: any DeviceCredentialStoring
    private let defaults: UserDefaults

    init(
        baseURL: URL,
        session: URLSession = .shared,
        credentialStore: any DeviceCredentialStoring = DeviceCredentialStore(),
        defaults: UserDefaults = .standard,
        requestTimeout: TimeInterval = BrainAPIClient.defaultRequestTimeout
    ) throws {
        guard let normalized = Self.validatedBaseURL(baseURL),
              requestTimeout > 0,
              requestTimeout <= Self.maximumRequestTimeout else {
            throw BrainAPIError.invalidBaseURL
        }
        self.baseURL = normalized
        self.session = session
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.requestTimeout = requestTimeout
    }

    var pairedInstance: BrainInstanceMetadata? {
        guard let data = defaults.data(forKey: Self.metadataDefaultsKey),
              let metadata = try? JSONDecoder().decode(BrainInstanceMetadata.self, from: data),
              metadata.baseURL == baseURL else {
            return nil
        }
        return metadata
    }

    @discardableResult
    func pair(code: String) async throws -> BrainInstanceMetadata {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw BrainAPIError.invalidRequest }
        let claim: BrainPairingClaim = try await send(
            path: "/v1/pair/claim",
            method: "POST",
            body: PairingBody(code: code),
            authenticated: false
        )
        let metadata = BrainInstanceMetadata(
            baseURL: baseURL,
            instanceID: claim.instanceID,
            deviceID: claim.deviceID,
            deviceName: claim.deviceName,
            scopes: claim.scopes
        )
        do {
            try credentialStore.save(claim.token, for: credentialAccount)
        } catch {
            throw BrainAPIError.credentialUnavailable
        }
        do {
            let data = try JSONEncoder().encode(metadata)
            defaults.set(data, forKey: Self.metadataDefaultsKey)
        } catch {
            try? credentialStore.delete(for: credentialAccount)
            throw BrainAPIError.invalidResponse
        }
        return metadata
    }

    func status() async throws -> BrainStatusReport {
        try await send(path: "/v1/status")
    }

    func health() async throws -> BrainHealthReport {
        try await send(path: "/v1/health")
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        try await send(path: "/health", authenticated: false)
    }

    func listKnowledge(limit: Int? = nil) async throws -> BrainKnowledgeDocumentsResponse {
        guard limit.map({ (1...50).contains($0) }) ?? true else {
            throw BrainAPIError.invalidRequest
        }
        let items = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        return try await send(path: "/v1/knowledge/documents", queryItems: items)
    }

    func searchKnowledge(query: String, limit: Int? = nil) async throws -> BrainKnowledgeSearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256,
              limit.map({ (1...50).contains($0) }) ?? true else {
            throw BrainAPIError.invalidRequest
        }
        var items = [URLQueryItem(name: "q", value: query)]
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await send(path: "/v1/knowledge/search", queryItems: items)
    }

    func knowledgeDocument(path: String) async throws -> BrainKnowledgeDocument {
        guard !path.isEmpty, path.count <= 1_024 else { throw BrainAPIError.invalidRequest }
        return try await send(
            path: "/v1/knowledge/document",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    func createJob(kind: BrainJobKind, question: String? = nil) async throws -> BrainJobCreated {
        if kind == .ask {
            guard let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrainAPIError.invalidRequest
            }
        } else if question != nil {
            throw BrainAPIError.invalidRequest
        }
        return try await send(
            path: "/v1/jobs",
            method: "POST",
            body: JobBody(kind: kind, question: question)
        )
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        guard Self.isSafeIdentifier(id) else { throw BrainAPIError.invalidRequest }
        return try await send(path: "/v1/jobs/\(id)")
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> BrainCaptureReceipt {
        try await send(
            path: "/v1/captures",
            method: "POST",
            body: capture,
            headers: ["Idempotency-Key": idempotencyKey.uuidString.lowercased()]
        )
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        guard let identifier = Self.canonicalCaptureIdentifier(id) else {
            throw BrainAPIError.invalidRequest
        }
        return try await send(path: "/v1/captures/\(identifier)")
    }

    func startGmailConnection() async throws -> BrainGmailAuthorization {
        try await send(path: "/v1/gmail/start", method: "POST", body: EmptyBody())
    }

    func gmailStatus() async throws -> BrainGmailStatus {
        try await send(path: "/v1/gmail/status")
    }

    func disconnectGmail() async throws -> BrainGmailDisconnectResponse {
        try await send(
            path: "/v1/gmail/disconnect",
            method: "POST",
            body: ConfirmationBody(confirm: true)
        )
    }

    func revokeDevice() async throws -> BrainDeviceRevokeResponse {
        try await send(path: "/v1/pair/revoke", method: "POST", body: EmptyBody())
    }

    /// Best-effort remote revocation followed by unconditional local cleanup.
    /// A network outage can leave the server-side device active, but never leaves
    /// this Mac able to use it or presented as paired.
    func disconnect() async -> BrainDisconnectResult {
        var revoked = false
        if pairedInstance != nil,
           let response = try? await revokeDevice() {
            revoked = response.revoked
        }

        var removed = true
        do {
            try credentialStore.delete(for: credentialAccount)
        } catch {
            removed = false
        }
        defaults.removeObject(forKey: Self.metadataDefaultsKey)
        return BrainDisconnectResult(remoteRevoked: revoked, localCredentialRemoved: removed)
    }

    private var credentialAccount: String { baseURL.absoluteString }

    private func send<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true,
        headers: [String: String] = [:]
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            bodyData: nil,
            queryItems: queryItems,
            authenticated: authenticated,
            headers: headers
        )
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw BrainAPIError.invalidRequest
        }
        return try await send(
            path: path,
            method: method,
            bodyData: data,
            queryItems: queryItems,
            authenticated: authenticated,
            headers: headers
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        bodyData: Data?,
        queryItems: [URLQueryItem],
        authenticated: Bool,
        headers: [String: String]
    ) async throws -> Response {
        guard path.hasPrefix("/"), !path.contains("?") else {
            throw BrainAPIError.invalidRequest
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url, Self.sameOrigin(url, baseURL) else {
            throw BrainAPIError.invalidRequest
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if authenticated {
            guard pairedInstance != nil else { throw BrainAPIError.notPaired }
            let token: String
            do {
                guard let stored = try credentialStore.load(for: credentialAccount) else {
                    throw BrainAPIError.credentialUnavailable
                }
                token = stored
            } catch let error as BrainAPIError {
                throw error
            } catch {
                throw BrainAPIError.credentialUnavailable
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            let delegate = BrainRedirectDelegate(origin: baseURL, authorization: request.value(forHTTPHeaderField: "Authorization"))
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw BrainAPIError.timedOut
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BrainAPIError.transport
        }

        guard let http = response as? HTTPURLResponse,
              let responseURL = http.url,
              Self.sameOrigin(responseURL, baseURL) else {
            throw BrainAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(BrainPublicErrorResponse.self, from: data)
            throw BrainAPIError.http(
                status: http.statusCode,
                code: decoded?.code ?? "http_error",
                message: decoded?.message,
                requestID: http.value(forHTTPHeaderField: "X-Request-ID")
            )
        }
        do {
            return try JSONDecoder.brainDecoder().decode(Response.self, from: data)
        } catch {
            throw BrainAPIError.invalidResponse
        }
    }

    private static func validatedBaseURL(_ input: URL) -> URL? {
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        guard let url = components.url, url.port.map({ (1...65_535).contains($0) }) ?? true else {
            return nil
        }
        return url
    }

    fileprivate static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else {
            return false
        }
        func port(_ components: URLComponents) -> Int? {
            components.port ?? (components.scheme?.lowercased() == "https" ? 443 : nil)
        }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && port(left) == port(right)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    static func canonicalCaptureIdentifier(_ value: String) -> String? {
        guard let identifier = UUID(uuidString: value),
              identifier.uuidString.caseInsensitiveCompare(value) == .orderedSame else {
            return nil
        }
        let canonical = identifier.uuidString.lowercased()
        let parts = canonical.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[2].first.map({ "12345".contains($0) }) == true,
              parts[3].first.map({ "89ab".contains($0) }) == true else {
            return nil
        }
        return canonical
    }
}

private struct PairingBody: Encodable { let code: String }
private struct EmptyBody: Encodable {}
private struct ConfirmationBody: Encodable { let confirm: Bool }
private struct JobBody: Encodable {
    let kind: BrainJobKind
    let question: String?
}

final class BrainRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let authorization: String?

    init(origin: URL, authorization: String?) {
        self.origin = origin
        self.authorization = authorization
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, BrainAPIClient.sameOrigin(target, origin) else {
            completionHandler(nil)
            return
        }
        guard let authorization else {
            completionHandler(request)
            return
        }
        var authorized = request
        authorized.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(authorized)
    }
}
