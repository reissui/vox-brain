import Darwin
import Foundation
import Observation

enum MeetingNotesStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsafePath
    case invalidUTF8
    case oversized
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            "Meeting notes are stored at an unsafe filesystem location."
        case .invalidUTF8:
            "Meeting notes are not valid UTF-8 text."
        case .oversized:
            "Meeting notes must be 1 MiB or smaller."
        case .readFailed:
            "Meeting notes could not be read."
        case .writeFailed:
            "Meeting notes could not be saved."
        }
    }
}

protocol MeetingNotesStoring: Sendable {
    func load(meetingID: UUID) throws -> String
    func save(_ notes: String, meetingID: UUID) throws
}

/// Owner-only storage for the one permitted notes file beside a meeting.
final class MeetingNotesStore: MeetingNotesStoring, @unchecked Sendable {
    static let filename = "notes.md"
    static let maximumUTF8Bytes = 1 * 1_024 * 1_024

    let rootURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(meetingID: UUID) throws -> String {
        try withLock {
            guard try validateRootIfPresent() else { return "" }
            let directory = directoryURL(for: meetingID)
            guard let directoryAttributes = try attributesIfPresent(at: directory) else {
                return ""
            }
            try requireDirectory(directoryAttributes)

            let url = notesURL(for: meetingID)
            guard let attributes = try attributesIfPresent(at: url) else { return "" }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MeetingNotesStoreError.unsafePath
            }
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0
                    <= Self.maximumUTF8Bytes else {
                throw MeetingNotesStoreError.oversized
            }
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw MeetingNotesStoreError.readFailed
            }
            guard data.count <= Self.maximumUTF8Bytes else {
                throw MeetingNotesStoreError.oversized
            }
            guard let notes = String(data: data, encoding: .utf8) else {
                throw MeetingNotesStoreError.invalidUTF8
            }
            return notes
        }
    }

    func save(_ notes: String, meetingID: UUID) throws {
        let data = Data(notes.utf8)
        guard data.count <= Self.maximumUTF8Bytes else {
            throw MeetingNotesStoreError.oversized
        }
        do {
            try MeetingStore.withDeletionPrecedence(
                rootURL: rootURL,
                meetingID: meetingID,
                fileManager: fileManager
            ) {
                try withLock {
                    try saveLocked(data, meetingID: meetingID)
                }
            }
        } catch let error as MeetingNotesStoreError {
            throw error
        } catch {
            throw MeetingNotesStoreError.writeFailed
        }
    }

    private func saveLocked(_ data: Data, meetingID: UUID) throws {
        do {
            try ensureDirectory(rootURL)
            let directory = directoryURL(for: meetingID)
            try ensureDirectory(directory)
            let destination = notesURL(for: meetingID)
            if let attributes = try attributesIfPresent(at: destination) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw MeetingNotesStoreError.unsafePath
                }
            }
            try writeAtomically(data, to: destination, in: directory)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        } catch let error as MeetingNotesStoreError {
            throw error
        } catch {
            throw MeetingNotesStoreError.writeFailed
        }
    }

    func notesURL(for meetingID: UUID) -> URL {
        directoryURL(for: meetingID)
            .appendingPathComponent(Self.filename, isDirectory: false)
    }

    private func directoryURL(for meetingID: UUID) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    /// Returns false only when the root does not exist. Existing roots must be
    /// real directories, never links or special filesystem entries.
    private func validateRootIfPresent() throws -> Bool {
        guard let attributes = try attributesIfPresent(at: rootURL) else { return false }
        try requireDirectory(attributes)
        return true
    }

    private func ensureDirectory(_ url: URL) throws {
        if let attributes = try attributesIfPresent(at: url) {
            try requireDirectory(attributes)
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw MeetingNotesStoreError.writeFailed
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            throw MeetingNotesStoreError.writeFailed
        }
    }

    private func requireDirectory(_ attributes: [FileAttributeKey: Any]) throws {
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MeetingNotesStoreError.unsafePath
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL, in directory: URL) throws {
        let temporary = directory.appendingPathComponent(
            ".notes.md.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw MeetingNotesStoreError.writeFailed }
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
                        throw MeetingNotesStoreError.writeFailed
                    }
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else { throw MeetingNotesStoreError.writeFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw MeetingNotesStoreError.writeFailed
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptorIsOpen = false
                throw MeetingNotesStoreError.writeFailed
            }
            descriptorIsOpen = false
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw MeetingNotesStoreError.writeFailed
            }
        } catch let error as MeetingNotesStoreError {
            throw error
        } catch {
            throw MeetingNotesStoreError.writeFailed
        }
    }

    private func attributesIfPresent(
        at url: URL
    ) throws -> [FileAttributeKey: Any]? {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return nil }
            throw MeetingNotesStoreError.unsafePath
        }
        do {
            return try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw MeetingNotesStoreError.unsafePath
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

enum MeetingNotesSaveState: Equatable, Sendable {
    case saved
    case saving
    case error(String)
}

private actor MeetingNotesWriter {
    let store: any MeetingNotesStoring

    init(store: any MeetingNotesStoring) {
        self.store = store
    }

    func load(meetingID: UUID) throws -> String {
        try store.load(meetingID: meetingID)
    }

    func save(_ notes: String, meetingID: UUID) throws {
        try store.save(notes, meetingID: meetingID)
    }
}

/// One application-lifetime controller owns all editable notes state. File IO
/// runs through the writer actor so typing never blocks the main actor and
/// autosaves cannot overtake one another.
@MainActor
@Observable
final class MeetingNotesController {
    static let autosaveDelay: Duration = .milliseconds(250)

    var text: String = "" {
        didSet {
            guard !isApplyingLoadedText, text != oldValue else { return }
            editRevision &+= 1
            scheduleAutosave()
        }
    }
    private(set) var state: MeetingNotesSaveState = .saved
    private(set) var meetingID: UUID?

    @ObservationIgnored private let writer: MeetingNotesWriter
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var sessionRevision: UInt64 = 0
    @ObservationIgnored private var editRevision: UInt64 = 0
    @ObservationIgnored private var isApplyingLoadedText = false

    init(
        store: any MeetingNotesStoring = MeetingNotesStore(),
        autosaveDelay: Duration = MeetingNotesController.autosaveDelay,
        sleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        writer = MeetingNotesWriter(store: store)
        self.autosaveDelay = autosaveDelay
        self.sleep = sleep
    }

    deinit {
        autosaveTask?.cancel()
    }

    func attach(meetingID: UUID) {
        autosaveTask?.cancel()
        autosaveTask = nil
        sessionRevision &+= 1
        let session = sessionRevision
        isApplyingLoadedText = true
        text = ""
        isApplyingLoadedText = false
        let startingEditRevision = editRevision
        self.meetingID = meetingID
        state = .saving

        Task { [weak self, writer] in
            do {
                let loaded = try await writer.load(meetingID: meetingID)
                guard let self,
                      self.sessionRevision == session,
                      self.meetingID == meetingID else { return }
                guard self.editRevision == startingEditRevision else {
                    self.scheduleAutosave()
                    return
                }
                self.isApplyingLoadedText = true
                self.text = loaded
                self.isApplyingLoadedText = false
                self.state = .saved
            } catch {
                guard let self,
                      self.sessionRevision == session,
                      self.meetingID == meetingID else { return }
                if self.editRevision == startingEditRevision {
                    self.isApplyingLoadedText = true
                    self.text = ""
                    self.isApplyingLoadedText = false
                }
                self.state = .error(Self.message(for: error))
            }
        }
    }

    func flush() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let meetingID else { return }
        let value = text
        let session = sessionRevision
        let revision = editRevision
        await save(value, meetingID: meetingID, session: session, revision: revision)
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let meetingID else { return }
        let value = text
        let session = sessionRevision
        let revision = editRevision
        state = .saving
        autosaveTask = Task { [weak self, sleep, autosaveDelay] in
            await sleep(autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            await self.save(
                value,
                meetingID: meetingID,
                session: session,
                revision: revision
            )
        }
    }

    private func save(
        _ value: String,
        meetingID: UUID,
        session: UInt64,
        revision: UInt64
    ) async {
        do {
            try await writer.save(value, meetingID: meetingID)
            guard sessionRevision == session, self.meetingID == meetingID else { return }
            if editRevision == revision {
                state = .saved
            } else {
                scheduleAutosave()
            }
        } catch {
            guard sessionRevision == session, self.meetingID == meetingID else { return }
            state = .error(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        String(error.localizedDescription.prefix(300))
    }
}
