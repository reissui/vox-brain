import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct RemoteBrainControllerTests {
    @Test
    func confirmationCreatesOnlyExactProcessAndDigestJobsAndShowsEveryTransition() async throws {
        let process = "job-process"
        let digest = "job-digest"
        let api = RemoteJobAPI(plans: [
            process: [
                job(process, kind: .process, state: .queued),
                job(process, kind: .process, state: .running),
                job(process, kind: .process, state: .completed, output: "processed\n"),
            ],
            digest: [
                job(digest, kind: .digest, state: .queued),
                job(digest, kind: .digest, state: .running),
                job(digest, kind: .digest, state: .completed, output: "digest\n"),
            ],
        ])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }

        #expect(fixture.controller.request(.process) == .confirmationRequired(.process))
        #expect(await api.createdKinds.isEmpty)
        let processResult = await fixture.controller.confirmPendingAction()

        #expect(processResult == .completed(job(
            process, kind: .process, state: .completed, output: "processed\n"
        )))
        #expect(fixture.controller.observedStates == [.queued, .running, .completed])
        #expect(fixture.controller.output == RemoteBrainOutput(
            standardOutput: "processed\n", standardError: "", isTruncated: false
        ))

        #expect(fixture.controller.request(.digest) == .confirmationRequired(.digest))
        #expect(await fixture.controller.confirmPendingAction() == .completed(job(
            digest, kind: .digest, state: .completed, output: "digest\n"
        )))
        #expect(await api.createdKinds == [.process, .digest])
        #expect(await api.createdQuestions == [nil, nil])
        #expect(await api.polledIDs == [process, process, process, digest, digest, digest])
        #expect(fixture.refresher.count == 2)
    }

    @Test
    func onlyOneMutationCanBeSubmittedWhileAJobIsNonterminal() async throws {
        let api = BlockingRemoteJobAPI()
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }

        #expect(fixture.controller.request(.process) == .confirmationRequired(.process))
        let first = Task { await fixture.controller.confirmPendingAction() }
        for _ in 0..<1_000 where !(await api.isWaiting) {
            await Task.yield()
        }
        #expect(await api.isWaiting)

        let recreatedViewController = RemoteBrainController(
            api: api,
            defaults: fixture.defaults,
            sleep: { _ in },
            refresh: {}
        )
        #expect(recreatedViewController.request(.digest) == .rejected(
            RemoteBrainController.concurrentMutationMessage
        ))
        #expect(await api.createCount == 1)

        await api.releaseCreation()
        #expect(await first.value == .completed(job(
            "job-blocked", kind: .process, state: .completed, output: "done"
        )))
        #expect(await api.createCount == 1)
    }

    @Test
    func relaunchResumesPersistedNonterminalIDWithoutResubmitting() async throws {
        let id = "job-resume"
        let api = RemoteJobAPI(plans: [
            id: [
                job(id, kind: .digest, state: .running),
                job(id, kind: .digest, state: .completed, output: "resumed"),
            ],
        ])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }
        fixture.defaults.set(id, forKey: RemoteBrainController.activeJobDefaultsKey)
        fixture.defaults.set("not-a-credential", forKey: "unrelated")

        let relaunched = RemoteBrainController(
            api: api,
            defaults: fixture.defaults,
            sleep: { _ in },
            refresh: { fixture.refresher.refresh() }
        )
        await relaunched.refresh()

        #expect(await api.createdKinds.isEmpty)
        #expect(await api.polledIDs == [id, id])
        #expect(relaunched.observedStates == [.running, .completed])
        #expect(relaunched.displayedState == .completed)
        #expect(fixture.defaults.string(forKey: RemoteBrainController.activeJobDefaultsKey) == nil)
        #expect(fixture.defaults.string(forKey: RemoteBrainController.lastJobDefaultsKey) == id)
        #expect(fixture.refresher.count == 1)
        #expect(fixture.defaults.dictionaryRepresentation().values.contains {
            String(describing: $0).contains("Bearer ")
        } == false)
    }

    @Test
    func terminalRefreshRunsOnceAcrossRepeatedRefreshAndRelaunch() async throws {
        let id = "job-terminal"
        let terminal = job(id, kind: .process, state: .completed, output: "done")
        let api = RemoteJobAPI(plans: [id: [terminal, terminal, terminal]])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }
        fixture.defaults.set(id, forKey: RemoteBrainController.activeJobDefaultsKey)

        await fixture.controller.refresh()
        await fixture.controller.refresh()
        let relaunched = RemoteBrainController(
            api: api,
            defaults: fixture.defaults,
            sleep: { _ in },
            refresh: { fixture.refresher.refresh() }
        )
        await relaunched.refresh()

        #expect(fixture.refresher.count == 1)
        #expect(await api.createdKinds.isEmpty)
    }

    @Test
    func terminalJobRefreshesTheComposedVisibleBrainStore() async throws {
        let api = DashboardRefreshAPI()
        let store = BrainStore(client: api)
        await store.refresh()
        #expect(store.status?.counts.inbox == 1)

        let suite = "RemoteBrainControllerTests.Composed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RemoteBrainController(
            api: api,
            defaults: defaults,
            sleep: { _ in },
            refresh: { await store.refresh() }
        )

        #expect(controller.request(.process) == .confirmationRequired(.process))
        _ = await controller.confirmPendingAction()

        #expect(store.status?.counts.inbox == 0)
        #expect(await api.statusCalls == 2)
    }

    @Test
    func boundsSeparatedOutputAndPreservesExactPublicFailureRemediation() async throws {
        let id = "job-failed"
        let stdout = String(repeating: "ø", count: RemoteBrainController.maximumStandardOutputBytes)
        let remediation = "Reconnect the remote Librarian, then retry this job."
        let api = RemoteJobAPI(plans: [
            id: [job(
                id,
                kind: .process,
                state: .failed,
                output: stdout,
                error: "action_failed",
                detail: remediation
            )],
        ])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }

        _ = fixture.controller.request(.process)
        #expect(await fixture.controller.confirmPendingAction() == .completed(job(
            id,
            kind: .process,
            state: .failed,
            output: stdout,
            error: "action_failed",
            detail: remediation
        )))

        let output = try #require(fixture.controller.output)
        #expect(output.standardOutput.utf8.count <= RemoteBrainController.maximumStandardOutputBytes)
        #expect(output.standardError == remediation)
        #expect(output.isTruncated)
        #expect(fixture.controller.publicFailure == RemoteBrainFailure(
            code: "action_failed", remediation: remediation
        ))
        #expect(output.standardOutput.contains(remediation) == false)
    }

    @Test(arguments: [BrainJobState.cancelled, .failed])
    func displaysEveryNonSuccessTerminalState(_ state: BrainJobState) async throws {
        let id = "job-\(state.rawValue)"
        let terminal = job(
            id,
            kind: .digest,
            state: state,
            error: state == .failed ? "job_failed" : nil,
            detail: state == .failed ? "Retry later." : nil
        )
        let api = RemoteJobAPI(plans: [id: [terminal]])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }

        _ = fixture.controller.request(.digest)
        _ = await fixture.controller.confirmPendingAction()

        #expect(fixture.controller.displayedState == state)
        #expect(fixture.controller.isMutating == false)
    }

    @Test
    func typedBoundaryHasNoLocalExecutionOrRemoteMachineInputSurface() async throws {
        #expect(RemoteBrainAction.allCases == [.process, .digest])

        let api = RemoteJobAPI(plans: [:])
        let fixture = makeController(api: api)
        defer { fixture.cleanup() }
        await fixture.controller.refresh()
        #expect(await api.probeCount == 1)
        #expect(await api.createdKinds.isEmpty)

        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativeSources = [
            "Sources/BrainMenu/Operations/RemoteBrainController.swift",
            "Sources/BrainMenu/Views/ActionsView.swift",
            "Sources/BrainMenu/Views/MacMiniView.swift",
        ]
        for relative in relativeSources {
            let source = try String(contentsOf: package.appending(path: relative), encoding: .utf8)
            #expect(source.contains("ProcessCommandExecutor") == false)
            #expect(source.contains("MacMiniClient") == false)
            #expect(source.contains("/usr/bin/ssh") == false)
            #expect(source.contains("Process(") == false)
            #expect(source.contains("executableURL") == false)
        }

        let dashboard = try String(
            contentsOf: package.appending(path: "Sources/BrainMenu/Views/DashboardView.swift"),
            encoding: .utf8
        )
        #expect(dashboard.contains("SettingsView("))
        let settings = try String(
            contentsOf: package.appending(path: "Sources/BrainMenu/Views/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(!settings.contains("ActionsView(store: store)"))
        #expect(!settings.contains("MacMiniView(store: store)"))
        #expect(!settings.contains("Section(\"Remote\")"))
    }
}

@MainActor
private final class RefreshCounter: Sendable {
    private(set) var count = 0

    func refresh() {
        count += 1
    }
}

private actor RemoteJobAPI: RemoteBrainJobAPI {
    nonisolated let pairedInstance: BrainInstanceMetadata? = testPairedInstance

    private var plans: [String: [BrainJobStatus]]
    private var planOrder: [String]
    private var nextPlan = 0
    private var offsets: [String: Int] = [:]
    private(set) var createdKinds: [BrainJobKind] = []
    private(set) var createdQuestions: [String?] = []
    private(set) var polledIDs: [String] = []
    private(set) var probeCount = 0

    init(plans: [String: [BrainJobStatus]]) {
        self.plans = plans
        planOrder = plans.keys.sorted()
        if plans.keys.contains("job-process"), plans.keys.contains("job-digest") {
            planOrder = ["job-process", "job-digest"]
        }
    }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        createdKinds.append(kind)
        createdQuestions.append(question)
        guard nextPlan < planOrder.count else { throw BrainAPIError.invalidResponse }
        let id = planOrder[nextPlan]
        nextPlan += 1
        return BrainJobCreated(id: id, state: .queued)
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        polledIDs.append(id)
        guard let statuses = plans[id], !statuses.isEmpty else {
            throw BrainAPIError.invalidResponse
        }
        let offset = offsets[id, default: 0]
        offsets[id] = offset + 1
        return statuses[min(offset, statuses.count - 1)]
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        probeCount += 1
        return BrainHealthProbeResponse(ok: true)
    }
}

