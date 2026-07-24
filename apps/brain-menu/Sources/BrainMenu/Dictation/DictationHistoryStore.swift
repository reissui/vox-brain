import AppKit
import Darwin
import Foundation
import Observation

struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let completedAt: Date
    let text: String
}

protocol DictationClipboardWriting: Sendable {
    func write(_ text: String)
}

struct SystemDictationClipboard: DictationClipboardWriting {
    func write(_ text: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

enum DictationHistoryError: Error, Equatable, LocalizedError, Sendable {
    case unsafeStorage
    case storageTooLarge
    case invalidHistory
    case persistenceFailed
    case handoffUnavailable
    case unsafeVoxTypeLog
    case invalidVoxTypeLog
    case voxTypeLogReadFailed

    var errorDescription: String? {
        switch self {
        case .unsafeStorage:
            "Dictation history storage is not private and could not be opened safely."
        case .storageTooLarge:
            "Dictation history input was quarantined because it exceeded the safety limit."
        case .invalidHistory:
            "Dictation history could not be read and was moved aside safely."
        case .persistenceFailed:
            "Dictation history could not be saved."
        case .handoffUnavailable:
            "Completed dictation could not be imported yet."
        case .unsafeVoxTypeLog:
            "VoxType's local dictation log could not be opened safely."
        case .invalidVoxTypeLog:
            "VoxType's dictation log format is not supported by this Brain version."
        case .voxTypeLogReadFailed:
            "Brain could not read VoxType's local dictation log."
        }
    }
}

@MainActor
@Observable
final class DictationHistoryStore {
    nonisolated static let retentionLimit = 500
    nonisolated static let maximumTranscriptBytes = 1_048_576
    nonisolated static let maximumHandoffBytes = 64 * 1_048_576
    nonisolated static let maximumHistoryBytes = 16 * 1_048_576
    nonisolated static let maximumVoxTypeLogReadBytes = 16 * 1_048_576

    private(set) var entries: [DictationHistoryEntry] = []
    private(set) var storageErrorMessage: String?
    private(set) var integrationErrorMessage: String?

    var errorMessage: String? { integrationErrorMessage ?? storageErrorMessage }

    let directoryURL: URL
    let handoffURL: URL
    let lockURL: URL
    let historyURL: URL
    let quarantineURL: URL
    let voxTypeLogURL: URL
    let voxTypeLogCursorURL: URL

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let clipboard: any DictationClipboardWriting
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?

    init(
        directoryURL: URL? = nil,
        voxTypeLogURL: URL? = nil,
        fileManager: FileManager = .default,
        clipboard: any DictationClipboardWriting = SystemDictationClipboard()
    ) {
        let selectedDirectory = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.directoryURL = selectedDirectory.standardizedFileURL
        handoffURL = selectedDirectory.appendingPathComponent("handoff.frames", isDirectory: false)
        lockURL = selectedDirectory.appendingPathComponent("handoff.lock", isDirectory: false)
        historyURL = selectedDirectory.appendingPathComponent("history.json", isDirectory: false)
        quarantineURL = selectedDirectory.appendingPathComponent("Quarantine", isDirectory: true)
        self.voxTypeLogURL = (
            voxTypeLogURL ?? Self.defaultVoxTypeLogURL(fileManager: fileManager)
        ).standardizedFileURL
        voxTypeLogCursorURL = selectedDirectory.appendingPathComponent(
            "voxtype-log-cursor.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        self.clipboard = clipboard
        do {
            try prepareDirectories()
            try loadHistory()
        } catch {
            storageErrorMessage = safeMessage(for: error)
        }
    }

    deinit {
        monitoringTask?.cancel()
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
    }

    static func defaultVoxTypeLogURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/voxtype/stdout.log", isDirectory: false)
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        importPendingFrames()
        importVoxTypeLog()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.importVoxTypeLog()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func importPendingFrames() {
        do {
            try prepareDirectories()
            try withHandoffLock {
                let descriptor = open(
                    handoffURL.path,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
                guard descriptor >= 0 else { throw DictationHistoryError.handoffUnavailable }
                defer { close(descriptor) }
                try validatePrivateRegularFile(descriptor)

                var information = stat()
                guard fstat(descriptor, &information) == 0 else {
                    throw DictationHistoryError.handoffUnavailable
                }
                if information.st_size == 0 { return }
                guard information.st_size <= Self.maximumHandoffBytes else {
                    try quarantineHandoff(descriptor: descriptor)
                    throw DictationHistoryError.storageTooLarge
                }

                let data = try readAll(descriptor: descriptor, count: Int(information.st_size))
                let parsed = DictationHandoffFrame.parse(data)
                let known = Set(entries.map(\.id))
                var imported = parsed.entries.filter { !known.contains($0.id) }
                imported.append(contentsOf: entries)
                imported.sort {
                    if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                    return $0.id.uuidString > $1.id.uuidString
                }
                if imported.count > Self.retentionLimit {
                    imported.removeLast(imported.count - Self.retentionLimit)
                }

                // Persist IDs and text before acknowledging the handoff. If the
                // process exits between these operations, the next launch sees
                // the same frames and deduplicates them by UUID.
                try persist(imported)
                entries = imported
                if parsed.isCorrupted {
                    try quarantineHandoff(descriptor: descriptor)
                } else {
                    guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else {
                        throw DictationHistoryError.handoffUnavailable
                    }
                }
            }
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = safeMessage(for: error)
        }
    }

    func importVoxTypeLog() {
        do {
            try prepareDirectories()
            let cursor = try loadVoxTypeLogCursor()
            guard let batch = try VoxTypeLogReader.read(
                from: voxTypeLogURL,
                after: cursor,
                maximumBytes: Self.maximumVoxTypeLogReadBytes
            ) else {
                integrationErrorMessage = nil
                return
            }

            var known = Set(entries.map {
                VoxTypeLogEntryIdentity(completedAt: $0.completedAt, text: $0.text)
            })
            var imported = batch.entries.compactMap { entry -> DictationHistoryEntry? in
                guard entry.text.utf8.count <= Self.maximumTranscriptBytes else { return nil }
                let identity = VoxTypeLogEntryIdentity(
                    completedAt: entry.completedAt,
                    text: entry.text
                )
                guard known.insert(identity).inserted else { return nil }
                return DictationHistoryEntry(
                    id: UUID(),
                    completedAt: entry.completedAt,
                    text: entry.text
                )
            }
            imported.append(contentsOf: entries)
            imported.sort {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            if imported.count > Self.retentionLimit {
                imported.removeLast(imported.count - Self.retentionLimit)
            }

            if imported != entries {
                // Save history before advancing the cursor. If Brain exits
                // between these writes, content and timestamp deduplication
                // makes replay exactly once on the next launch.
                try persist(imported)
                entries = imported
            }
            if cursor != batch.cursor {
                try persistVoxTypeLogCursor(batch.cursor)
            }
            integrationErrorMessage = nil
        } catch {
            integrationErrorMessage = safeMessage(for: error)
        }
    }

    func copy(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        clipboard.write(entry.text)
    }

    func delete(id: UUID) {
        let updated = entries.filter { $0.id != id }
        guard updated.count != entries.count else { return }
        do {
            try persist(updated)
            entries = updated
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = safeMessage(for: error)
        }
    }

    func clearAll() {
        do {
            try persist([])
            entries = []
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = safeMessage(for: error)
        }
    }

    private func prepareDirectories() throws {
        let brainDirectory = directoryURL.deletingLastPathComponent()
        try createOrValidatePrivateDirectory(brainDirectory)
        try createOrValidatePrivateDirectory(directoryURL)
        try createOrValidatePrivateDirectory(quarantineURL)
    }

    private func createOrValidatePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw DictationHistoryError.unsafeStorage
        }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              chmod(url.path, 0o700) == 0 else {
            throw DictationHistoryError.unsafeStorage
        }
    }

    private func loadHistory() throws {
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        guard isPrivateRegularFile(historyURL) else { throw DictationHistoryError.unsafeStorage }
        let attributes = try fileManager.attributesOfItem(atPath: historyURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumHistoryBytes else {
            try quarantineHistory()
            throw DictationHistoryError.invalidHistory
        }
        do {
            let data = try Data(contentsOf: historyURL, options: [.mappedIfSafe])
            let decoded = try JSONDecoder.brainDictation.decode(
                [DictationHistoryEntry].self,
                from: data
            )
            guard decoded.count <= Self.retentionLimit,
                  decoded.allSatisfy({ $0.text.utf8.count <= Self.maximumTranscriptBytes }) else {
                throw DictationHistoryError.invalidHistory
            }
            var identifiers = Set<UUID>()
            guard decoded.allSatisfy({ identifiers.insert($0.id).inserted }) else {
                throw DictationHistoryError.invalidHistory
            }
            entries = decoded.sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        } catch {
            try quarantineHistory()
            throw DictationHistoryError.invalidHistory
        }
    }

    private func persist(_ records: [DictationHistoryEntry]) throws {
        do {
            try prepareDirectories()
            let data = try JSONEncoder.brainDictation.encode(records)
            guard data.count <= Self.maximumHistoryBytes else {
                throw DictationHistoryError.persistenceFailed
            }
            let staged = directoryURL.appendingPathComponent(
                ".history.\(UUID().uuidString).brain-tmp",
                isDirectory: false
            )
            let descriptor = open(
                staged.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw DictationHistoryError.persistenceFailed }
            var descriptorIsOpen = true
            defer {
                if descriptorIsOpen { close(descriptor) }
            }
            do {
                try validatePrivateRegularFile(descriptor)
                try writeAll(data, descriptor: descriptor)
                guard fsync(descriptor) == 0 else {
                    throw DictationHistoryError.persistenceFailed
                }
                close(descriptor)
                descriptorIsOpen = false
                guard rename(staged.path, historyURL.path) == 0 else {
                    throw DictationHistoryError.persistenceFailed
                }
                guard chmod(historyURL.path, 0o600) == 0 else {
                    throw DictationHistoryError.persistenceFailed
                }
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        } catch let error as DictationHistoryError {
            throw error
        } catch {
            throw DictationHistoryError.persistenceFailed
        }
    }

    private func loadVoxTypeLogCursor() throws -> VoxTypeLogCursor? {
        guard fileManager.fileExists(atPath: voxTypeLogCursorURL.path) else { return nil }
        guard isPrivateRegularFile(voxTypeLogCursorURL) else {
            throw DictationHistoryError.unsafeStorage
        }
        do {
            let data = try Data(contentsOf: voxTypeLogCursorURL)
            guard data.count <= 4_096 else { return nil }
            return try? JSONDecoder().decode(VoxTypeLogCursor.self, from: data)
        } catch {
            throw DictationHistoryError.persistenceFailed
        }
    }

    private func persistVoxTypeLogCursor(_ cursor: VoxTypeLogCursor) throws {
        do {
            let data = try JSONEncoder().encode(cursor)
            let staged = directoryURL.appendingPathComponent(
                ".voxtype-log-cursor.\(UUID().uuidString).brain-tmp",
                isDirectory: false
            )
            let descriptor = open(
                staged.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else { throw DictationHistoryError.persistenceFailed }
            var descriptorIsOpen = true
            defer {
                if descriptorIsOpen { close(descriptor) }
            }
            do {
                try validatePrivateRegularFile(descriptor)
                try writeAll(data, descriptor: descriptor)
                guard fsync(descriptor) == 0 else {
                    throw DictationHistoryError.persistenceFailed
                }
                close(descriptor)
                descriptorIsOpen = false
                guard rename(staged.path, voxTypeLogCursorURL.path) == 0,
                      chmod(voxTypeLogCursorURL.path, 0o600) == 0 else {
                    throw DictationHistoryError.persistenceFailed
                }
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        } catch let error as DictationHistoryError {
            throw error
        } catch {
            throw DictationHistoryError.persistenceFailed
        }
    }

    private func withHandoffLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw DictationHistoryError.handoffUnavailable }
        defer { close(descriptor) }
        try validatePrivateRegularFile(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DictationHistoryError.handoffUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func validatePrivateRegularFile(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw DictationHistoryError.unsafeStorage
        }
    }

    private func isPrivateRegularFile(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFREG
            && information.st_uid == geteuid()
    }

    private func readAll(descriptor: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < count {
                let amount = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw DictationHistoryError.handoffUnavailable }
                offset += amount
            }
        }
        return result
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw DictationHistoryError.persistenceFailed }
                offset += amount
            }
        }
    }

    private func quarantineHandoff(descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw DictationHistoryError.handoffUnavailable }
        let destination = quarantineURL.appendingPathComponent(
            "handoff-\(UUID().uuidString).frames",
            isDirectory: false
        )
        guard rename(handoffURL.path, destination.path) == 0,
              chmod(destination.path, 0o600) == 0 else {
            throw DictationHistoryError.handoffUnavailable
        }
        let replacement = open(
            handoffURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard replacement >= 0 else { throw DictationHistoryError.handoffUnavailable }
        close(replacement)
    }

    private func quarantineHistory() throws {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        let destination = quarantineURL.appendingPathComponent(
            "history-\(UUID().uuidString).json",
            isDirectory: false
        )
        guard rename(historyURL.path, destination.path) == 0,
              chmod(destination.path, 0o600) == 0 else {
            throw DictationHistoryError.persistenceFailed
        }
    }

    private func safeMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? DictationHistoryError.persistenceFailed.localizedDescription
    }
}

