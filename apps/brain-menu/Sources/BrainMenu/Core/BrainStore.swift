import AppKit
import Foundation
import Observation

@MainActor
protocol BrainPrivateSiteOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct SystemBrainPrivateSiteOpener: BrainPrivateSiteOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

protocol BrainStatusAPI: Sendable {
    var pairedInstance: BrainInstanceMetadata? { get }

    func status() async throws -> BrainStatusReport
    func health() async throws -> BrainHealthReport
}

extension BrainAPIClient: BrainStatusAPI {}

@MainActor
@Observable
final class BrainStore {
    static let defaultRefreshInterval: Duration = .seconds(60)

    private(set) var snapshot: BrainSnapshot?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var isPairing = false
    private(set) var isConfiguringLocal = false
    private(set) var deploymentMode: BrainDeploymentMode?

    @ObservationIgnored private var client: (any BrainStatusAPI)?
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let privateSiteOpener: any BrainPrivateSiteOpening
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    var status: BrainStatusReport? { snapshot?.status }
    var health: BrainHealthReport? { snapshot?.health }
    var isPaired: Bool {
        deploymentMode != .local && client?.pairedInstance != nil
    }
    var isReady: Bool {
        deploymentMode == .local ? client != nil : client?.pairedInstance != nil
    }
    var pairedInstance: BrainInstanceMetadata? { client?.pairedInstance }
    var runtimeIdentity: String {
        let mode = deploymentMode?.rawValue ?? "unconfigured"
        let instance = pairedInstance?.instanceID ?? "none"
        return "\(mode):\(instance)"
    }
    var isStale: Bool { snapshot?.isStale ?? false }
    var lastRefreshedAt: Date? { snapshot?.refreshedAt }
    var privateSiteURL: URL? { status?.siteURL }

    init(
        client: (any BrainStatusAPI)? = BrainRuntime.statusClient(),
        refreshInterval: Duration = BrainStore.defaultRefreshInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        privateSiteOpener: any BrainPrivateSiteOpening = SystemBrainPrivateSiteOpener(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.refreshInterval = refreshInterval
        self.now = now
        self.privateSiteOpener = privateSiteOpener
        deploymentMode = BrainRuntime.deploymentMode(defaults: defaults)
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

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
        guard !isRefreshing, let client, client.pairedInstance != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // Keep the paired status requests sequential so manual and periodic
            // refreshes can never overlap each other or the remote instance.
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
                ? deploymentMode == .local
                    ? "The local Brain vault is unavailable. Showing a cached status snapshot."
                    : "The remote Brain origin is unavailable. Showing a cached status snapshot."
                : nil
        } catch is CancellationError {
            return
        } catch {
            if snapshot != nil {
                snapshot?.isStale = true
            }
            errorMessage = error.localizedDescription
        }
    }

    func pair(address: String, code: String) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }

        do {
            guard let baseURL = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BrainAPIError.invalidBaseURL
            }
            let client = try BrainAPIClient(baseURL: baseURL)
            _ = try await client.pair(code: code)
            BrainRuntime.selectRemote()
            deploymentMode = .remote
            self.client = client
            snapshot = nil
            errorMessage = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configureLocal(
        configuration suppliedConfiguration: BrainLocalConfiguration? = nil,
        defaults: UserDefaults = .standard
    ) async {
        guard !isConfiguringLocal else { return }
        isConfiguringLocal = true
        defer { isConfiguringLocal = false }

        do {
            let storedConfiguration = BrainRuntime.localConfiguration(defaults: defaults)
            let reusableStoredConfiguration = storedConfiguration.flatMap { configuration in
                FileManager.default.isExecutableFile(atPath: configuration.cliPath)
                    ? configuration
                    : nil
            }
            guard let configuration = suppliedConfiguration
                    ?? reusableStoredConfiguration
                    ?? BrainRuntime.defaultLocalConfiguration() else {
                throw LocalBrainError.invalidConfiguration
            }
            try await LocalBrainClient.initialize(configuration)
            try BrainRuntime.persistLocal(configuration, defaults: defaults)
            client = try LocalBrainClient(configuration: configuration)
            deploymentMode = .local
            snapshot = nil
            errorMessage = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectRemote(defaults: UserDefaults = .standard) {
        BrainRuntime.selectRemote(defaults: defaults)
        deploymentMode = .remote
        client = BrainRuntime.statusClient(defaults: defaults)
        snapshot = nil
        errorMessage = nil
    }

    @discardableResult
    func openPrivateSite() -> Bool {
        guard let privateSiteURL else { return false }
        return privateSiteOpener.open(privateSiteURL)
    }

}
