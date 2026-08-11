import AVFoundation
import Foundation

enum MeetingStoreFile: String, Equatable, Sendable {
    case meeting = "meeting.json"
    case transcript = "transcript.json"
}

enum MeetingStoreWriteEvent: Equatable, Sendable {
    case beforeAtomicReplacement(MeetingStoreFile)
    case afterAtomicDeletionRename
}

enum UnavailableMeetingReason: String, Equatable, Sendable {
    case unsafeEntry
    case missingMeeting
    case corruptMeeting
    case missingTranscript
    case corruptTranscript
    case mismatchedIdentifier
}

struct UnavailableMeeting: Equatable, Sendable {
    let id: UUID?
    let directoryName: String
    let reason: UnavailableMeetingReason
}

enum MeetingListEntry: Equatable, Sendable {
    case available(MeetingRecord)
    case unavailable(UnavailableMeeting)

    var id: UUID? {
        switch self {
        case .available(let meeting): meeting.id
        case .unavailable(let meeting): meeting.id
        }
    }
}

enum MeetingStoreError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound(UUID)
    case audioDeletionCommitted(UUID)
    case deletionRequiresConfirmation
    case unsafeStorePath(String)
    case corruptMeeting(UUID, UnavailableMeetingReason)
    case atomicWriteFailed(MeetingStoreFile)
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .meetingNotFound:
            "The meeting is not available on this Mac."
        case .audioDeletionCommitted:
            "The meeting audio was deleted and cannot be restored by a stale update."
        case .deletionRequiresConfirmation:
            "Deleting a meeting requires explicit confirmation."
        case .unsafeStorePath:
            "The meeting store contains an unsafe filesystem entry."
        case .corruptMeeting:
            "The local meeting data is unavailable or corrupt."
        case .atomicWriteFailed:
            "The local meeting could not be replaced atomically."
        case .rollbackFailed:
            "The local meeting update failed and its prior files could not be fully restored."
        }
    }
}

/// Local operational state for meetings. The Markdown vault is intentionally
/// outside this type's API and filesystem scope.
final class MeetingStore: @unchecked Sendable {
    static let maximumRecords = 1_000
    static let meetingFilename = MeetingStoreFile.meeting.rawValue
    static let transcriptFilename = MeetingStoreFile.transcript.rawValue

    static var productionRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Brain", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    let rootURL: URL

