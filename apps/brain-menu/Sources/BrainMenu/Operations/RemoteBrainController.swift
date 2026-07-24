import Foundation
import Observation

/// The complete set of vault-changing controls exposed by Brain.app.
///
/// There are intentionally no associated values: callers cannot supply a
/// command, arguments, a filesystem location, or a remote machine address.
enum RemoteBrainAction: String, CaseIterable, Identifiable, Sendable {
    case process
    case digest

    var id: Self { self }

    var jobKind: BrainJobKind {
        switch self {
        case .process: .process
        case .digest: .digest
        }
    }

    var title: String {
        switch self {
        case .process: "Process inbox"
        case .digest: "Write digest"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .process:
            "Brain will process the current vault inbox."
        case .digest:
            "Brain will write the current vault digest now."
        }
    }
}

struct RemoteBrainOutput: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let isTruncated: Bool
}

struct RemoteBrainFailure: Equatable, Sendable {
    let code: String
    /// Public, credential-free remediation returned by the remote API.
    let remediation: String?
}

enum RemoteBrainConnectionState: Equatable, Sendable {
    case notTested
    case testing
    case reachable
    case failed(String)
}

enum RemoteBrainRequestResult: Equatable, Sendable {
    case confirmationRequired(RemoteBrainAction)
    case completed(BrainJobStatus)
    case rejected(String)
    case failed(String)
}

protocol RemoteBrainJobAPI: Sendable {
    var pairedInstance: BrainInstanceMetadata? { get }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated
    func jobStatus(id: String) async throws -> BrainJobStatus
    func healthProbe() async throws -> BrainHealthProbeResponse
}

extension BrainAPIClient: RemoteBrainJobAPI {}

