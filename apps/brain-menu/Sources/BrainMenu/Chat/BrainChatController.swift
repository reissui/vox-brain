import Foundation
import Observation

protocol BrainChatJobAPI: Sendable {
    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated
    func jobStatus(id: String) async throws -> BrainJobStatus
}

extension BrainAPIClient: BrainChatJobAPI {}

enum BrainChatFailure: Equatable, Sendable {
    case unpaired
    case revoked
    case offline
    case timedOut
    case librarian(String)

    var title: String {
        switch self {
        case .unpaired:
            "Brain is not paired"
        case .revoked:
            "Pairing was revoked"
        case .offline:
            "Brain is offline"
        case .timedOut:
            "Brain timed out"
        case .librarian:
            "The Librarian could not answer"
        }
    }

    var detail: String {
        switch self {
        case .unpaired:
            "Finish configuring Brain, then retry."
        case .revoked:
            "Pair this Mac again, then retry the question."
        case .offline:
            "The Brain vault could not be reached."
        case .timedOut:
            "Brain did not respond in time."
        case .librarian(let detail):
            detail
        }
    }
}

struct BrainChatTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    fileprivate(set) var jobID: String?
    fileprivate(set) var jobState: BrainJobState?
    fileprivate(set) var answer: String?
    fileprivate(set) var failure: BrainChatFailure?

    fileprivate init(question: String) {
        id = UUID()
        self.question = question
    }
}

enum BrainChatLinkKind: Equatable, Sendable {
    case citation(path: String)
    case external
}

struct BrainChatLink: Equatable, Sendable {
    let label: String
    let url: URL
    let kind: BrainChatLinkKind
}

enum BrainChatAnswerRenderer {
    static let knowledgeScheme = "brain-wikilink"

