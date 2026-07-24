import Foundation

enum BrainOverallState: String, Codable, CaseIterable, Sendable {
    case healthy
    case activity
    case warning
    case failure
}

enum BrainCheckState: String, Codable, CaseIterable, Sendable {
    case pass
    case activity
    case warning
    case failure
}

enum BrainVaultState: String, Codable, CaseIterable, Sendable {
    case clean
    case activity
    case warning
}

struct BrainReportFreshness: Equatable, Sendable {
    static let fresh = BrainReportFreshness()

    let isStale: Bool
    let snapshotAt: Date?
    let ageSeconds: Int?

    init(
        isStale: Bool = false,
        snapshotAt: Date? = nil,
        ageSeconds: Int? = nil
    ) {
        self.isStale = isStale
        self.snapshotAt = snapshotAt
        self.ageSeconds = ageSeconds
    }
}

struct BrainStatusReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let vault: BrainVaultStatus
    let counts: BrainContentCounts
    let lastRun: BrainLastRun?
    let services: [BrainServiceStatus]
    let siteURL: URL?
    let freshness: BrainReportFreshness

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case vault
        case counts
        case lastRun = "last_run"
        case services
        case siteURL = "site_url"
        case stale
        case ageSeconds = "age_seconds"
        case snapshotAt = "snapshot_at"
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        vault: BrainVaultStatus,
        counts: BrainContentCounts,
        lastRun: BrainLastRun?,
        services: [BrainServiceStatus],
        siteURL: URL? = nil,
        freshness: BrainReportFreshness = .fresh
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.vault = vault
        self.counts = counts
        self.lastRun = lastRun
        self.services = services
        self.siteURL = siteURL.flatMap { BrainPrivateSiteURL.validated($0.absoluteString) }
        self.freshness = freshness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        vault = try container.decode(BrainVaultStatus.self, forKey: .vault)
        counts = try container.decode(BrainContentCounts.self, forKey: .counts)
        lastRun = try container.decodeIfPresent(BrainLastRun.self, forKey: .lastRun)
        services = try container.decode([BrainServiceStatus].self, forKey: .services)
        let rawSiteURL = try? container.decode(String.self, forKey: .siteURL)
        siteURL = rawSiteURL.flatMap(BrainPrivateSiteURL.validated)
        freshness = BrainReportFreshness(
            isStale: try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false,
            snapshotAt: try container.decodeIfPresent(Date.self, forKey: .snapshotAt),
            ageSeconds: try container.decodeIfPresent(Int.self, forKey: .ageSeconds)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(vault, forKey: .vault)
        try container.encode(counts, forKey: .counts)
        try container.encodeIfPresent(lastRun, forKey: .lastRun)
        try container.encode(services, forKey: .services)
        try container.encodeIfPresent(siteURL?.absoluteString, forKey: .siteURL)
        if freshness.isStale {
            try container.encode(true, forKey: .stale)
            try container.encodeIfPresent(freshness.ageSeconds, forKey: .ageSeconds)
            try container.encodeIfPresent(freshness.snapshotAt, forKey: .snapshotAt)
        }
    }
}

struct BrainVaultStatus: Codable, Equatable, Sendable {
    let path: String
    let state: BrainVaultState
    let dirtyPaths: Int

    enum CodingKeys: String, CodingKey {
        case path
        case state
        case dirtyPaths = "dirty_paths"
    }
}

struct BrainContentCounts: Codable, Equatable, Sendable {
    let inbox: Int
    let sources: Int
    let notes: Int
    let people: Int
    let projects: Int
}

struct BrainLastRun: Codable, Equatable, Sendable {
    let at: Date
    let commit: String?
    let summary: String
}

struct BrainServiceStatus: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let configured: Bool
    let running: Bool
    let detail: String
}

struct BrainHealthReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let overall: BrainOverallState
    let counts: BrainHealthCounts
    let checks: [BrainHealthCheck]
    let operations: BrainAgentOperations?
    let freshness: BrainReportFreshness

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case overall
        case counts
        case checks
        case operations
        case stale
        case ageSeconds = "age_seconds"
        case snapshotAt = "snapshot_at"
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        overall: BrainOverallState,
        counts: BrainHealthCounts,
        checks: [BrainHealthCheck],
        operations: BrainAgentOperations? = nil,
        freshness: BrainReportFreshness = .fresh
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.overall = overall
        self.counts = counts
        self.checks = checks
        self.operations = operations
        self.freshness = freshness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        overall = try container.decode(BrainOverallState.self, forKey: .overall)
        counts = try container.decode(BrainHealthCounts.self, forKey: .counts)
        checks = try container.decode([BrainHealthCheck].self, forKey: .checks)
        operations = try container.decodeIfPresent(BrainAgentOperations.self, forKey: .operations)
        freshness = BrainReportFreshness(
            isStale: try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false,
            snapshotAt: try container.decodeIfPresent(Date.self, forKey: .snapshotAt),
            ageSeconds: try container.decodeIfPresent(Int.self, forKey: .ageSeconds)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(overall, forKey: .overall)
        try container.encode(counts, forKey: .counts)
        try container.encode(checks, forKey: .checks)
        try container.encodeIfPresent(operations, forKey: .operations)
        if freshness.isStale {
            try container.encode(true, forKey: .stale)
            try container.encodeIfPresent(freshness.ageSeconds, forKey: .ageSeconds)
            try container.encodeIfPresent(freshness.snapshotAt, forKey: .snapshotAt)
        }
    }
}

struct BrainAgentOperations: Codable, Equatable, Sendable {
    let lastSuccessfulPoll: Date?
    let pollAgeSeconds: Int?
    let backlogCount: Int
    let oldestBacklogAgeSeconds: Int?
    let process: BrainAgentProcessProgress
    let automation: BrainAutomationProgress
    let launchd: BrainLaunchdStates

    enum CodingKeys: String, CodingKey {
        case lastSuccessfulPoll = "last_successful_poll"
        case pollAgeSeconds = "poll_age_seconds"
        case backlogCount = "backlog_count"
        case oldestBacklogAgeSeconds = "oldest_backlog_age_seconds"
        case process, automation, launchd
    }
}

struct BrainAgentProcessProgress: Codable, Equatable, Sendable {
    let state: String
    let label: String?
    let startedAt: Date?
    let progressAgeSeconds: Int?
    let declaredBoundSeconds: Int

    enum CodingKeys: String, CodingKey {
        case state, label
        case startedAt = "started_at"
        case progressAgeSeconds = "progress_age_seconds"
        case declaredBoundSeconds = "declared_bound_seconds"
    }
}

struct BrainAutomationProgress: Codable, Equatable, Sendable {
    let lastProgressAt: Date?
    let progressAgeSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case lastProgressAt = "last_progress_at"
        case progressAgeSeconds = "progress_age_seconds"
    }
}

struct BrainLaunchdStates: Codable, Equatable, Sendable {
    let agent: String
    let automation: String
}

struct BrainHealthCounts: Codable, Equatable, Sendable {
    let pass: Int
    let activity: Int
    let warning: Int
    let failure: Int
}

struct BrainHealthCheck: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let scope: String
    let state: BrainCheckState
    let summary: String
    let detail: String
    let remediation: String?
}

struct BrainSnapshot: Equatable, Sendable {
    let status: BrainStatusReport
    let health: BrainHealthReport
    let refreshedAt: Date
    var isStale: Bool
}

extension JSONDecoder {
    static func brainDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