enum DictationHandoffFrame {
    static let magic = Data("BRDCT001".utf8)
    static let fixedBodyBytes = 36 + 8 + 4

    struct ParseResult {
        let entries: [DictationHistoryEntry]
        let isCorrupted: Bool
    }

    static func encode(id: UUID, completedAt: Date, text: String) -> Data {
        let textData = Data(text.utf8)
        let identifierData = Data(id.uuidString.utf8)
        let milliseconds = Int64((completedAt.timeIntervalSince1970 * 1_000).rounded())
        let bodyLength = fixedBodyBytes + textData.count
        var frame = Data(capacity: magic.count + 4 + bodyLength)
        frame.append(magic)
        frame.appendBigEndian(UInt32(bodyLength))
        frame.append(identifierData)
        frame.appendBigEndian(UInt64(bitPattern: milliseconds))
        frame.appendBigEndian(UInt32(textData.count))
        frame.append(textData)
        return frame
    }

    static func parse(_ data: Data) -> ParseResult {
        var cursor = 0
        var result: [DictationHistoryEntry] = []
        var seen = Set<UUID>()
        while cursor < data.count {
            guard data.count - cursor >= magic.count + 4,
                  data[cursor..<(cursor + magic.count)] == magic[...] else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            cursor += magic.count
            guard let bodyLength: UInt32 = data.readBigEndian(at: cursor) else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            cursor += 4
            let bodyBytes = Int(bodyLength)
            guard bodyBytes >= fixedBodyBytes,
                  bodyBytes <= fixedBodyBytes + DictationHistoryStore.maximumTranscriptBytes,
                  bodyBytes <= data.count - cursor else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            let frameEnd = cursor + bodyBytes
            let identifierData = data[cursor..<(cursor + 36)]
            cursor += 36
            guard let identifierText = String(data: identifierData, encoding: .utf8),
                  let identifier = UUID(uuidString: identifierText),
                  let timestampBits: UInt64 = data.readBigEndian(at: cursor) else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            cursor += 8
            guard let textLength: UInt32 = data.readBigEndian(at: cursor) else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            cursor += 4
            guard Int(textLength) == frameEnd - cursor,
                  Int(textLength) <= DictationHistoryStore.maximumTranscriptBytes,
                  let text = String(data: data[cursor..<frameEnd], encoding: .utf8),
                  !text.isEmpty else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            cursor = frameEnd
            let timestamp = Int64(bitPattern: timestampBits)
            guard timestamp > 0, seen.insert(identifier).inserted else {
                return ParseResult(entries: result, isCorrupted: true)
            }
            result.append(DictationHistoryEntry(
                id: identifier,
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1_000),
                text: text
            ))
        }
        return ParseResult(entries: result, isCorrupted: false)
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(at offset: Int) -> T? {
        guard offset >= 0, count - offset >= MemoryLayout<T>.size else { return nil }
        var value: T = 0
        for byte in self[offset..<(offset + MemoryLayout<T>.size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}

private extension JSONEncoder {
    static var brainDictation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var brainDictation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
