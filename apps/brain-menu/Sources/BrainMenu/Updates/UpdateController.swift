import AppKit
import Foundation
import Observation

struct BrainRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL
    let archiveURL: URL
    let archiveSize: Int
}

enum BrainUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(Date)
    case available(BrainRelease)
    case downloading(BrainRelease)
    case failed(String)
    case unavailable(String)
}

struct BrainUpdateSidebarAlert: Equatable, Sendable {
    let title: String
    let detail: String
}

enum BrainUpdateError: LocalizedError {
    case invalidResponse
    case noReleasePublished
    case noReleaseArchive
    case archiveTooLarge
    case invalidRelease
    case invalidApplication
    case unsignedApplication
    case signerMismatch
    case updaterUnavailable
    case installationLocationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub returned an invalid release response."
        case .noReleasePublished: "No Brain releases have been published yet."
        case .noReleaseArchive: "The latest release does not include a Brain update archive."
        case .archiveTooLarge: "The release archive is larger than Brain's update limit."
        case .invalidRelease: "The downloaded release version does not match GitHub."
        case .invalidApplication: "The downloaded archive does not contain a valid Brain app."
        case .unsignedApplication: "The downloaded Brain app did not pass macOS signature validation."
        case .signerMismatch: "The update was signed by a different developer and was not installed."
        case .updaterUnavailable: "The Brain update helper is unavailable."
        case .installationLocationUnavailable: "Move Brain to Applications before installing updates."
        }
    }
}

protocol BrainUpdateServing: Sendable {
    func latestRelease() async throws -> BrainRelease
    func prepareInstallation(for release: BrainRelease) async throws -> BrainPreparedUpdate
}

struct BrainPreparedUpdate: Sendable {
    let helperURL: URL
    let currentApplicationURL: URL
    let preparedApplicationURL: URL
}

actor GitHubBrainUpdateService: BrainUpdateServing {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/reissui/vox-brain/releases/latest"
    )!
    static let maximumArchiveSize = 500 * 1_024 * 1_024

    private struct ReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    func latestRelease() async throws -> BrainRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Brain.app updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw BrainUpdateError.noReleasePublished
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ReleaseResponse.self, from: data),
              decoded.tagName.hasPrefix("brain-v") else {
            throw BrainUpdateError.invalidResponse
        }
        let version = String(decoded.tagName.dropFirst("brain-v".count))
        guard BrainSemanticVersion(version) != nil else {
            throw BrainUpdateError.invalidResponse
        }
        guard let archive = decoded.assets.first(where: {
            $0.name == "Brain-\(version).zip"
        }) else {
            throw BrainUpdateError.noReleaseArchive
        }
        guard archive.size > 0, archive.size <= Self.maximumArchiveSize else {
            throw BrainUpdateError.archiveTooLarge
        }
        return BrainRelease(
            version: version,
            pageURL: decoded.htmlURL,
            archiveURL: archive.browserDownloadURL,
            archiveSize: archive.size
        )
    }

    func prepareInstallation(for release: BrainRelease) async throws -> BrainPreparedUpdate {
        let currentApplicationURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentApplicationURL.pathExtension == "app",
              currentApplicationURL.deletingLastPathComponent().isFileURL else {
            throw BrainUpdateError.installationLocationUnavailable
        }
        let helperURL = currentApplicationURL
            .appendingPathComponent("Contents/Helpers/BrainUpdater", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw BrainUpdateError.updaterUnavailable
        }

        let (downloadURL, response) = try await URLSession.shared.download(from: release.archiveURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BrainUpdateError.invalidResponse
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let extracted = temporaryRoot.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", downloadURL.path, extracted.path]
        )

        guard let candidate = Self.findApplication(in: extracted),
              let candidateBundle = Bundle(url: candidate),
              candidateBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              candidateBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == release.version else {
            throw BrainUpdateError.invalidRelease
        }

        try await Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", candidate.path]
        )
        let currentTeam = try await Self.teamIdentifier(for: currentApplicationURL)
        let candidateTeam = try await Self.teamIdentifier(for: candidate)
        guard let currentTeam, let candidateTeam else {
            throw BrainUpdateError.unsignedApplication
        }
        guard currentTeam == candidateTeam else {
            throw BrainUpdateError.signerMismatch
        }

        let parent = currentApplicationURL.deletingLastPathComponent()
        let readyURL = parent.appendingPathComponent(
            ".Brain-update-ready-\(UUID().uuidString).app",
            isDirectory: true
        )
        do {
            try FileManager.default.copyItem(at: candidate, to: readyURL)
        } catch {
            throw BrainUpdateError.installationLocationUnavailable
        }
        return BrainPreparedUpdate(
            helperURL: helperURL,
            currentApplicationURL: currentApplicationURL,
            preparedApplicationURL: readyURL
        )
    }

    private static func findApplication(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("Brain.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "Brain.app" {
            return url
        }
        return nil
    }

    private static func teamIdentifier(for applicationURL: URL) async throws -> String? {
        let output = try await run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", applicationURL.path],
            acceptsStandardError: true
        )
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count)
            return value == "not set" || value.isEmpty ? nil : String(value)
        }
        return nil
    }

    @discardableResult
    private static func run(
        executable: URL,
        arguments: [String],
        acceptsStandardError: Bool = false
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw BrainUpdateError.invalidApplication
            }
            return String(
                decoding: acceptsStandardError ? errorData : outputData,
                as: UTF8.self
            )
        }.value
    }
}