    private let fileManager: FileManager
    private let failureInjector: (@Sendable (MeetingStoreWriteEvent) throws -> Void)?
    private let lock = NSLock()
    private static let mutationRegistry = MeetingStoreMutationRegistry()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default,
        failureInjector: (@Sendable (MeetingStoreWriteEvent) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws {
        try Self.withDeletionPrecedence(
            rootURL: rootURL,
            meetingID: meeting.id,
            fileManager: fileManager
        ) {
            try withLock {
                try saveLocked(meeting, utterances: utterances)
            }
        }
    }

    private func saveLocked(
        _ meeting: MeetingRecord,
        utterances: [MeetingUtterance]
    ) throws {
        try ensureDirectory(rootURL, permissions: 0o700)

        let directory = directoryURL(for: meeting.id)
        let createdDirectory = !fileManager.fileExists(atPath: directory.path)
        try ensureDirectory(directory, permissions: 0o700)

        let meetingURL = directory.appendingPathComponent(Self.meetingFilename)
        let transcriptURL = directory.appendingPathComponent(Self.transcriptFilename)
        let oldMeeting = try existingData(at: meetingURL)
        if meeting.audioRetentionState != .deleted,
           let oldMeeting,
           (try? Self.decoder().decode(MeetingRecord.self, from: oldMeeting))?
            .audioRetentionState == .deleted {
            throw MeetingStoreError.audioDeletionCommitted(meeting.id)
        }
        let oldTranscript = try existingData(at: transcriptURL)
        if fileManager.fileExists(atPath: transcriptURL.path), !isRegularFile(transcriptURL) {
            throw MeetingStoreError.unsafeStorePath(transcriptURL.lastPathComponent)
        }
        let meetingData = try Self.encoder().encode(meeting)
        let transcriptData = try Self.encoder().encode(
            utterances.sorted(by: MeetingUtterance.chronologicallyPrecedes)
        )
        let stagedMeeting = try stage(meetingData, for: .meeting, in: directory)
        var stagedTranscript: URL?

        do {
            stagedTranscript = try stage(transcriptData, for: .transcript, in: directory)
        } catch {
            try? fileManager.removeItem(at: stagedMeeting)
            if createdDirectory {
                try? fileManager.removeItem(at: directory)
            }
            throw error
        }

        var replacedTranscript = false
        do {
            if let stagedTranscript {
                try replace(stagedTranscript, at: transcriptURL, file: .transcript, injectFailure: true)
                replacedTranscript = true
            }
            // meeting.json is the visible commit marker. It is replaced
            // last so a completed state can never point at older transcript
            // bytes after an interrupted two-file update.
            try replace(stagedMeeting, at: meetingURL, file: .meeting, injectFailure: true)
        } catch {
            try? fileManager.removeItem(at: stagedMeeting)
            if let stagedTranscript {
                try? fileManager.removeItem(at: stagedTranscript)
            }

            do {
                if replacedTranscript {
                    try restore(
                        oldTranscript,
                        at: transcriptURL,
                        file: .transcript,
                        in: directory
                    )
                }
                if createdDirectory {
                    try? fileManager.removeItem(at: directory)
                }
            } catch {
                throw MeetingStoreError.rollbackFailed
            }
            throw error
        }
    }

    func save(meeting: MeetingRecord, transcript: [MeetingUtterance]) throws {
        try save(meeting, utterances: transcript)
    }

    func load(_ id: UUID) throws -> StoredMeeting {
        try withLock {
            let directory = directoryURL(for: id)
            guard fileManager.fileExists(atPath: directory.path) else {
                throw MeetingStoreError.meetingNotFound(id)
            }
            do {
                return try load(id: id, from: directory)
            } catch let error as ClassifiedLoadError {
                throw MeetingStoreError.corruptMeeting(id, error.reason)
            }
        }
    }

    func list() throws -> [MeetingListEntry] {
        try Self.mutationRegistry.withReconciliation(rootPath: rootURL.path) {
            try withLock {
                guard fileManager.fileExists(atPath: rootURL.path) else {
                    return ([], [])
                }
                try requireSafeDirectory(rootURL)
                let deletedMeetingIDs = try cleanupDeletionTombstonesLocked()

                let children = try fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                let candidates = children.map { child -> ListingCandidate in
                    let directoryName = child.lastPathComponent
                    let id = UUID(uuidString: directoryName)
                    let modifiedAt = (try? child.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast

                    guard let id else {
                        return ListingCandidate(
                            entry: .unavailable(UnavailableMeeting(
                                id: nil,
                                directoryName: directoryName,
                                reason: .unsafeEntry
                            )),
                            sortDate: modifiedAt,
                            directoryName: directoryName
                        )
                    }

                    do {
                        let stored = try load(id: id, from: child)
                        return ListingCandidate(
                            entry: .available(stored.meeting),
                            sortDate: stored.meeting.startedAt,
                            directoryName: directoryName
                        )
                    } catch let error as ClassifiedLoadError {
                        return ListingCandidate(
                            entry: .unavailable(UnavailableMeeting(
                                id: id,
                                directoryName: directoryName,
                                reason: error.reason
                            )),
                            sortDate: modifiedAt,
                            directoryName: directoryName
                        )
                    } catch {
                        return ListingCandidate(
                            entry: .unavailable(UnavailableMeeting(
                                id: id,
                                directoryName: directoryName,
                                reason: .unsafeEntry
                            )),
                            sortDate: modifiedAt,
                            directoryName: directoryName
                        )
                    }
                }

                let entries = candidates
                    .sorted {
                        if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                        return $0.directoryName < $1.directoryName
                    }
                    .prefix(Self.maximumRecords)
                    .map(\.entry)
                return (entries, deletedMeetingIDs)
            }
        }
    }

    func delete(_ id: UUID, confirmed: Bool) throws {
        var tombstone: URL?
        try Self.mutationRegistry.withDelete(rootPath: rootURL.path, meetingID: id) {
            try withLock {
                guard confirmed else {
                    throw MeetingStoreError.deletionRequiresConfirmation
                }

                let directory = directoryURL(for: id)
                guard fileManager.fileExists(atPath: directory.path) else {
                    throw MeetingStoreError.meetingNotFound(id)
                }

                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeSymbolicLink else {
                    throw MeetingStoreError.unsafeStorePath(directory.lastPathComponent)
                }
                let deletionTombstone = deletionTombstoneURL(for: id)
                try fileManager.moveItem(at: directory, to: deletionTombstone)
                tombstone = deletionTombstone
            }
        }
        try failureInjector?(.afterAtomicDeletionRename)
        if let tombstone {
            try? fileManager.removeItem(at: tombstone)
        }
    }

    func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func load(id: UUID, from directory: URL) throws -> StoredMeeting {
        do {
            try requireSafeDirectory(directory)
        } catch {
            throw ClassifiedLoadError(reason: .unsafeEntry)
        }

        let meetingURL = directory.appendingPathComponent(Self.meetingFilename)
        let transcriptURL = directory.appendingPathComponent(Self.transcriptFilename)
        guard fileManager.fileExists(atPath: meetingURL.path) else {
            throw ClassifiedLoadError(reason: .missingMeeting)
        }
        guard isRegularFile(meetingURL) else {
            throw ClassifiedLoadError(reason: .unsafeEntry)
        }

        var meeting: MeetingRecord
        let usesLegacyTranscriptionSchema: Bool
        do {
            let meetingData = try Data(contentsOf: meetingURL)
            meeting = try Self.decoder().decode(
                MeetingRecord.self,
                from: meetingData
            )
            let object = try JSONSerialization.jsonObject(with: meetingData) as? [String: Any]
            usesLegacyTranscriptionSchema = object?["transcriptionState"] == nil
        } catch {
            throw ClassifiedLoadError(reason: .corruptMeeting)
        }
        guard meeting.id == id else {
            throw ClassifiedLoadError(reason: .mismatchedIdentifier)
        }
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            throw ClassifiedLoadError(reason: .missingTranscript)
        }
        guard isRegularFile(transcriptURL) else {
            throw ClassifiedLoadError(reason: .unsafeEntry)
        }

        let utterances: [MeetingUtterance]
        do {
            utterances = try Self.decoder().decode(
                [MeetingUtterance].self,
                from: Data(contentsOf: transcriptURL)
            )
        } catch {
            throw ClassifiedLoadError(reason: .corruptTranscript)
        }
        var orderedUtterances = utterances.sorted(by: MeetingUtterance.chronologicallyPrecedes)
        if Self.isRecoverableLegacyPlaceholderTranscript(
            meeting: meeting,
            utterances: orderedUtterances,
            usesLegacyTranscriptionSchema: usesLegacyTranscriptionSchema,
            directory: directory,
            fileManager: fileManager
        ) {
            meeting.transcriptionState = .failed
            meeting.transcriptionErrorMessage =
                "This older meeting contains an unavailable transcript. Retry from the saved recording."
            orderedUtterances.removeAll(where: Self.isLegacyUnavailableUtterance)
        }
        return StoredMeeting(meeting: meeting, utterances: orderedUtterances)
    }

    private static func isRecoverableLegacyPlaceholderTranscript(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        usesLegacyTranscriptionSchema: Bool,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard meeting.lifecycleState == .completed,
              meeting.transcriptionState == .completed,
              meeting.transcriptionAttemptCount == 0,
              usesLegacyTranscriptionSchema,
              utterances.contains(where: isLegacyUnavailableUtterance) else {
            return false
        }
        return hasValidRawCapture(
            in: directory,
            fileManager: fileManager
        ) || hasValidRetainedAudio(
            meeting: meeting,
            in: directory,
            fileManager: fileManager
        )
    }

    private static func isLegacyUnavailableUtterance(_ utterance: MeetingUtterance) -> Bool {
        utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == "[Transcript unavailable for this audio span.]"
    }

    private static func hasValidRawCapture(
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let manifestURL = directory
            .appendingPathComponent(MeetingAudioWriter.manifestFilename)
            .standardizedFileURL
        guard manifestURL.deletingLastPathComponent() == directory.standardizedFileURL,
              manifestURL.resolvingSymlinksInPath().standardizedFileURL == manifestURL,
              let attributes = try? fileManager.attributesOfItem(atPath: manifestURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: manifestURL),
              let capture = try? decoder().decode(MeetingAudioCaptureSummary.self, from: data),
              capture.tracks.count == MeetingAudioSource.allCases.count,
              Set(capture.tracks.map(\.source)) == Set(MeetingAudioSource.allCases),
              !capture.chunks.isEmpty else {
            return false
        }
        let tracks = Dictionary(
            uniqueKeysWithValues: capture.tracks.map { ($0.source, $0) }
        )
        guard capture.tracks.allSatisfy({ track in
            let url = track.fileURL.standardizedFileURL
            guard url.deletingLastPathComponent() == directory.standardizedFileURL,
                  url.lastPathComponent == "\(track.source.rawValue).f32le.pcm",
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  track.sampleRate == MeetingAudioWriter.sampleRate,
                  track.channelCount == MeetingAudioWriter.channelCount,
                  track.frameCount >= 0,
                  track.frameCount <= Int64.max / Int64(MemoryLayout<Float>.size),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                return false
            }
            return size == track.frameCount * Int64(MemoryLayout<Float>.size)
        }) else {
            return false
        }
        return capture.chunks.allSatisfy { chunk in
            guard chunk.timestampMilliseconds >= 0,
                  chunk.frameOffset >= 0,
                  chunk.frameCount > 0,
                  let track = tracks[chunk.source] else {
                return false
            }
            return chunk.frameOffset <= track.frameCount
                && Int64(chunk.frameCount) <= track.frameCount - chunk.frameOffset
        }
    }

