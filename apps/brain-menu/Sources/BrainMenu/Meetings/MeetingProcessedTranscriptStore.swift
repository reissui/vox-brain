import Darwin
import Foundation

protocol MeetingProcessedTranscriptStoring: Sendable {
    func load(
        meetingID: UUID,
        rawAttemptID: UUID,
        terminologyHash: String
    ) throws -> MeetingProcessedTranscript?
    func replace(_ transcript: MeetingProcessedTranscript, meetingID: UUID) throws
}

enum MeetingProcessedTranscriptStoreEvent: Equatable, Sendable {
    case beforeAtomicReplacement
}

enum MeetingProcessedTranscriptStoreError: Error, Equatable, Sendable {
    case unsafePath
    case corruptTranscript
    case invalidTranscript
    case transcriptTooLarge
    case atomicWriteFailed
}

/// Owner-only projection of one selected immutable raw attempt. A load returns
/// a value only when both pieces of source identity are current; stale output
/// is kept on disk until a successful atomic replacement supersedes it.
final class MeetingProcessedTranscriptStore: MeetingProcessedTranscriptStoring, @unchecked Sendable {
    static let filename = "processed-transcript.json"
    static let maximumEncodedSize = 16 * 1_024 * 1_024

    let rootURL: URL

    private let fileManager: FileManager
    private let failureInjector: (@Sendable (MeetingProcessedTranscriptStoreEvent) throws -> Void)?
    private let lock = NSLock()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default,
        failureInjector: (@Sendable (MeetingProcessedTranscriptStoreEvent) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func load(
        meetingID: UUID,
        rawAttemptID: UUID,
        terminologyHash: String
    ) throws -> MeetingProcessedTranscript? {
        try withLock {
            guard let transcript = try loadLocked(meetingID: meetingID) else { return nil }
            guard transcript.rawAttemptID == rawAttemptID,
                  transcript.terminologyHash == terminologyHash else { return nil }
            return transcript
        }
    }

    func replace(_ transcript: MeetingProcessedTranscript, meetingID: UUID) throws {
        guard transcript.version == MeetingTranscriptProcessingSchema.currentVersion else {
            throw MeetingProcessedTranscriptStoreError.invalidTranscript
        }
        do {
            try MeetingStore.withDeletionPrecedence(
                rootURL: rootURL,
                meetingID: meetingID,
                fileManager: fileManager
            ) {
                try withLock {
                    try ensureDirectory(rootURL)
                    let directory = directoryURL(for: meetingID)
                    try ensureDirectory(directory)
                    let destination = transcriptURL(for: meetingID)
                    if try attributesIfPresent(destination) != nil {
                        try requireRegularFile(destination)
                    }
                    let data = try Self.encoder().encode(transcript)
                    guard data.count <= Self.maximumEncodedSize else {
                        throw MeetingProcessedTranscriptStoreError.transcriptTooLarge
                    }
                    try writeAtomically(data, to: destination, in: directory)
                }
            }
        } catch let error as MeetingProcessedTranscriptStoreError {
            throw error
        } catch {
            throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
        }
    }

    func transcriptURL(for meetingID: UUID) -> URL {
        directoryURL(for: meetingID).appendingPathComponent(Self.filename)
    }

    private func loadLocked(meetingID: UUID) throws -> MeetingProcessedTranscript? {
        guard try validateRootIfPresent() else { return nil }
        let directory = directoryURL(for: meetingID)
        guard let attributes = try attributesIfPresent(directory) else { return nil }
        try requireDirectory(attributes)
        let url = transcriptURL(for: meetingID)
        guard try attributesIfPresent(url) != nil else { return nil }
        try requireRegularFile(url)
        let attributesForFile = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributesForFile[.size] as? NSNumber)?.intValue ?? 0
                <= Self.maximumEncodedSize else {
            throw MeetingProcessedTranscriptStoreError.transcriptTooLarge
        }
        do {
            let value = try JSONDecoder().decode(
                MeetingProcessedTranscript.self,
                from: Data(contentsOf: url, options: .mappedIfSafe)
            )
            guard value.version == MeetingTranscriptProcessingSchema.currentVersion else {
                throw MeetingProcessedTranscriptStoreError.invalidTranscript
            }
            return value
        } catch let error as MeetingProcessedTranscriptStoreError {
            throw error
        } catch {
            throw MeetingProcessedTranscriptStoreError.corruptTranscript
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL, in directory: URL) throws {
        let temporary = directory.appendingPathComponent(
            ".\(Self.filename).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporary)
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard let baseAddress = bytes.baseAddress else {
                        throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
                    }
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
                    }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0,
                  Darwin.close(descriptor) == 0 else {
                descriptorIsOpen = false
                throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
            }
            descriptorIsOpen = false
            try failureInjector?(.beforeAtomicReplacement)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: destination.path
            )
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
            }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
            }
        } catch let error as MeetingProcessedTranscriptStoreError {
            throw error
        } catch {
            throw MeetingProcessedTranscriptStoreError.atomicWriteFailed
        }
    }

    private func directoryURL(for meetingID: UUID) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .standardizedFileURL
    }

    private func validateRootIfPresent() throws -> Bool {
        guard let attributes = try attributesIfPresent(rootURL) else { return false }
        try requireDirectory(attributes)
        return true
    }

    private func ensureDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(url) {
            try requireDirectory(attributes)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func requireDirectory(_ attributes: [FileAttributeKey: Any]) throws {
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MeetingProcessedTranscriptStoreError.unsafePath
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingProcessedTranscriptStoreError.unsafePath
        }
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return nil }
            throw MeetingProcessedTranscriptStoreError.unsafePath
        }
        return try fileManager.attributesOfItem(atPath: url.path)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
