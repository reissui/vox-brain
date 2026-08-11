import Foundation
import Observation

protocol BrainStatusAPI: Sendable {
    func status() async throws -> BrainStatusReport
    func health() async throws -> BrainHealthReport
}

@MainActor
@Observable
final class BrainStore {
    static let defaultRefreshInterval: Duration = .seconds(60)

    private(set) var snapshot: BrainSnapshot?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isConfiguringLocal = false

    @ObservationIgnored private var client: (any BrainStatusAPI)?
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    var status: BrainStatusReport? { snapshot?.status }
    var health: BrainHealthReport? { snapshot?.health }
    var isReady: Bool { client != nil }
    var runtimeIdentity: String {
        BrainRuntime.localConfiguration(defaults: defaults)?.vaultPath ?? "local:unconfigured"
    }
    var isStale: Bool { snapshot?.isStale ?? false }
    var lastRefreshedAt: Date? { snapshot?.refreshedAt }

    init(
        client: (any BrainStatusAPI)? = BrainRuntime.statusClient(),
        refreshInterval: Duration = BrainStore.defaultRefreshInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.refreshInterval = refreshInterval
        self.now = now
        self.defaults = defaults
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            if self.client == nil {
                await self.configureLocal()
            } else {
                await self.refresh()
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.refreshInterval)
                } catch {
                    return
                }
                await self.refresh()
            }
        }
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func refresh() async {
        guard !isRefreshing, let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let status = try await client.status()
            let health = try await client.health()
            let staleReports = [status.freshness, health.freshness].filter(\.isStale)
            let isStale = !staleReports.isEmpty
            let reportTimestamp = staleReports.compactMap(\.snapshotAt).min()
            snapshot = BrainSnapshot(
                status: status,
                health: health,
                refreshedAt: reportTimestamp ?? (isStale
                    ? min(status.generatedAt, health.generatedAt)
                    : now()),
                isStale: isStale
            )
            errorMessage = isStale
                ? "The local Brain vault is unavailable. Showing a cached status snapshot."
                : nil
        } catch is CancellationError {
            return
        } catch {
            if snapshot != nil { snapshot?.isStale = true }
            errorMessage = error.localizedDescription
        }
    }

    /// Initializes or reconnects the configured local vault. A failed attempt
    /// leaves the app on its recovery screen and can be retried without
    /// changing or deleting any existing vault contents.
    func configureLocal(
        configuration suppliedConfiguration: BrainLocalConfiguration? = nil,
        defaults suppliedDefaults: UserDefaults? = nil
    ) async {
        guard !isConfiguringLocal else { return }
        isConfiguringLocal = true
        defer { isConfiguringLocal = false }

        let defaults = suppliedDefaults ?? self.defaults
        do {
            guard let configuration = suppliedConfiguration
                    ?? BrainRuntime.configuration(defaults: defaults) else {
                throw LocalBrainError.invalidConfiguration
            }
            let marker = configuration.vaultURL
                .appendingPathComponent(LocalBrainClient.markerFilename)
            if !FileManager.default.fileExists(atPath: marker.path) {
                try await LocalBrainClient.initialize(configuration)
            }
            try BrainRuntime.persistLocal(configuration, defaults: defaults)
            client = try LocalBrainClient(configuration: configuration)
            snapshot = nil
            errorMessage = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }
}
