import AppKit
import Foundation
import Observation

enum GmailConnectionState: Equatable, Sendable {
    case checking
    case disconnected
    case authorizing
    case connected(account: String)
    case reconnectRequired
    case denied
    case expired
    case unavailable(detail: String)
    case timedOut

    var title: String {
        switch self {
        case .checking:
            "Checking…"
        case .disconnected:
            "Not connected"
        case .authorizing:
            "Waiting for Google consent…"
        case .connected(let account):
            account.isEmpty ? "Connected" : "Connected as \(account)"
        case .reconnectRequired:
            "Reconnect required"
        case .denied:
            "Consent denied"
        case .expired:
            "Consent expired"
        case .unavailable:
            "Server unavailable"
        case .timedOut:
            "Consent timed out"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Checking Gmail on the paired remote Brain instance."
        case .disconnected:
            "No Gmail account is connected on the remote Brain instance."
        case .authorizing:
            "Finish Google consent in your browser while Brain waits for the remote instance."
        case .connected:
            "Remote capability: Gmail read-only. Brain can search mail and read threads on demand; it cannot send, modify, or delete mail."
        case .reconnectRequired:
            "The remote Gmail grant must be renewed before Brain can read mail."
        case .denied:
            "Google consent was denied. Gmail remains disconnected."
        case .expired:
            "The remote consent session expired before it was completed."
        case .unavailable(let detail):
            detail
        case .timedOut:
            "Brain stopped waiting for consent. Refresh to check the remote status or try again."
        }
    }

    var symbolName: String {
        switch self {
        case .checking, .authorizing: "clock"
        case .disconnected: "minus.circle"
        case .connected: "checkmark.circle.fill"
        case .reconnectRequired, .expired, .timedOut: "exclamationmark.triangle.fill"
        case .denied: "xmark.circle.fill"
        case .unavailable: "network.slash"
        }
    }
}

enum GmailRemoteStatus: Equatable, Sendable {
    case disconnected
    case connected(account: String)
    case reconnectRequired
    case denied
    case expired
    case originUnavailable
}

protocol GmailConnectionAPI: Sendable {
    func start() async throws -> URL
    func status() async throws -> GmailRemoteStatus
    func disconnect() async throws
}

@MainActor
protocol GmailAuthorizationOpening: Sendable {
    func open(_ url: URL) -> Bool
}

struct SystemGmailAuthorizationOpener: GmailAuthorizationOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

struct BrainGmailConnectionAPI: GmailConnectionAPI {
    let client: BrainAPIClient

    func start() async throws -> URL {
        try await client.startGmailConnection().authorizationURL
    }

    func status() async throws -> GmailRemoteStatus {
        do {
            let response = try await client.gmailStatus()
            switch response.status {
            case .disconnected:
                return .disconnected
            case .connected:
                return .connected(account: response.account ?? "")
            case .reconnectRequired:
                return .reconnectRequired
            case .denied:
                return .denied
            case .expired:
                return .expired
            case .originUnavailable:
                return .originUnavailable
            }
        } catch let error as BrainAPIError {
            guard case .http(let status, let code, _, _) = error else { throw error }
            let normalizedCode = code.lowercased()
            if normalizedCode.contains("denied") {
                return .denied
            }
            if normalizedCode.contains("expired") {
                return .expired
            }
            if status == 503 {
                return .originUnavailable
            }
            throw error
        }
    }

    func disconnect() async throws {
        let response = try await client.disconnectGmail()
        guard response.status == .disconnected else {
            throw BrainAPIError.invalidResponse
        }
    }
}

@MainActor
@Observable
final class GmailConnectionController {
    static let pollInterval: Duration = .seconds(2)
    static let maximumPollAttempts = 150

    private(set) var state: GmailConnectionState = .checking
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private let api: (any GmailConnectionAPI)?
    @ObservationIgnored private let opener: any GmailAuthorizationOpening
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let maximumPollingAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        api: (any GmailConnectionAPI)? = GmailConnectionController.persistedAPIClient(),
        opener: any GmailAuthorizationOpening = SystemGmailAuthorizationOpener(),
        pollingInterval: Duration = GmailConnectionController.pollInterval,
        maximumPollingAttempts: Int = GmailConnectionController.maximumPollAttempts,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.api = api
        self.opener = opener
        self.pollingInterval = pollingInterval
        self.maximumPollingAttempts = max(1, maximumPollingAttempts)
        self.sleep = sleep
    }

    func refresh() async {
        guard !isWorking else { return }
        guard let api else {
            state = .unavailable(detail: "Pair this Mac with a remote Brain instance first.")
            errorMessage = nil
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            apply(try await api.status())
        } catch is CancellationError {
            return
        } catch {
            showUnavailable(error)
        }
    }

    func connect() async {
        guard !isWorking else { return }
        guard let api else {
            state = .unavailable(detail: "Pair this Mac with a remote Brain instance first.")
            errorMessage = nil
            return
        }

        isWorking = true
        errorMessage = nil
        state = .authorizing
        defer { isWorking = false }

        do {
            let authorizationURL = try await api.start()
            guard opener.open(authorizationURL) else {
                throw GmailConnectionError.browserUnavailable
            }

            for attempt in 0..<maximumPollingAttempts {
                let status = try await api.status()
                switch status {
                case .connected(let account):
                    state = .connected(account: account)
                    return
                case .denied:
                    state = .denied
                    return
                case .expired:
                    state = .expired
                    return
                case .originUnavailable:
                    state = .unavailable(
                        detail: "The remote Brain instance cannot currently report Gmail status."
                    )
                    return
                case .disconnected, .reconnectRequired:
                    if attempt == maximumPollingAttempts - 1 {
                        state = .timedOut
                        return
                    }
                    try await sleep(pollingInterval)
                }
            }
        } catch is CancellationError {
            state = .disconnected
        } catch {
            showUnavailable(error)
        }
    }

    func disconnect() async {
        guard !isWorking else { return }
        guard let api else {
            state = .unavailable(detail: "Pair this Mac with a remote Brain instance first.")
            errorMessage = nil
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await api.disconnect()
            state = .disconnected
        } catch is CancellationError {
            return
        } catch {
            showUnavailable(error)
        }
    }

    private func apply(_ status: GmailRemoteStatus) {
        switch status {
        case .disconnected:
            state = .disconnected
        case .connected(let account):
            state = .connected(account: account)
        case .reconnectRequired:
            state = .reconnectRequired
        case .denied:
            state = .denied
        case .expired:
            state = .expired
        case .originUnavailable:
            state = .unavailable(
                detail: "The remote Brain instance cannot currently report Gmail status."
            )
        }
    }

    private func showUnavailable(_ error: Error) {
        let detail = error.localizedDescription
        errorMessage = detail
        state = .unavailable(detail: detail)
    }

    static func persistedAPIClient(
        defaults: UserDefaults = .standard
    ) -> (any GmailConnectionAPI)? {
        guard let data = defaults.data(forKey: BrainAPIClient.metadataDefaultsKey),
              let metadata = try? JSONDecoder().decode(BrainInstanceMetadata.self, from: data),
              let client = try? BrainAPIClient(baseURL: metadata.baseURL, defaults: defaults) else {
            return nil
        }
        return BrainGmailConnectionAPI(client: client)
    }
}

enum GmailConnectionError: Error, Equatable, LocalizedError, Sendable {
    case browserUnavailable

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            "Brain could not open the Google consent page in the default browser."
        }
    }
}