    private static func hasValidRetainedAudio(
        meeting: MeetingRecord,
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let metadata = meeting.retainedAudio,
              AudioRetentionController.supports(metadata) else {
            return false
        }
        let url = directory.appendingPathComponent(metadata.filename).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL,
              url.resolvingSymlinksInPath().standardizedFileURL == url,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == metadata.sizeBytes,
              let audio = try? AVAudioFile(
                  forReading: url,
                  commonFormat: .pcmFormatFloat32,
                  interleaved: false
              ),
              audio.fileFormat.channelCount
                  == AVAudioChannelCount(AudioRetentionController.channelCount),
              Int(audio.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate,
              audio.length > 0 else {
            return false
        }
        let duration = Int64(
            (Double(audio.length) * 1_000 / Double(MeetingAudioWriter.sampleRate)).rounded()
        )
        return abs(duration - metadata.durationMilliseconds) <= 1
    }

    private func ensureDirectory(_ url: URL, permissions: Int) throws {
        if fileManager.fileExists(atPath: url.path) {
            try requireSafeDirectory(url)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private func requireSafeDirectory(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MeetingStoreError.unsafeStorePath(url.lastPathComponent)
        }
    }

    private func existingData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isRegularFile(url) else {
            throw MeetingStoreError.unsafeStorePath(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func deletionTombstoneURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(
            ".\(id.uuidString).\(UUID().uuidString).deleting",
            isDirectory: true
        )
    }

    static func withDeletionPrecedence<T>(
        rootURL: URL,
        meetingID: UUID,
        fileManager: FileManager,
        _ operation: () throws -> T
    ) throws -> T {
        let rootURL = rootURL.standardizedFileURL
        return try mutationRegistry.withSave(
            rootPath: rootURL.path,
            meetingID: meetingID,
            durableDeletionExists: {
                hasDeletionTombstone(
                    for: meetingID,
                    rootURL: rootURL,
                    fileManager: fileManager
                )
            },
            operation
        )
    }

    private static func hasDeletionTombstone(
        for id: UUID,
        rootURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: rootURL.path),
              let children = try? fileManager.contentsOfDirectory(
                  at: rootURL,
                  includingPropertiesForKeys: nil
              ) else {
            return false
        }
        return children.contains { child in
            Self.deletionTombstoneMeetingID(child.lastPathComponent) == id
                && isDirectoryOrSymbolicLink(child, fileManager: fileManager)
        }
    }

    private func cleanupDeletionTombstonesLocked() throws -> Set<UUID> {
        var deletedMeetingIDs = Set<UUID>()
        for child in try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) {
            guard let meetingID = Self.deletionTombstoneMeetingID(child.lastPathComponent),
                  isDirectoryOrSymbolicLink(child) else {
                continue
            }
            deletedMeetingIDs.insert(meetingID)
            try? fileManager.removeItem(at: child)
        }
        return deletedMeetingIDs
    }

    private func isDirectoryOrSymbolicLink(_ url: URL) -> Bool {
        Self.isDirectoryOrSymbolicLink(url, fileManager: fileManager)
    }

    private static func isDirectoryOrSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory || type == .typeSymbolicLink
    }