    static func navigationURL(forPath path: String) -> URL? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = knowledgeScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: path)]
        return components.url
    }

    static func citationTarget(from url: URL) -> String? {
        guard url.scheme?.lowercased() == knowledgeScheme,
              url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
              !target.isEmpty else {
            return nil
        }
        return target
    }

    static func citationPath(from url: URL) -> String? {
        citationTarget(from: url)
    }

    static func links(in answer: String) -> [BrainChatLink] {
        var links: [BrainChatLink] = []
        let source = answer as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        if let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#) {
            for match in expression.matches(in: answer, range: fullRange) {
                guard match.numberOfRanges == 2 else { continue }
                let label = source.substring(with: match.range(at: 1))
                let path = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = navigationURL(forPath: path) else { continue }
                links.append(BrainChatLink(label: "[[\(label)]]", url: url, kind: .citation(path: path)))
            }
        }

        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            for match in detector.matches(in: answer, range: fullRange) {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    continue
                }
                links.append(BrainChatLink(
                    label: source.substring(with: match.range),
                    url: url,
                    kind: .external
                ))
            }
        }

        return links
    }

    static func attributedAnswer(_ answer: String) -> AttributedString {
        let source = answer as NSString
        var markdown = answer
        if let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#) {
            let matches = expression.matches(
                in: answer,
                range: NSRange(location: 0, length: source.length)
            )
            for match in matches.reversed() {
                let label = source.substring(with: match.range(at: 1))
                let path = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = navigationURL(forPath: path),
                      let range = Range(match.range, in: markdown) else {
                    continue
                }
                let escapedLabel = label
                    .replacingOccurrences(of: #"\"#, with: #"\\"#)
                    .replacingOccurrences(of: "[", with: #"\["#)
                    .replacingOccurrences(of: "]", with: #"\]"#)
                markdown.replaceSubrange(
                    range,
                    with: #"[\[\#(escapedLabel)\]\]](\#(url.absoluteString))"#
                )
            }
        }

        var attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(answer)

        // Foundation's inline Markdown parser handles labelled HTTP links. Make
        // bare HTTP(S) URLs links too while leaving every other URL scheme inert.
        for link in links(in: answer) where link.kind == .external {
            var search = attributed.startIndex..<attributed.endIndex
            while let range = attributed[search].range(of: link.label) {
                attributed[range].link = link.url
                guard range.upperBound < attributed.endIndex else { break }
                search = range.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }
}

@MainActor
@Observable
final class BrainChatController {
    static let currentJobDefaultsKey = "brain.chat.current-job"
    static let defaultHistoryLimit = 20
    static let defaultPollInterval: Duration = .seconds(1)
    static let maximumNonterminalAge: TimeInterval = 10 * 60

    private(set) var turns: [BrainChatTurn] = []
    private(set) var isSubmitting = false
    private(set) var isPolling = false

    @ObservationIgnored private let client: (any BrainChatJobAPI)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyLimit: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var activeTurnID: UUID?
    @ObservationIgnored private var didRestore = false

    var currentTurn: BrainChatTurn? {
        guard let activeTurnID else { return turns.last }
        return turns.first(where: { $0.id == activeTurnID })
    }

    var isWorking: Bool { isSubmitting || isPolling }
    var canRetry: Bool { !isWorking && currentTurn?.failure != nil }

    init(
        client: (any BrainChatJobAPI)? = nil,
        defaults: UserDefaults = .standard,
        historyLimit: Int = BrainChatController.defaultHistoryLimit,
        pollInterval: Duration = BrainChatController.defaultPollInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.client = client ?? Self.persistedAPIClient(defaults: defaults)
        self.historyLimit = max(1, historyLimit)
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    func submit(_ text: String) async {
        guard !isWorking else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        clearPersistedJob()
        let turn = BrainChatTurn(question: question)
        activeTurnID = turn.id
        turns.append(turn)
        boundHistory()
        await createAndMonitorJob(for: turn.id, question: question)
    }

    func retry() async {
        guard canRetry, let turn = currentTurn else { return }
        clearPersistedJob()
        await createAndMonitorJob(for: turn.id, question: turn.question)
    }

    func restore() async {
        guard !didRestore, !isWorking else { return }
        didRestore = true
        guard let saved = loadPersistedJob() else { return }

        let turn = BrainChatTurn(question: saved.question)
        activeTurnID = turn.id
        turns.append(turn)
        boundHistory()
        updateTurn(id: turn.id) {
            $0.jobID = saved.jobID
            $0.jobState = saved.state
        }
        await monitorJob(id: saved.jobID, turnID: turn.id)
    }

    func attributedAnswer(for turn: BrainChatTurn) -> AttributedString? {
        turn.answer.map(BrainChatAnswerRenderer.attributedAnswer)
    }

    private func createAndMonitorJob(for turnID: UUID, question: String) async {
        updateTurn(id: turnID) {
            $0.jobID = nil
            $0.jobState = nil
            $0.answer = nil
            $0.failure = nil
        }
        activeTurnID = turnID
        isSubmitting = true
        defer { isSubmitting = false }

        guard let client else {
            markFailure(.unpaired, turnID: turnID)
            return
        }

        do {
            let created = try await client.createJob(kind: .ask, question: question)
            updateTurn(id: turnID) {
                $0.jobID = created.id
                $0.jobState = created.state
            }
            if created.state == .queued || created.state == .running {
                persist(jobID: created.id, question: question, state: created.state)
            }
            isSubmitting = false
            await monitorJob(id: created.id, turnID: turnID)
        } catch is CancellationError {
            return
        } catch {
            markFailure(Self.failure(for: error), turnID: turnID)
        }
    }

    private func monitorJob(id: String, turnID: UUID) async {
        guard let client else {
            markFailure(.unpaired, turnID: turnID)
            return
        }
        isPolling = true
        defer { isPolling = false }

        do {
            while !Task.isCancelled {
                let status = try await client.jobStatus(id: id)
                guard status.id == id, status.kind == .ask else {
                    throw BrainAPIError.invalidResponse
                }
                if status.state == .queued || status.state == .running {
                    guard let createdAt = Self.date(from: status.createdAt) else {
                        throw BrainAPIError.invalidResponse
                    }
                    if now().timeIntervalSince(createdAt) >= Self.maximumNonterminalAge {
                        markFailure(.timedOut, turnID: turnID)
                        clearPersistedJob()
                        return
                    }
                }
                updateTurn(id: turnID) {
                    $0.jobState = status.state
                    $0.failure = nil
                    if status.state == .completed {
                        $0.answer = status.output ?? ""
                    }
                }

                switch status.state {
                case .queued, .running:
                    persist(jobID: id, question: question(for: turnID), state: status.state)
                    try await sleep(pollInterval)
                case .completed:
                    clearPersistedJob()
                    activeTurnID = nil
                    return
                case .failed:
                    let detail = status.error ?? status.detail ?? "The ask job failed."
                    markFailure(.librarian(detail), turnID: turnID)
                    clearPersistedJob()
                    return
                case .cancelled:
                    markFailure(.librarian("The ask job was cancelled."), turnID: turnID)
                    clearPersistedJob()
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // The server-side job may still be running. Its last nonterminal
            // identity stays persisted so a relaunch resumes polling, while an
            // explicit retry deliberately replaces it with a fresh ask job.
            markFailure(Self.failure(for: error), turnID: turnID)
        }
    }

    private func markFailure(_ failure: BrainChatFailure, turnID: UUID) {
        updateTurn(id: turnID) {
            $0.jobState = .failed
            $0.failure = failure
        }
        activeTurnID = turnID
    }

    private func updateTurn(id: UUID, _ update: (inout BrainChatTurn) -> Void) {
        guard let index = turnIndex(id: id) else { return }
        update(&turns[index])
    }

    private func question(for turnID: UUID) -> String {
        turns.first(where: { $0.id == turnID })?.question ?? ""
    }

    private func turnIndex(id: UUID) -> Int? {
        turns.firstIndex(where: { $0.id == id })
    }

    private func boundHistory() {
        if turns.count > historyLimit {
            turns.removeFirst(turns.count - historyLimit)
        }
    }

    private func persist(jobID: String, question: String, state: BrainJobState) {
        guard !jobID.isEmpty, !question.isEmpty, state == .queued || state == .running,
              let data = try? JSONEncoder().encode(
                PersistedJob(jobID: jobID, question: question, state: state)
              ) else {
            return
        }
        defaults.set(data, forKey: Self.currentJobDefaultsKey)
    }

    private func loadPersistedJob() -> PersistedJob? {
        guard let data = defaults.data(forKey: Self.currentJobDefaultsKey),
              let saved = try? JSONDecoder().decode(PersistedJob.self, from: data),
              !saved.jobID.isEmpty,
              !saved.question.isEmpty,
              saved.state == .queued || saved.state == .running else {
            clearPersistedJob()
            return nil
        }
        return saved
    }

    private func clearPersistedJob() {
        defaults.removeObject(forKey: Self.currentJobDefaultsKey)
    }

    private static func date(from timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }

    private static func persistedAPIClient(defaults: UserDefaults) -> (any BrainChatJobAPI)? {
        BrainRuntime.chatClient(defaults: defaults)
    }

    private static func failure(for error: Error) -> BrainChatFailure {
        guard let apiError = error as? BrainAPIError else {
            return .librarian(error.localizedDescription)
        }
        switch apiError {
        case .notPaired:
            return .unpaired
        case .credentialUnavailable:
            return .revoked
        case .transport:
            return .offline
        case .timedOut:
            return .timedOut
        case .http(let status, let code, let message, _):
            let normalizedCode = code.lowercased()
            if status == 401 || status == 403
                || normalizedCode.contains("revoked")
                || normalizedCode.contains("credential") {
                return .revoked
            }
            return .librarian(message ?? "Brain request failed (\(status), \(code)).")
        case .invalidBaseURL, .invalidRequest, .invalidResponse:
            return .librarian(apiError.localizedDescription)
        }
    }
}

private struct PersistedJob: Codable {
    let jobID: String
    let question: String
    let state: BrainJobState
}
