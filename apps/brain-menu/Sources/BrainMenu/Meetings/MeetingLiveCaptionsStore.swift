import Foundation

/// Persists the opt-in for live meeting captions. Recording always continues;
/// this flag only controls whether Brain spends GPU on preview transcription
/// during the call. Missing keys default to off.
final class MeetingLiveCaptionsStore: @unchecked Sendable {
    static let defaultsKey = "meeting.liveCaptions.enabled"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        lock.withLock {
            defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
        }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            defaults.set(enabled, forKey: Self.defaultsKey)
        }
    }
}