@MainActor
@Observable
final class RemoteBrainController {
    static let activeJobDefaultsKey = "brain.remote.active-job-id"
    static let lastJobDefaultsKey = "brain.remote.last-job-id"
    static let refreshedTerminalJobDefaultsKey = "brain.remote.refreshed-terminal-job-id"
    static let concurrentMutationMessage = "Another Brain job is already in progress."
    static let maximumStandardOutputBytes = 48 * 1_024
    static let maximumStandardErrorBytes = 2 * 1_024
    static let pollingBackoff: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10),
    ]

    /// Covers the small interval before a newly-created job ID can be stored,
    /// including when SwiftUI has recreated the Actions view meanwhile.
    private static var submissionInFlight = false

    private(set) var pendingConfirmation: RemoteBrainAction?
    private(set) var currentJob: BrainJobStatus?
    private(set) var submittedJobID: String?
    private(set) var submittedJobKind: BrainJobKind?
    private(set) var submittedJobState: BrainJobState?
    private(set) var output: RemoteBrainOutput?
    private(set) var publicFailure: RemoteBrainFailure?
    private(set) var errorMessage: String?
    private(set) var connectionState: RemoteBrainConnectionState = .notTested
    private(set) var isSubmitting = false
    private(set) var isPolling = false
    private(set) var observedStates: [BrainJobState] = []

    @ObservationIgnored private let api: (any RemoteBrainJobAPI)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let refreshDashboard: @MainActor @Sendable () async -> Void
    @ObservationIgnored private var pollingJobID: String?

    var pairedInstance: BrainInstanceMetadata? { api?.pairedInstance }

    var displayedState: BrainJobState? {
        currentJob?.state ?? submittedJobState
    }

    var isMutating: Bool {
        Self.submissionInFlight
            || isSubmitting
            || pollingJobID != nil
            || defaults.string(forKey: Self.activeJobDefaultsKey) != nil
            || displayedState.map(Self.isTerminal) == false
    }

    init(
        api: (any RemoteBrainJobAPI)?,
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        refresh: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.api = api
        self.defaults = defaults
        self.sleep = sleep
        refreshDashboard = refresh
        submittedJobID = defaults.string(forKey: Self.activeJobDefaultsKey)
            ?? defaults.string(forKey: Self.lastJobDefaultsKey)
    }

    static func live(
        defaults: UserDefaults = .standard,
        refresh: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> RemoteBrainController {
        RemoteBrainController(
            api: BrainRuntime.jobClient(defaults: defaults),
            defaults: defaults,
            refresh: refresh
        )
    }

    /// Requests an explicit in-app confirmation. This never contacts the API.
    @discardableResult
    func request(_ action: RemoteBrainAction) -> RemoteBrainRequestResult {
        guard !isMutating else { return rejectConcurrentMutation() }
        errorMessage = nil
        pendingConfirmation = action
        return .confirmationRequired(action)
    }

    func cancelPendingAction() {
        pendingConfirmation = nil
    }

    /// Creates exactly one typed remote job after a request has been confirmed,
    /// then follows that job ID until it reaches a terminal state.
    @discardableResult
    func confirmPendingAction() async -> RemoteBrainRequestResult {
        guard let action = pendingConfirmation else {
            let message = "There is no Brain action to confirm."
            errorMessage = message
            return .rejected(message)
        }
        guard !isMutating else { return rejectConcurrentMutation() }
        guard let api else {
            pendingConfirmation = nil
            let message = BrainAPIError.notPaired.localizedDescription
            errorMessage = message
            return .failed(message)
        }

        pendingConfirmation = nil
        Self.submissionInFlight = true
        isSubmitting = true
        errorMessage = nil
        output = nil
        publicFailure = nil
        currentJob = nil
        observedStates = []
        submittedJobKind = action.jobKind

        do {
            let created = try await api.createJob(kind: action.jobKind, question: nil)
            Self.submissionInFlight = false
            isSubmitting = false
            submittedJobID = created.id
            submittedJobState = created.state
            publish(created.state)
            defaults.set(created.id, forKey: Self.activeJobDefaultsKey)
            defaults.set(created.id, forKey: Self.lastJobDefaultsKey)

            guard let terminal = await poll(
                jobID: created.id,
                expectedKind: action.jobKind
            ) else {
                let message = errorMessage ?? "Brain job monitoring stopped."
                return .failed(message)
            }
            return .completed(terminal)
        } catch is CancellationError {
            Self.submissionInFlight = false
            isSubmitting = false
            // The server owns submitted work. A cancelled window task must not
            // cancel or re-submit it; its persisted ID is resumed next time.
            return .failed("Brain job monitoring stopped.")
        } catch {
            Self.submissionInFlight = false
            isSubmitting = false
            let message = error.localizedDescription
            errorMessage = message
            return .failed(message)
        }
    }

    /// Read-only refresh. It tests the paired endpoint, resumes an unfinished
    /// persisted job, or fetches the most recently displayed terminal job.
    func refresh() async {
        guard let api else {
            connectionState = .failed(BrainAPIError.notPaired.localizedDescription)
            errorMessage = BrainAPIError.notPaired.localizedDescription
            return
        }

        connectionState = .testing
        do {
            let probe = try await api.healthProbe()
            connectionState = probe.ok
                ? .reachable
                : .failed("The paired Brain instance reported that it is unavailable.")
        } catch is CancellationError {
            return
        } catch {
            connectionState = .failed(error.localizedDescription)
        }

        if pollingJobID != nil { return }
        if let activeID = defaults.string(forKey: Self.activeJobDefaultsKey) {
            submittedJobID = activeID
            _ = await poll(jobID: activeID, expectedKind: nil)
            return
        }

        if let lastID = defaults.string(forKey: Self.lastJobDefaultsKey) {
            submittedJobID = lastID
            await fetchLastJob(id: lastID, api: api)
        }
    }

    private func poll(jobID: String, expectedKind: BrainJobKind?) async -> BrainJobStatus? {
        guard pollingJobID == nil || pollingJobID == jobID else {
            _ = rejectConcurrentMutation()
            return nil
        }
        guard let api else { return nil }

        pollingJobID = jobID
        isPolling = true
        defer {
            if pollingJobID == jobID { pollingJobID = nil }
            isPolling = false
        }

        var attempt = 0
        while !Task.isCancelled {
            do {
                let status = try await api.jobStatus(id: jobID)
                guard status.id == jobID,
                      expectedKind.map({ $0 == status.kind }) ?? true else {
                    throw BrainAPIError.invalidResponse
                }
                publish(status)

                if Self.isTerminal(status.state) {
                    defaults.removeObject(forKey: Self.activeJobDefaultsKey)
                    defaults.set(jobID, forKey: Self.lastJobDefaultsKey)
                    await refreshDashboardOnce(forTerminalJobID: jobID)
                    return status
                }

                let delay = Self.pollingBackoff[min(attempt, Self.pollingBackoff.count - 1)]
                attempt += 1
                try await sleep(delay)
            } catch is CancellationError {
                return nil
            } catch {
                // Keep the nonterminal ID so a manual refresh or relaunch can
                // resume monitoring without creating a second job.
                errorMessage = error.localizedDescription
                return nil
            }
        }
        return nil
    }

    private func fetchLastJob(id: String, api: any RemoteBrainJobAPI) async {
        do {
            let status = try await api.jobStatus(id: id)
            guard status.id == id else { throw BrainAPIError.invalidResponse }
            if Self.isTerminal(status.state) {
                publish(status)
            } else {
                defaults.set(id, forKey: Self.activeJobDefaultsKey)
                _ = await poll(jobID: id, expectedKind: status.kind)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publish(_ state: BrainJobState) {
        submittedJobState = state
        if observedStates.last != state { observedStates.append(state) }
    }

    private func publish(_ status: BrainJobStatus) {
        currentJob = status
        submittedJobID = status.id
        submittedJobKind = status.kind
        publish(status.state)

        guard Self.isTerminal(status.state) else {
            output = nil
            publicFailure = nil
            return
        }

        let boundedOut = Self.bound(status.output ?? "", bytes: Self.maximumStandardOutputBytes)
        let boundedError = Self.bound(status.detail ?? "", bytes: Self.maximumStandardErrorBytes)
        output = RemoteBrainOutput(
            standardOutput: boundedOut.value,
            standardError: boundedError.value,
            isTruncated: status.truncated == true || boundedOut.truncated || boundedError.truncated
        )
        if status.state == .failed {
            publicFailure = RemoteBrainFailure(
                code: status.error ?? "job_failed",
                remediation: status.detail
            )
        } else {
            publicFailure = nil
        }
        errorMessage = nil
    }

    private func refreshDashboardOnce(forTerminalJobID id: String) async {
        guard defaults.string(forKey: Self.refreshedTerminalJobDefaultsKey) != id else {
            return
        }
        // Record before awaiting so closing the window cannot trigger a second
        // refresh on relaunch.
        defaults.set(id, forKey: Self.refreshedTerminalJobDefaultsKey)
        await refreshDashboard()
    }

    private func rejectConcurrentMutation() -> RemoteBrainRequestResult {
        errorMessage = Self.concurrentMutationMessage
        return .rejected(Self.concurrentMutationMessage)
    }

    private static func isTerminal(_ state: BrainJobState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }

    private static func bound(_ value: String, bytes limit: Int) -> (value: String, truncated: Bool) {
        let bytes = Array(value.utf8)
        guard bytes.count > limit else { return (value, false) }

        var end = limit
        while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil {
            end -= 1
        }
        return (String(decoding: bytes[..<end], as: UTF8.self), true)
    }
}
