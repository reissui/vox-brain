import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct BrainChatControllerTests {
    @MainActor
    @Test
    func nonemptySubmissionCreatesOneAskJobAndPollsSharedStates() async throws {
        let api = ChatJobAPISpy(
            creations: [.success(BrainJobCreated(id: "ask-1", state: .queued))],
            statuses: [
                .success(job(id: "ask-1", state: .queued)),
                .success(job(id: "ask-1", state: .running)),
                .success(job(id: "ask-1", state: .completed, output: "The answer")),
            ]
        )
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let controller = BrainChatController(
            client: api,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )

        await controller.submit("   What do I know?   ")

        let calls = await api.calls
        #expect(calls == [
            .create(kind: .ask, question: "What do I know?"),
            .status(id: "ask-1"),
            .status(id: "ask-1"),
            .status(id: "ask-1"),
        ])
        #expect(await api.statesServed == [.queued, .running, .completed])
        #expect(controller.turns.count == 1)
        #expect(controller.turns[0].jobID == "ask-1")
        #expect(controller.turns[0].jobState == .completed)
        #expect(controller.turns[0].answer == "The answer")
        #expect(defaults.data(forKey: BrainChatController.currentJobDefaultsKey) == nil)

        await controller.submit("  \n  ")
        #expect(await api.calls.count == 4)
    }

    @MainActor
    @Test
    func rendersCitationsForRemoteNavigationAndHTTPLinksExternally() throws {
        let answer = "Read [[notes/Agent Memory.md]], [the source](https://example.com/a), or https://example.org/b."

        let links = BrainChatAnswerRenderer.links(in: answer)
        let citation = try #require(links.first { $0.kind == .citation(path: "notes/Agent Memory.md") })
        #expect(citation.label == "[[notes/Agent Memory.md]]")
        #expect(citation.url.scheme == BrainChatAnswerRenderer.knowledgeScheme)
        #expect(BrainChatAnswerRenderer.citationPath(from: citation.url) == "notes/Agent Memory.md")
        #expect(links.contains { $0.url.absoluteString == "https://example.com/a" && $0.kind == .external })
        #expect(links.contains { $0.url.absoluteString == "https://example.org/b" && $0.kind == .external })

        let rendered = BrainChatAnswerRenderer.attributedAnswer(answer)
        let renderedLinks = rendered.runs.compactMap(\.link)
        #expect(renderedLinks.contains(citation.url))
        #expect(renderedLinks.contains(URL(string: "https://example.com/a")!))
        #expect(renderedLinks.contains(URL(string: "https://example.org/b")!))
    }

    @MainActor
    @Test
    func remoteKnowledgeNavigationWaitsForDestinationObserverAndDeliversOnce() async {
        let center = NotificationCenter()
        let capture = NotificationCapture()

        BrainRemoteKnowledgeNavigation.deliver(
            path: "notes/Agent Memory.md",
            center: center
        )
        #expect(capture.paths.isEmpty)

        let observer = center.addObserver(
            forName: BrainRemoteKnowledgeNavigation.notification,
            object: nil,
            queue: .main
        ) { notification in
            if let path = notification.userInfo?[BrainRemoteKnowledgeNavigation.pathKey] as? String {
                capture.append(path)
            }
        }
        defer { center.removeObserver(observer) }

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(capture.paths == ["notes/Agent Memory.md"])
    }

    @MainActor
    @Test
    func completedConversationIsBoundedMemoryAndNeverPersisted() async throws {
        let api = ChatJobAPISpy(
            creations: (1...3).map {
                .success(BrainJobCreated(id: "ask-\($0)", state: .queued))
            },
            statuses: (1...3).map {
                .success(job(id: "ask-\($0)", state: .completed, output: "answer \($0)"))
            }
        )
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let controller = BrainChatController(
            client: api,
            defaults: defaults,
            historyLimit: 2,
            pollInterval: .zero,
            sleep: { _ in }
        )

        await controller.submit("question 1")
        await controller.submit("question 2")
        await controller.submit("question 3")

        #expect(controller.turns.map(\.question) == ["question 2", "question 3"])
        #expect(controller.turns.map(\.answer) == ["answer 2", "answer 3"])
        #expect(defaults.data(forKey: BrainChatController.currentJobDefaultsKey) == nil)

        let relaunched = BrainChatController(client: api, defaults: defaults, historyLimit: 2)
        #expect(relaunched.turns.isEmpty)
    }

    @MainActor
    @Test
    func relaunchResumesOneNonterminalJobWithoutResendingQuestion() async throws {
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let interruptedAPI = ChatJobAPISpy(
            creations: [.success(BrainJobCreated(id: "ask-resume", state: .queued))],
            statuses: [
                .success(job(id: "ask-resume", state: .running)),
                .failure(BrainAPIError.transport),
            ]
        )
        let interrupted = BrainChatController(
            client: interruptedAPI,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )

        await interrupted.submit("Resume this question")

        #expect(interrupted.turns.last?.failure == .offline)
        #expect(defaults.data(forKey: BrainChatController.currentJobDefaultsKey) != nil)

        let resumedAPI = ChatJobAPISpy(
            creations: [],
            statuses: [
                .success(job(id: "ask-resume", state: .completed, output: "Resumed answer")),
            ]
        )
        let controller = BrainChatController(client: resumedAPI, defaults: defaults)

        await controller.restore()
        await controller.restore()

        #expect(await interruptedAPI.calls == [
            .create(kind: .ask, question: "Resume this question"),
            .status(id: "ask-resume"),
            .status(id: "ask-resume"),
        ])
        #expect(await resumedAPI.calls == [.status(id: "ask-resume")])
        #expect(controller.turns.count == 1)
        #expect(controller.turns[0].question == "Resume this question")
        #expect(controller.turns[0].answer == "Resumed answer")
        #expect(defaults.data(forKey: BrainChatController.currentJobDefaultsKey) == nil)
    }

    @MainActor
    @Test
    func staleNonterminalJobStopsPollingAndRemainsRetryable() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-21T12:00:00Z"))
        let api = ChatJobAPISpy(
            creations: [.success(BrainJobCreated(id: "ask-stale", state: .queued))],
            statuses: [
                .success(job(
                    id: "ask-stale",
                    state: .queued,
                    createdAt: "2026-07-21T11:49:59Z"
                )),
            ]
        )
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let controller = BrainChatController(
            client: api,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in },
            now: { now }
        )

        await controller.submit("Recover this question")

        #expect(await api.calls == [
            .create(kind: .ask, question: "Recover this question"),
            .status(id: "ask-stale"),
        ])
        #expect(controller.turns.last?.failure == .timedOut)
        #expect(controller.canRetry)
        #expect(defaults.data(forKey: BrainChatController.currentJobDefaultsKey) == nil)
    }

    @MainActor
    @Test
    func failureRetainsQuestionAndExplicitRetryCreatesFreshJob() async throws {
        let api = ChatJobAPISpy(
            creations: [
                .success(BrainJobCreated(id: "ask-failed", state: .queued)),
                .success(BrainJobCreated(id: "ask-retry", state: .queued)),
            ],
            statuses: [
                .success(job(
                    id: "ask-failed",
                    state: .failed,
                    error: "Remote Gmail connector needs attention"
                )),
                .success(job(id: "ask-retry", state: .completed, output: "Recovered answer")),
            ]
        )
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let controller = BrainChatController(
            client: api,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )

        await controller.submit("Find the email")
        #expect(controller.turns[0].question == "Find the email")
        #expect(controller.turns[0].failure == .librarian("Remote Gmail connector needs attention"))
        #expect(controller.canRetry)

        await controller.retry()

        let creates = await api.calls.filter {
            if case .create = $0 { true } else { false }
        }
        #expect(creates == [
            .create(kind: .ask, question: "Find the email"),
            .create(kind: .ask, question: "Find the email"),
        ])
        #expect(controller.turns.count == 1)
        #expect(controller.turns[0].jobID == "ask-retry")
        #expect(controller.turns[0].answer == "Recovered answer")
    }

    @MainActor
    @Test
    func revokedUnpairedOfflineAndTimeoutFailuresRemainRetryable() async throws {
        let cases: [(Error?, BrainChatFailure)] = [
            (nil, .unpaired),
            (BrainAPIError.http(status: 403, code: "device_revoked", message: nil, requestID: nil), .revoked),
            (BrainAPIError.transport, .offline),
            (BrainAPIError.timedOut, .timedOut),
        ]

        for (error, expected) in cases {
            let defaults = try testDefaults()
            defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
            let api = error.map { ChatJobAPISpy(creations: [.failure($0)], statuses: []) }
            let controller = BrainChatController(client: api, defaults: defaults)

            await controller.submit("Keep this question")

            #expect(controller.turns.last?.question == "Keep this question")
            #expect(controller.turns.last?.failure == expected)
            #expect(controller.canRetry)
        }
    }

    @MainActor
    @Test
    func chatHasZeroDirectExternalServiceCalls() async throws {
        let api = ChatJobAPISpy(
            creations: [.success(BrainJobCreated(id: "ask-only", state: .queued))],
            statuses: [.success(job(id: "ask-only", state: .completed, output: "Done"))]
        )
        let defaults = try testDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let controller = BrainChatController(
            client: api,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )

        await controller.submit("Use the remote Librarian")

        #expect(await api.calls == [
            .create(kind: .ask, question: "Use the remote Librarian"),
            .status(id: "ask-only"),
        ])
        // The deliberately narrow BrainChatJobAPI offers no Gmail, Codex,
        // Telegram, GitHub, vault, filesystem, Process, or supervision method.
        #expect(await api.directExternalServiceCalls == 0)
    }
}