struct BrainSemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let major = Int(pieces[0]),
              let minor = Int(pieces[1]),
              let patch = Int(pieces[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

@MainActor
@Observable
final class UpdateController {
    static let automaticChecksDefaultsKey = "BrainMenu.updates.automaticChecks"
    static let lastCheckDefaultsKey = "BrainMenu.updates.lastCheck"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: BrainUpdateState = .idle
    var automaticChecksEnabled: Bool {
        didSet {
            defaults.set(automaticChecksEnabled, forKey: Self.automaticChecksDefaultsKey)
            if automaticChecksEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    @ObservationIgnored private let service: any BrainUpdateServing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let buildInfo: BrainBuildInfo?
    @ObservationIgnored private var automaticTask: Task<Void, Never>?

    init(
        service: any BrainUpdateServing = GitHubBrainUpdateService(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        buildInfo: BrainBuildInfo? = BrainBuildInfo.current
    ) {
        self.service = service
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        self.buildInfo = buildInfo
        automaticChecksEnabled = defaults.object(
            forKey: Self.automaticChecksDefaultsKey
        ) as? Bool ?? true
    }

    var currentVersion: String {
        buildInfo?.version ?? "Unknown"
    }

    var availableRelease: BrainRelease? {
        switch state {
        case .available(let release), .downloading(let release): release
        default: nil
        }
    }

    var sidebarAlert: BrainUpdateSidebarAlert? {
        guard let release = availableRelease else { return nil }
        return BrainUpdateSidebarAlert(
            title: state == .downloading(release) ? "Installing update" : "Update available",
            detail: "Brain \(release.version)"
        )
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    func start() {
        guard automaticChecksEnabled, automaticTask == nil else { return }
        let lastCheck = defaults.object(forKey: Self.lastCheckDefaultsKey) as? Date
        let initialDelay = lastCheck.map {
            max(0, Self.automaticCheckInterval - now().timeIntervalSince($0))
        } ?? 0
        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if initialDelay > 0 {
                do {
                    try await self.sleep(.seconds(initialDelay))
                } catch {
                    return
                }
            }
            while !Task.isCancelled, self.automaticChecksEnabled {
                await self.checkNow()
                do {
                    try await self.sleep(.seconds(Self.automaticCheckInterval))
                } catch {
                    return
                }
            }
            self.automaticTask = nil
        }
    }

    func stop() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    func checkNow() async {
        guard !isWorking else { return }
        guard let buildInfo, let current = BrainSemanticVersion(buildInfo.version) else {
            state = .unavailable("Build version information is unavailable.")
            return
        }
        state = .checking
        do {
            let release = try await service.latestRelease()
            guard let latest = BrainSemanticVersion(release.version) else {
                throw BrainUpdateError.invalidResponse
            }
            let checkedAt = now()
            defaults.set(checkedAt, forKey: Self.lastCheckDefaultsKey)
            state = latest > current ? .available(release) : .upToDate(checkedAt)
        } catch is CancellationError {
            state = .idle
        } catch BrainUpdateError.noReleasePublished {
            state = .unavailable("No Brain releases have been published yet.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func installAvailableUpdate() async {
        guard case .available(let release) = state else { return }
        state = .downloading(release)
        do {
            let prepared = try await service.prepareInstallation(for: release)
            let process = Process()
            process.executableURL = prepared.helperURL
            process.arguments = [
                prepared.currentApplicationURL.path,
                prepared.preparedApplicationURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
            ]
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch is CancellationError {
            state = .available(release)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openReleasePage() {
        guard let release = availableRelease else { return }
        NSWorkspace.shared.open(release.pageURL)
    }
}
