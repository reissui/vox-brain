import Darwin
import Foundation

enum MeetingTranscriptArtifactStoreWriteEvent: Equatable, Sendable {
    case beforeAtomicReplacement
    case afterDurableWrite
}

enum MeetingTranscriptArtifactStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsafeStorePath(String)
    case invalidSchemaVersion(Int)
    case mismatchedMeetingIdentifier
    case corruptArtifact
    case duplicateAttempt(UUID)
    case attemptsAreNotAppendOnly
    case invalidSelection(UUID)
    case selectedAttemptIsNotSuccessful(UUID)
    case artifactTooLarge
    case atomicWriteFailed

    var errorDescription: String? {
        switch self {
        case .unsafeStorePath: "The raw transcript store contains an unsafe filesystem entry."
        case .invalidSchemaVersion: "The raw transcript schema is unsupported."
        case .mismatchedMeetingIdentifier: "The raw transcript belongs to a different meeting."
        case .corruptArtifact: "The raw transcript artifact is corrupt."
        case .duplicateAttempt: "A raw transcription attempt with this identifier already exists."
        case .attemptsAreNotAppendOnly: "Raw transcription attempts are append-only."
        case .invalidSelection: "The selected raw transcription attempt does not exist."
        case .selectedAttemptIsNotSuccessful: "Only a successful raw transcription attempt can be selected."
        case .artifactTooLarge: "The raw transcript artifact exceeds 16 MiB."
        case .atomicWriteFailed: "The raw transcript artifact could not be replaced atomically."
        }
    }
}

/// Owner-only persistence for `raw-transcript.json`. The API accepts a UUID,
/// never an arbitrary path, and all mutations preserve the exact bytes-worth
/// of previously decoded attempts.
final class MeetingTranscriptArtifactStore: @unchecked Sendable {
    static let filename = "raw-transcript.json"
    static let maximumEncodedSize = 16 * 1_024 * 1_024

    let rootURL: URL