private actor BlockingRemoteJobAPI: RemoteBrainJobAPI {
    nonisolated let pairedInstance: BrainInstanceMetadata? = testPairedInstance

    private(set) var createCount = 0
    private(set) var isWaiting = false
    private var pollCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        createCount += 1
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
        return BrainJobCreated(id: "job-blocked", state: .queued)
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        pollCount += 1
        return job(id, kind: .process, state: .completed, output: "done")
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        BrainHealthProbeResponse(ok: true)
    }

    func releaseCreation() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

private actor DashboardRefreshAPI: RemoteBrainJobAPI, BrainStatusAPI {
    nonisolated let pairedInstance: BrainInstanceMetadata? = testPairedInstance

    private(set) var statusCalls = 0
    private var didProcess = false

    func status() async throws -> BrainStatusReport {
        statusCalls += 1
        let generatedAt = Date(timeIntervalSince1970: 1_784_112_400)
        return BrainStatusReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            vault: BrainVaultStatus(path: "remote", state: .clean, dirtyPaths: 0),
            counts: BrainContentCounts(
                inbox: didProcess ? 0 : 1,
                sources: 8,
                notes: 7,
                people: 6,
                projects: 5
            ),
            lastRun: nil,
            services: []
        )
    }

    func health() async throws -> BrainHealthReport {
        BrainHealthReport(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_784_112_401),
            overall: .healthy,
            counts: BrainHealthCounts(pass: 1, activity: 0, warning: 0, failure: 0),
            checks: [
                BrainHealthCheck(
                    id: "sync.agent",
                    scope: "sync",
                    state: .pass,
                    summary: "Agent is current",
                    detail: "Reported by the remote Brain.",
                    remediation: nil
                ),
            ]
        )
    }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        guard kind == .process, question == nil else { throw BrainAPIError.invalidRequest }
        return BrainJobCreated(id: "composed-process", state: .queued)
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        guard id == "composed-process" else { throw BrainAPIError.invalidResponse }
        didProcess = true
        return job(id, kind: .process, state: .completed, output: "processed")
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        BrainHealthProbeResponse(ok: true)
    }
}