    private static func deletionTombstoneMeetingID(_ name: String) -> UUID? {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0].isEmpty,
              components[3] == "deleting",
              UUID(uuidString: String(components[2])) != nil else {
            return nil
        }
        return UUID(uuidString: String(components[1]))
    }

    private func stage(_ data: Data, for file: MeetingStoreFile, in directory: URL) throws -> URL {
        let temporary = directory.appendingPathComponent(
            ".\(file.rawValue).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw MeetingStoreError.atomicWriteFailed(file)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw MeetingStoreError.atomicWriteFailed(file)
        }
        return temporary
    }

    private func replace(
        _ staged: URL,
        at destination: URL,
        file: MeetingStoreFile,
        injectFailure: Bool
    ) throws {
        do {
            if injectFailure {
                try failureInjector?(.beforeAtomicReplacement(file))
            }
            try fileManager.moveReplacingItem(at: staged, to: destination)
        } catch {
            throw MeetingStoreError.atomicWriteFailed(file)
        }
    }

    private func restore(
        _ oldData: Data?,
        at destination: URL,
        file: MeetingStoreFile,
        in directory: URL
    ) throws {
        guard let oldData else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            return
        }
        let staged = try stage(oldData, for: file, in: directory)
        try replace(staged, at: destination, file: file, injectFailure: false)
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

