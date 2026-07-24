import Foundation

struct MacMiniRecoveryCommand: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let command: String
}

enum BrainPrivateSiteURL {
    static let maximumUTF8Bytes = 2_048

    static func validated(_ value: String) -> URL? {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value > 0x7e
              }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url,
              url.absoluteString == value else {
            return nil
        }
        return url
    }
}

enum BrainDeviceScope: String, Codable, CaseIterable, Sendable {
    case capture
    case read
    case control
}

struct BrainInstanceMetadata: Codable, Equatable, Sendable {
    let baseURL: URL
    let instanceID: String
    let deviceID: String
    let deviceName: String
    let scopes: [BrainDeviceScope]

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case instanceID = "instance_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case scopes
    }
}

struct BrainPairingClaim: Decodable, Equatable, Sendable {
    let instanceID: String
    let deviceID: String
    let deviceName: String
    let scopes: [BrainDeviceScope]
    let token: String

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case scopes
        case token
    }
}

struct BrainKnowledgeSearchResponse: Codable, Equatable, Sendable {
    let query: String
    let results: [BrainKnowledgeSearchResult]
}

struct BrainKnowledgeDocumentsResponse: Codable, Equatable, Sendable {
    let documents: [BrainKnowledgeListItem]
}

struct BrainKnowledgeListItem: Codable, Equatable, Identifiable, Sendable {
    let title: String
    let path: String

    var id: String { path }
}

struct BrainKnowledgeSearchResult: Codable, Equatable, Identifiable, Sendable {
    let title: String
    let path: String
    let snippet: String

    var id: String { path }
}

struct BrainKnowledgeDocument: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let title: String
    let content: String

    var id: String { path }
}

enum BrainJobKind: String, Codable, CaseIterable, Sendable {
    case ask
    case process
    case digest
}

enum BrainJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct BrainJobCreated: Codable, Equatable, Sendable {
    let id: String
    let state: BrainJobState
}

struct BrainJobStatus: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: BrainJobKind
    let state: BrainJobState
    let output: String?
    let error: String?
    let detail: String?
    let truncated: Bool?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case state
        case output
        case error
        case detail
        case truncated
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
    }
}

enum BrainCaptureType: String, Codable, CaseIterable, Sendable {
    case video
    case tweet
    case article
    case design
    case note
    case transcript
}

struct BrainCaptureRequest: Codable, Equatable, Sendable {
    let type: BrainCaptureType?
    let url: String?
    let text: String?
    let note: String?
    let source: String?
    let image: String?
    let transcript: String?
    let title: String?
    let entity: String?

    init(
        type: BrainCaptureType? = nil,
        url: String? = nil,
        text: String? = nil,
        note: String? = nil,
        source: String? = nil,
        image: String? = nil,
        transcript: String? = nil,
        title: String? = nil,
        entity: String? = nil
    ) {
        self.type = type
        self.url = url
        self.text = text
        self.note = note
        self.source = source
        self.image = image
        self.transcript = transcript
        self.title = title
        self.entity = entity
    }
}

enum BrainCaptureState: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case delivered
    case failed
}

struct BrainCaptureReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let state: String
}

struct BrainCaptureStatus: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: BrainCaptureType?
    let source: String?
    let state: BrainCaptureState
    let retryable: Bool
    let error: String?
    let createdAt: Date
    let updatedAt: Date
    let deliveredAt: Date?
    let object: BrainCaptureObjectMetadata?

    init(
        id: String,
        type: BrainCaptureType? = nil,
        source: String? = nil,
        state: BrainCaptureState,
        retryable: Bool,
        error: String?,
        createdAt: Date,
        updatedAt: Date,
        deliveredAt: Date?,
        object: BrainCaptureObjectMetadata? = nil
    ) {
        self.id = id
        self.type = type
        self.source = source
        self.state = state
        self.retryable = retryable
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deliveredAt = deliveredAt
        self.object = object
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case source
        case state
        case retryable
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deliveredAt = "delivered_at"
        case object
    }
}

struct BrainCaptureObjectMetadata: Codable, Equatable, Sendable {
    let sha256: String
    let contentType: String
    let byteLength: Int
    let filename: String
    let retention: String
    let href: String

    enum CodingKeys: String, CodingKey {
        case sha256
        case contentType = "content_type"
        case byteLength = "byte_length"
        case filename
        case retention
        case href
    }
}

struct BrainCaptureListResponse: Codable, Equatable, Sendable {
    let captures: [BrainCaptureStatus]
}

struct BrainGmailAuthorization: Codable, Equatable, Sendable {
    let authorizationURL: URL

    enum CodingKeys: String, CodingKey {
        case authorizationURL = "authorization_url"
    }
}

enum BrainGmailConnectionState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case connected
    case reconnectRequired = "reconnect_required"
    case denied
    case expired
    case originUnavailable = "origin_unavailable"
}

struct BrainGmailStatus: Codable, Equatable, Sendable {
    let status: BrainGmailConnectionState
    let account: String?
}

struct BrainGmailDisconnectResponse: Codable, Equatable, Sendable {
    let status: BrainGmailConnectionState
}

struct BrainDeviceRevokeResponse: Codable, Equatable, Sendable {
    let revoked: Bool
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case revoked
        case deviceID = "device_id"
    }
}

struct BrainHealthProbeResponse: Codable, Equatable, Sendable {
    let ok: Bool
}

struct BrainDisconnectResult: Equatable, Sendable {
    let remoteRevoked: Bool
    let localCredentialRemoved: Bool
}

struct BrainPublicErrorResponse: Decodable, Equatable, Sendable {
    let code: String
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case error
    }

    private struct Detail: Decodable {
        let code: String
        let message: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let simple = try? container.decode(String.self, forKey: .error) {
            code = simple
            message = nil
            return
        }
        let detail = try container.decode(Detail.self, forKey: .error)
        code = detail.code
        message = detail.message
    }
}

enum BrainAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidRequest
    case notPaired
    case credentialUnavailable
    case transport
    case timedOut
    case invalidResponse
    case http(status: Int, code: String, message: String?, requestID: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter the HTTPS address of a Brain instance."
        case .invalidRequest:
            "The Brain request is invalid."
        case .notPaired:
            "Pair this Mac with Brain first."
        case .credentialUnavailable:
            "The Brain device credential is unavailable. Pair this Mac again."
        case .transport:
            "Could not reach Brain."
        case .timedOut:
            "Brain did not respond in time."
        case .invalidResponse:
            "Brain returned an invalid response."
        case .http(let status, let code, let message, _):
            message ?? "Brain request failed (\(status), \(code))."
        }
    }
}
