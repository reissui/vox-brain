import Foundation

enum AISettingsStoreError: Error, Equatable, LocalizedError {
    case invalidBookmark
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .invalidBookmark:
            "Brain could not store the selected executable."
        case .invalidArguments:
            "Custom command arguments may not contain provider credentials."
        }
    }
}

final class AISettingsStore: @unchecked Sendable {
    static let defaultsKey = "BrainMenu.aiProviderSettings.v1"

    private struct PersistedSettings: Codable {
        let provider: AIProvider
        let executableBookmark: Data?
        let arguments: [String]
        let model: String?
        let timeout: TimeInterval
        let contextChoice: AIContextChoice
    }

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func load() -> AIProviderConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let persisted = try? decoder.decode(PersistedSettings.self, from: data) else {
            return AIProviderConfiguration()
        }

        var executableURL: URL?
        if let bookmark = persisted.executableBookmark {
            var stale = false
            executableURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale, let executableURL,
               let refreshed = try? Self.bookmark(for: executableURL),
               let refreshedSettings = try? encoder.encode(PersistedSettings(
                   provider: persisted.provider,
                   executableBookmark: refreshed,
                   arguments: persisted.arguments,
                   model: persisted.model,
                   timeout: AIProviderConfiguration.boundedTimeout(persisted.timeout),
                   contextChoice: persisted.contextChoice
               )) {
                defaults.set(refreshedSettings, forKey: Self.defaultsKey)
            }
        }

        return AIProviderConfiguration(
            provider: persisted.provider,
            executableURL: executableURL,
            arguments: persisted.arguments,
            model: persisted.model,
            timeout: persisted.timeout,
            contextChoice: persisted.contextChoice
        ).canonicalized()
    }

    func save(_ configuration: AIProviderConfiguration) throws {
        let configuration = configuration.canonicalized()
        do {
            if configuration.provider == .advanced {
                try AIProviderValidation.validateAdvancedArguments(configuration.arguments)
            }
        } catch {
            throw AISettingsStoreError.invalidArguments
        }

        let bookmark: Data?
        if let executableURL = configuration.executableURL {
            do {
                bookmark = try Self.bookmark(for: executableURL)
            } catch {
                throw AISettingsStoreError.invalidBookmark
            }
        } else {
            bookmark = nil
        }

        let persisted = PersistedSettings(
            provider: configuration.provider,
            executableBookmark: bookmark,
            arguments: configuration.arguments,
            model: configuration.model,
            timeout: AIProviderConfiguration.boundedTimeout(configuration.timeout),
            contextChoice: configuration.contextChoice
        )
        defaults.set(try encoder.encode(persisted), forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isRegularFileKey, .isExecutableKey],
            relativeTo: nil
        )
    }
}