private enum ChatAPICall: Equatable, Sendable {
    case create(kind: BrainJobKind, question: String?)
    case status(id: String)
}

private final class NotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.withLock { storedPaths }
    }

    func append(_ path: String) {
        lock.withLock { storedPaths.append(path) }
    }
}

private actor ChatJobAPISpy: BrainChatJobAPI {
    private var creations: [Result<BrainJobCreated, Error>]
    private var statuses: [Result<BrainJobStatus, Error>]
    private(set) var calls: [ChatAPICall] = []
    private(set) var statesServed: [BrainJobState] = []
    private(set) var directExternalServiceCalls = 0

    init(
        creations: [Result<BrainJobCreated, Error>],
        statuses: [Result<BrainJobStatus, Error>]
    ) {
        self.creations = creations
        self.statuses = statuses
    }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        calls.append(.create(kind: kind, question: question))
        guard !creations.isEmpty else { throw BrainAPIError.invalidResponse }
        return try creations.removeFirst().get()
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        calls.append(.status(id: id))
        guard !statuses.isEmpty else { throw BrainAPIError.invalidResponse }
        let status = try statuses.removeFirst().get()
        statesServed.append(status.state)
        return status
    }
}

private func job(
    id: String,
    state: BrainJobState,
    output: String? = nil,
    error: String? = nil,
    createdAt: String = ISO8601DateFormatter().string(from: Date())
) -> BrainJobStatus {
    BrainJobStatus(
        id: id,
        kind: .ask,
        state: state,
        output: output,
        error: error,
        detail: nil,
        truncated: false,
        createdAt: createdAt,
        startedAt: state == .queued ? nil : "2026-07-15T10:00:01.000Z",
        finishedAt: state == .completed || state == .failed ? "2026-07-15T10:00:02.000Z" : nil,
        updatedAt: createdAt
    )
}

private func testDefaults() throws -> UserDefaults {
    let suite = "BrainChatControllerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw BrainAPIError.invalidResponse
    }
    defaults.set(suite, forKey: "test-suite-name")
    return defaults
}

private func defaultsSuite(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "test-suite-name") ?? "BrainChatControllerTests"
}