    private let fileManager: FileManager
    private let failureInjector: (@Sendable (MeetingTranscriptArtifactStoreWriteEvent) throws -> Void)?
    private let lock = NSLock()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default,
        failureInjector: (@Sendable (MeetingTranscriptArtifactStoreWriteEvent) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func load(meetingID: UUID) throws -> MeetingTranscriptArtifact? {
        try withLock { try loadLocked(meetingID: meetingID) }
    }

    func load(
        meeting: MeetingRecord,
        legacyTranscript: [MeetingUtterance]
    ) throws -> MeetingTranscriptArtifact {
        if let artifact = try load(meetingID: meeting.id) { return artifact }
        let attempt = MeetingTranscriptAttempt.legacy(
            meeting: meeting,
            utterances: legacyTranscript
        )
        return MeetingTranscriptArtifact(
            meetingID: meeting.id,
            attempts: [attempt],
            selectedAttemptID: attempt.isSuccessful ? attempt.id : nil
        )
    }

    @discardableResult
    func append(
        _ attempt: MeetingTranscriptAttempt,
        meetingID: UUID,
        selecting: Bool = false
    ) throws -> MeetingTranscriptArtifact {
        try withLock {
            var artifact = try loadLocked(meetingID: meetingID)
                ?? MeetingTranscriptArtifact(meetingID: meetingID)
            guard !artifact.attempts.contains(where: { $0.id == attempt.id }) else {
                throw MeetingTranscriptArtifactStoreError.duplicateAttempt(attempt.id)
            }
            artifact.attempts.append(attempt)
            if selecting {
                guard attempt.isSuccessful else {
                    throw MeetingTranscriptArtifactStoreError.selectedAttemptIsNotSuccessful(
                        attempt.id
                    )
                }
                artifact.selectedAttemptID = attempt.id
            }
            try saveLocked(artifact, meetingID: meetingID)
            return artifact
        }
    }

    @discardableResult
    func save(_ artifact: MeetingTranscriptArtifact) throws -> MeetingTranscriptArtifact {
        try withLock {
            try saveLocked(artifact, meetingID: artifact.meetingID)
            return artifact
        }
    }

    /// Advances the selected projection only after the attempt is already a
    /// durable member of the append-only document.
    @discardableResult
    func select(attemptID: UUID, meetingID: UUID) throws -> MeetingTranscriptArtifact {
        try withLock {
            guard var artifact = try loadLocked(meetingID: meetingID),
                  let selectedIndex = artifact.attempts.firstIndex(where: {
                      $0.id == attemptID
                  }) else {
                throw MeetingTranscriptArtifactStoreError.invalidSelection(attemptID)
            }
            guard artifact.attempts[selectedIndex].isSuccessful else {
                throw MeetingTranscriptArtifactStoreError.selectedAttemptIsNotSuccessful(attemptID)
            }
            if let oldID = artifact.selectedAttemptID,
               let oldIndex = artifact.attempts.firstIndex(where: { $0.id == oldID }),
               selectedIndex < oldIndex {
                throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
            }
            artifact.selectedAttemptID = attemptID
            try saveLocked(artifact, meetingID: meetingID)
            return artifact
        }
    }

    private func loadLocked(meetingID: UUID) throws -> MeetingTranscriptArtifact? {
        try requireSafeRootIfPresent()
        let directory = directoryURL(for: meetingID)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try requireSafeDirectory(directory, expectedParent: rootURL)
        let url = directory.appendingPathComponent(Self.filename).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else {
            throw MeetingTranscriptArtifactStoreError.unsafeStorePath(url.path)
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try requireRegularFile(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumEncodedSize else {
            throw MeetingTranscriptArtifactStoreError.artifactTooLarge
        }
        do {
            let artifact = try Self.decoder().decode(
                MeetingTranscriptArtifact.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe])
            )
            try validate(artifact, meetingID: meetingID)
            return artifact
        } catch let error as MeetingTranscriptArtifactStoreError {
            throw error
        } catch {
            throw MeetingTranscriptArtifactStoreError.corruptArtifact
        }
    }

    private func saveLocked(
        _ artifact: MeetingTranscriptArtifact,
        meetingID: UUID
    ) throws {
        try validate(artifact, meetingID: meetingID)
        let existing = try loadLocked(meetingID: meetingID)
        if let existing {
            guard artifact.attempts.count >= existing.attempts.count,
                  Array(artifact.attempts.prefix(existing.attempts.count)) == existing.attempts else {
                throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
            }
            let oldIDs = Set(existing.attempts.map(\.id))
            let appendedIDs = artifact.attempts.dropFirst(existing.attempts.count).map(\.id)
            guard oldIDs.isDisjoint(with: appendedIDs),
                  Set(appendedIDs).count == appendedIDs.count else {
                throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
            }
            if artifact.selectedAttemptID != existing.selectedAttemptID,
               let selected = artifact.selectedAttemptID {
                guard let selectedIndex = artifact.attempts.firstIndex(where: {
                    $0.id == selected
                }) else {
                    throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
                }
                if let oldSelected = existing.selectedAttemptID,
                   let oldIndex = artifact.attempts.firstIndex(where: {
                       $0.id == oldSelected
                   }), selectedIndex < oldIndex {
                    throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
                }
            }
        }

        let data = try Self.encoder().encode(artifact)
        guard data.count <= Self.maximumEncodedSize else {
            throw MeetingTranscriptArtifactStoreError.artifactTooLarge
        }
        try ensureDirectory(rootURL, expectedParent: nil)
        let directory = directoryURL(for: meetingID)
        try ensureDirectory(directory, expectedParent: rootURL)
        let destination = directory.appendingPathComponent(Self.filename)
        if fileManager.fileExists(atPath: destination.path) {
            try requireRegularFile(destination)
        }
        let temporary = directory.appendingPathComponent(
            ".\(Self.filename).\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingTranscriptArtifactStoreError.atomicWriteFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            try failureInjector?(.beforeAtomicReplacement)
            guard rename(temporary.path, destination.path) == 0 else {
                throw MeetingTranscriptArtifactStoreError.atomicWriteFailed
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: destination.path
            )
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw MeetingTranscriptArtifactStoreError.atomicWriteFailed
            }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw MeetingTranscriptArtifactStoreError.atomicWriteFailed
            }
            try failureInjector?(.afterDurableWrite)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let error = error as? MeetingTranscriptArtifactStoreError { throw error }
            throw MeetingTranscriptArtifactStoreError.atomicWriteFailed
        }
    }

    private func validate(
        _ artifact: MeetingTranscriptArtifact,
        meetingID: UUID
    ) throws {
        guard artifact.schemaVersion == MeetingTranscriptArtifact.currentSchemaVersion else {
            throw MeetingTranscriptArtifactStoreError.invalidSchemaVersion(artifact.schemaVersion)
        }
        guard artifact.meetingID == meetingID else {
            throw MeetingTranscriptArtifactStoreError.mismatchedMeetingIdentifier
        }
        let ids = artifact.attempts.map(\.id)
        guard Set(ids).count == ids.count else {
            throw MeetingTranscriptArtifactStoreError.attemptsAreNotAppendOnly
        }
        if let selected = artifact.selectedAttemptID {
            guard let attempt = artifact.attempts.first(where: { $0.id == selected }) else {
                throw MeetingTranscriptArtifactStoreError.invalidSelection(selected)
            }
            guard attempt.isSuccessful else {
                throw MeetingTranscriptArtifactStoreError.selectedAttemptIsNotSuccessful(selected)
            }
        }
    }

    private func directoryURL(for meetingID: UUID) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true).standardizedFileURL
    }

    private func requireSafeRootIfPresent() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try requireSafeDirectory(rootURL, expectedParent: nil)
    }

    private func ensureDirectory(_ url: URL, expectedParent: URL?) throws {
        if fileManager.fileExists(atPath: url.path) {
            try requireSafeDirectory(url, expectedParent: expectedParent)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func requireSafeDirectory(_ url: URL, expectedParent: URL?) throws {
        let standardized = url.standardizedFileURL
        if let expectedParent,
           standardized.deletingLastPathComponent() != expectedParent.standardizedFileURL {
            throw MeetingTranscriptArtifactStoreError.unsafeStorePath(url.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: standardized.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              standardized.resolvingSymlinksInPath().standardizedFileURL == standardized else {
            throw MeetingTranscriptArtifactStoreError.unsafeStorePath(url.path)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw MeetingTranscriptArtifactStoreError.unsafeStorePath(url.path)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