private struct ListingCandidate {
    let entry: MeetingListEntry
    let sortDate: Date
    let directoryName: String
}

private struct ClassifiedLoadError: Error {
    let reason: UnavailableMeetingReason
}

private final class MeetingStoreMutationRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let rootPath: String
        let meetingID: UUID
    }

    private let lock = NSLock()
    private var deleted = Set<Key>()

    func withSave<T>(
        rootPath: String,
        meetingID: UUID,
        durableDeletionExists: () -> Bool,
        _ operation: () throws -> T
    ) throws -> T {
        try lock.withLock {
            let key = Key(rootPath: rootPath, meetingID: meetingID)
            if durableDeletionExists() {
                deleted.insert(key)
            }
            guard !deleted.contains(key) else {
                throw MeetingStoreError.meetingNotFound(meetingID)
            }
            return try operation()
        }
    }

    func withDelete<T>(
        rootPath: String,
        meetingID: UUID,
        _ operation: () throws -> T
    ) throws -> T {
        try lock.withLock {
            let result = try operation()
            deleted.insert(Key(rootPath: rootPath, meetingID: meetingID))
            return result
        }
    }

    func withReconciliation<T>(
        rootPath: String,
        _ operation: () throws -> (T, Set<UUID>)
    ) throws -> T {
        try lock.withLock {
            let (result, meetingIDs) = try operation()
            deleted.formUnion(meetingIDs.map {
                Key(rootPath: rootPath, meetingID: $0)
            })
            return result
        }
    }
}

private extension FileManager {
    func moveReplacingItem(at source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
