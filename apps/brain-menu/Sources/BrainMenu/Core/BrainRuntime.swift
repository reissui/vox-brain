import Foundation

enum BrainDeploymentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remote

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "This Mac"
        case .remote: "Remote Brain"
        }
    }

    var detail: String {
        switch self {
        case .local:
            "Keep the vault and run the Brain CLI on this Mac. No server, Cloudflare account, or MCP connection is used."
        case .remote:
            "Connect this app to a Brain runner on another Mac through the authenticated remote gateway."
        }
    }
}

struct BrainLocalConfiguration: Codable, Equatable, Sendable {
    let vaultPath: String
    let cliPath: String

    var vaultURL: URL { URL(fileURLWithPath: vaultPath, isDirectory: true) }
    var cliURL: URL { URL(fileURLWithPath: cliPath, isDirectory: false) }
}

enum BrainRuntime {
    static let deploymentModeDefaultsKey = "brain.deployment.mode"
    static let localConfigurationDefaultsKey = "brain.local.configuration"

    static func deploymentMode(defaults: UserDefaults = .standard) -> BrainDeploymentMode? {
        defaults.string(forKey: deploymentModeDefaultsKey)
            .flatMap(BrainDeploymentMode.init(rawValue:))
    }

    static func localConfiguration(
        defaults: UserDefaults = .standard
    ) -> BrainLocalConfiguration? {
        guard let data = defaults.data(forKey: localConfigurationDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BrainLocalConfiguration.self, from: data)
    }

    static func defaultLocalConfiguration(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> BrainLocalConfiguration? {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let vaultURL = applicationSupport?
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
        guard let vaultURL, let cliURL = discoverCLI(
            fileManager: fileManager,
            environment: environment,
            bundle: bundle
        ) else {
            return nil
        }
        return BrainLocalConfiguration(
            vaultPath: vaultURL.standardizedFileURL.path,
            cliPath: cliURL.standardizedFileURL.path
        )
    }

    static func discoverCLI(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        var candidates: [URL] = []
        if let sourceRoot = environment["BRAIN_SOURCE_ROOT"], sourceRoot.hasPrefix("/") {
            candidates.append(
                URL(fileURLWithPath: sourceRoot, isDirectory: true)
                    .appendingPathComponent("scripts/brain")
            )
        }
        if let resourceURL = bundle.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("BrainRuntime", isDirectory: true)
                    .appendingPathComponent("scripts/brain")
            )
        }
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("scripts/brain")
        )
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("dev/brain", isDirectory: true)
                .appendingPathComponent("scripts/brain")
        )
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.standardizedFileURL.path)
        }?.standardizedFileURL
    }

    static func persistLocal(
        _ configuration: BrainLocalConfiguration,
        defaults: UserDefaults = .standard
    ) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: localConfigurationDefaultsKey)
        defaults.set(BrainDeploymentMode.local.rawValue, forKey: deploymentModeDefaultsKey)
        clearJobContinuations(defaults: defaults)
    }

    static func selectRemote(defaults: UserDefaults = .standard) {
        defaults.set(BrainDeploymentMode.remote.rawValue, forKey: deploymentModeDefaultsKey)
        clearJobContinuations(defaults: defaults)
    }

    static func statusClient(defaults: UserDefaults = .standard) -> (any BrainStatusAPI)? {
        switch deploymentMode(defaults: defaults) {
        case .local:
            return localConfiguration(defaults: defaults).flatMap {
                try? LocalBrainClient(configuration: $0)
            }
        case .remote:
            return remoteAPIClient(defaults: defaults)
        case nil:
            return nil
        }
    }

    static func captureClient(defaults: UserDefaults = .standard) -> (any BrainCaptureAPI)? {
        switch deploymentMode(defaults: defaults) {
        case .local:
            return localConfiguration(defaults: defaults).flatMap {
                try? LocalBrainClient(configuration: $0)
            }
        case .remote:
            guard let metadata = remoteMetadata(defaults: defaults),
                  metadata.scopes.contains(.capture) else {
                return nil
            }
            return PairedCaptureClient(metadata: metadata)
        case nil:
            return nil
        }
    }

    static func knowledgeClient(
        defaults: UserDefaults = .standard
    ) -> (any RemoteKnowledgeAPI)? {
        switch deploymentMode(defaults: defaults) {
        case .local:
            return localConfiguration(defaults: defaults).flatMap {
                try? LocalBrainClient(configuration: $0)
            }
        case .remote:
            guard let metadata = remoteMetadata(defaults: defaults),
                  metadata.scopes.contains(.read) else {
                return nil
            }
            return try? BrainAPIClient(baseURL: metadata.baseURL, defaults: defaults)
        case nil:
            return nil
        }
    }

    static func jobClient(defaults: UserDefaults = .standard) -> (any RemoteBrainJobAPI)? {
        switch deploymentMode(defaults: defaults) {
        case .local:
            return localConfiguration(defaults: defaults).flatMap {
                try? LocalBrainClient(configuration: $0)
            }
        case .remote:
            return remoteAPIClient(defaults: defaults)
        case nil:
            return nil
        }
    }

    static func chatClient(defaults: UserDefaults = .standard) -> (any BrainChatJobAPI)? {
        switch deploymentMode(defaults: defaults) {
        case .local:
            return localConfiguration(defaults: defaults).flatMap {
                try? LocalBrainClient(configuration: $0)
            }
        case .remote:
            return remoteAPIClient(defaults: defaults)
        case nil:
            return nil
        }
    }

    private static func remoteMetadata(
        defaults: UserDefaults
    ) -> BrainInstanceMetadata? {
        guard let data = defaults.data(forKey: BrainAPIClient.metadataDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BrainInstanceMetadata.self, from: data)
    }

    private static func remoteAPIClient(defaults: UserDefaults) -> BrainAPIClient? {
        guard let metadata = remoteMetadata(defaults: defaults) else { return nil }
        return try? BrainAPIClient(baseURL: metadata.baseURL, defaults: defaults)
    }

    private static func clearJobContinuations(defaults: UserDefaults) {
        for key in [
            "brain.remote.active-job-id",
            "brain.remote.last-job-id",
            "brain.remote.refreshed-terminal-job-id",
            "brain.chat.current-job",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