@MainActor
private func makeController(api: any RemoteBrainJobAPI) -> (
    controller: RemoteBrainController,
    defaults: UserDefaults,
    refresher: RefreshCounter,
    cleanup: () -> Void
) {
    let suite = "RemoteBrainControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let refresher = RefreshCounter()
    let controller = RemoteBrainController(
        api: api,
        defaults: defaults,
        sleep: { _ in },
        refresh: { refresher.refresh() }
    )
    return (
        controller,
        defaults,
        refresher,
        { defaults.removePersistentDomain(forName: suite) }
    )
}

private let testPairedInstance = BrainInstanceMetadata(
    baseURL: URL(string: "https://brain.example.test")!,
    instanceID: "brain-test",
    deviceID: "device-test",
    deviceName: "Test Mac",
    scopes: [.read, .control]
)

private func job(
    _ id: String,
    kind: BrainJobKind,
    state: BrainJobState,
    output: String? = nil,
    error: String? = nil,
    detail: String? = nil,
    truncated: Bool? = nil
) -> BrainJobStatus {
    BrainJobStatus(
        id: id,
        kind: kind,
        state: state,
        output: output,
        error: error,
        detail: detail,
        truncated: truncated,
        createdAt: "2026-07-15T10:00:00Z",
        startedAt: state == .queued ? nil : "2026-07-15T10:00:01Z",
        finishedAt: [.completed, .failed, .cancelled].contains(state)
            ? "2026-07-15T10:00:02Z"
            : nil,
        updatedAt: "2026-07-15T10:00:02Z"
    )
}
