import Foundation

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

struct BrainHealthProbeResponse: Codable, Equatable, Sendable {
    let ok: Bool
}
