import Foundation

struct BrainLocalConfiguration: Codable, Equatable, Sendable {
    let vaultPath: String
    let cliPath: String

    var vaultURL: URL { URL(fileURLWithPath: vaultPath, isDirectory: true) }
    var cliURL: URL { URL(fileURLWithPath: cliPath, isDirectory: false) }
}

/// Resolves the one supported Brain runtime: the bundled CLI operating on a
/// vault owned by this user. Historical settings from older app versions are
/// deliberately not read or removed, so upgrading never mutates old data.
enum BrainRuntime {
    static let localConfigurationDefaultsKey = "brain.local.configuration"

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
        let vaultURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
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
        defaults.set(try JSONEncoder().encode(configuration), forKey: localConfigurationDefaultsKey)
    }

    static func configuration(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> BrainLocalConfiguration? {
        if let stored = localConfiguration(defaults: defaults),
           fileManager.isExecutableFile(atPath: stored.cliPath) {
            return stored
        }
        return defaultLocalConfiguration(
            fileManager: fileManager,
            environment: environment,
            bundle: bundle
        )
    }

    static func client(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        configuration(defaults: defaults).flatMap { try? LocalBrainClient(configuration: $0) }
    }

    static func statusClient(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        client(defaults: defaults)
    }

    static func captureClient(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        client(defaults: defaults)
    }

    static func knowledgeClient(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        client(defaults: defaults)
    }

    static func jobClient(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        client(defaults: defaults)
    }

    static func chatClient(defaults: UserDefaults = .standard) -> LocalBrainClient? {
        client(defaults: defaults)
    }

}
