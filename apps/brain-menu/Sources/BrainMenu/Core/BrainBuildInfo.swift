import Foundation

struct BrainBuildInfo: Equatable, Sendable {
    enum Channel: String, Sendable {
        case development
        case test
        case release
    }

    let version: String
    let build: String
    let sourceSHA: String
    let channel: Channel
    let buildDate: String

    init?(infoDictionary: [String: Any]) {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String,
              Self.matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+$"#),
              let build = infoDictionary["CFBundleVersion"] as? String,
              Self.matches(build, #"^[0-9]+$"#),
              let sourceSHA = infoDictionary["BrainSourceSHA"] as? String,
              Self.matches(sourceSHA, #"^[0-9a-f]{40}$"#),
              let channelValue = infoDictionary["BrainChannel"] as? String,
              let channel = Channel(rawValue: channelValue),
              let buildDate = infoDictionary["BrainBuildDate"] as? String,
              Self.isCanonicalUTCBuildDate(buildDate)
        else { return nil }

        self.version = version
        self.build = build
        self.sourceSHA = sourceSHA
        self.channel = channel
        self.buildDate = buildDate
    }

    static var current: BrainBuildInfo? {
        BrainBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    var versionLabel: String { "Version \(version) (\(build))" }
    var shortSourceSHA: String { String(sourceSHA.prefix(12)) }

    var diagnostics: String {
        """
        Brain \(version) (\(build))
        Channel: \(channel.rawValue)
        Source: \(sourceSHA)
        Built: \(buildDate)
        """
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isCanonicalUTCBuildDate(_ value: String) -> Bool {
        guard matches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#)
        else { return false }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
