import AppKit
import AVFoundation
import Foundation

protocol AudioRetentionMeetingStoring {
    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws
    func load(_ id: UUID) throws -> StoredMeeting
    func list() throws -> [MeetingListEntry]
    func directoryURL(for id: UUID) -> URL
}

extension MeetingStore: AudioRetentionMeetingStoring {}

protocol AudioRetentionFileSystem {
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func createOwnerOnlyDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func setOwnerOnlyPermissions(at url: URL) throws
}

struct LocalAudioRetentionFileSystem: AudioRetentionFileSystem {
    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}

protocol MeetingAudioRevealing {
    func revealFile(_ url: URL) throws
}

struct FinderMeetingAudioRevealer: MeetingAudioRevealing {
    func revealFile(_ url: URL) throws {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum AudioRetentionControllerError: Error, Equatable, LocalizedError, Sendable {
    case invalidTemporaryAudio
    case transcriptPersistenceFailed
    case recordingPersistenceFailed
    case temporaryCleanupFailed
    case retainedAudioUnavailable
    case revealFailed
    case exportFailed
    case deletionRequiresConfirmation
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .invalidTemporaryAudio:
            "The temporary meeting audio is incomplete or unsafe."
        case .transcriptPersistenceFailed:
            "The final transcript could not be stored, so temporary audio was preserved."
        case .recordingPersistenceFailed:
            "The private meeting recording could not be stored, so its source audio was preserved."
        case .temporaryCleanupFailed:
            "The final meeting was stored, but some temporary audio could not be removed."
        case .retainedAudioUnavailable:
            "The retained meeting recording is not available on this Mac."
        case .revealFailed:
            "The retained meeting recording could not be revealed in Finder."
        case .exportFailed:
            "The retained meeting recording could not be exported."
        case .deletionRequiresConfirmation:
            "Deleting a retained meeting recording requires explicit confirmation."
        case .deleteFailed:
            "The retained meeting recording could not be deleted safely."
        }
    }
}

/// Owns the post-transcription lifetime of meeting audio. This type has no
/// capture or upload dependency: audio is read only from a meeting's private
/// Application Support directory and is never represented by an API model.
final class AudioRetentionController: @unchecked Sendable {
    static let retainedFilename = "recording.m4a"
    static let retainedFormat = "M4A/AAC-LC"
    static let channelCount = 2
    static let microphoneChannel = 1
    static let systemAudioChannel = 2

    private static let legacyRetainedFilename = "recording.caf"
    private static let legacyRetainedFormat = "CAF/Linear PCM"
    private static let retainedBitRate = 48_000
    private static let framesPerWrite = 8_192

    private let store: any AudioRetentionMeetingStoring
    private let fileSystem: any AudioRetentionFileSystem
    private let revealer: any MeetingAudioRevealing

    init(
        store: any AudioRetentionMeetingStoring = MeetingStore(),
        fileSystem: any AudioRetentionFileSystem = LocalAudioRetentionFileSystem(),
        revealer: any MeetingAudioRevealing = FinderMeetingAudioRevealer()
    ) {
        self.store = store
        self.fileSystem = fileSystem
        self.revealer = revealer
    }

    /// Persists the final structured transcript before changing audio files.
    /// Upload availability is irrelevant here: subsequent delivery uses the
    /// already-persisted transcript and never any audio URL or bytes.
    @discardableResult
    func finalize(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        audio: MeetingAudioCaptureSummary
    ) throws -> MeetingRecord {
        let previous = try? store.load(meeting.id)
        let validated: ValidatedTemporaryAudio
        do {
            validated = try validateTemporaryAudio(audio, meetingID: meeting.id)
        } catch {
            throw AudioRetentionControllerError.invalidTemporaryAudio
        }

        var archiving = meeting
        archiving.transcriptionState = .processing
        do {
            try store.save(archiving, utterances: utterances)
        } catch {
            throw AudioRetentionControllerError.transcriptPersistenceFailed
        }

        do {
            return try retain(
                meeting: meeting,
                utterances: utterances,
                audio: audio,
                validated: validated
            )
        } catch {
            if let previous {
                try? store.save(previous.meeting, utterances: previous.utterances)
            }
            throw error
        }
    }

    @discardableResult
    func completeFinalTranscript(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        audio: MeetingAudioCaptureSummary
    ) throws -> MeetingRecord {
        try finalize(meeting: meeting, utterances: utterances, audio: audio)
    }

    func revealRecording(for meetingID: UUID) throws {
        let stored: StoredMeeting
        do {
            stored = try store.load(meetingID)
        } catch {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        let source = try retainedAudioURL(for: stored.meeting)
        do {
            try revealer.revealFile(source)
        } catch {
            throw AudioRetentionControllerError.revealFailed
        }
    }

    /// A nil destination represents a cancelled system save panel and performs
    /// no filesystem operation.
    @discardableResult
    func exportRecording(for meetingID: UUID, to destination: URL?) throws -> URL? {
        guard let destination else { return nil }

        let stored: StoredMeeting
        do {
            stored = try store.load(meetingID)
        } catch {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        let source = try retainedAudioURL(for: stored.meeting)
        let resolvedDestination = destination.standardizedFileURL
        guard resolvedDestination != source,
              !fileSystem.fileExists(at: resolvedDestination) else {
            throw AudioRetentionControllerError.exportFailed
        }

        do {
            try fileSystem.copyItem(at: source, to: resolvedDestination)
            let sourceSize = try regularFileSize(at: source)
            let destinationSize = try regularFileSize(at: resolvedDestination)
            guard sourceSize == destinationSize else {
                try? fileSystem.removeItem(at: resolvedDestination)
                throw AudioRetentionControllerError.exportFailed
            }
            return resolvedDestination
        } catch let error as AudioRetentionControllerError {
            throw error
        } catch {
            try? fileSystem.removeItem(at: resolvedDestination)
            throw AudioRetentionControllerError.exportFailed
        }
    }

    @discardableResult
    func deleteRecording(for meetingID: UUID, confirmed: Bool) throws -> MeetingRecord {
        guard confirmed else {
            throw AudioRetentionControllerError.deletionRequiresConfirmation
        }

        let stored: StoredMeeting
        do {
            stored = try store.load(meetingID)
        } catch {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        let source = try retainedAudioURL(for: stored.meeting)
        let directory = source.deletingLastPathComponent()
        let quarantine = directory.appendingPathComponent(
            ".recording.\(UUID().uuidString).deleting",
            isDirectory: true
        )
        let artifacts: [URL]
        do {
            artifacts = try audioArtifacts(in: directory)
            guard artifacts.contains(source.standardizedFileURL) else {
                throw AudioRetentionControllerError.deleteFailed
            }
            try fileSystem.createOwnerOnlyDirectory(at: quarantine)
        } catch {
            throw AudioRetentionControllerError.deleteFailed
        }
        let moves = artifacts.enumerated().map { index, artifact in
            AudioArtifactMove(
                original: artifact,
                quarantined: quarantine.appendingPathComponent(
                    "\(index)-\(artifact.lastPathComponent)",
                    isDirectory: false
                )
            )
        }

        let updated = Self.recordAfterDeletingAudio(stored.meeting)

        do {
            for move in moves {
                try fileSystem.moveItem(at: move.original, to: move.quarantined)
            }
        } catch {
            restore(moves, quarantine: quarantine)
            throw AudioRetentionControllerError.deleteFailed
        }

        do {
            try store.save(updated, utterances: stored.utterances)
        } catch {
            restore(moves, quarantine: quarantine)
            throw AudioRetentionControllerError.deleteFailed
        }

        do {
            try fileSystem.removeItem(at: quarantine)
            return updated
        } catch {
            restore(moves, quarantine: quarantine)
            if fileSystem.fileExists(at: source) {
                try? store.save(stored.meeting, utterances: stored.utterances)
            }
            throw AudioRetentionControllerError.deleteFailed
        }
    }

    @discardableResult
    func reconcileInterruptedDeletions() -> [MeetingRecord] {
        guard let entries = try? store.list() else { return [] }
        var reconciled: [MeetingRecord] = []

        for entry in entries {
            guard let meetingID = entry.id else { continue }
            let directory = store.directoryURL(for: meetingID).standardizedFileURL
            guard let quarantines = try? deletionQuarantines(in: directory) else { continue }

            switch entry {
            case .available:
                guard let stored = try? store.load(meetingID) else { continue }
                let hasDeletedAudioArtifacts = stored.meeting.audioRetentionState == .deleted
                    && ((try? audioArtifacts(in: directory).isEmpty) == false)
                guard !quarantines.isEmpty || hasDeletedAudioArtifacts else { continue }
                let updated = Self.recordAfterDeletingAudio(stored.meeting)
                guard (try? store.save(updated, utterances: stored.utterances)) != nil else {
                    continue
                }
                finishInterruptedDeletion(in: directory, quarantines: quarantines)
                reconciled.append(updated)
            case .unavailable:
                if !quarantines.isEmpty {
                    finishInterruptedDeletion(in: directory, quarantines: quarantines)
                }
            }
        }

        return reconciled
    }

    func hasInterruptedDeletion(for meetingID: UUID) -> Bool {
        let directory = store.directoryURL(for: meetingID).standardizedFileURL
        guard let entries = try? fileSystem.contentsOfDirectory(at: directory) else {
            return false
        }
        return entries.contains {
            Self.isDeletionQuarantineName($0.lastPathComponent)
        }
    }

    private func retain(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        audio: MeetingAudioCaptureSummary,
        validated: ValidatedTemporaryAudio
    ) throws -> MeetingRecord {
        let directory = store.directoryURL(for: meeting.id).standardizedFileURL
        let destination = directory.appendingPathComponent(Self.retainedFilename)
        let staged = directory.appendingPathComponent(
            ".recording.\(UUID().uuidString).m4a",
            isDirectory: false
        )
        let backup = directory.appendingPathComponent(
            ".recording.\(UUID().uuidString).backup",
            isDirectory: false
        )

        let metadata: RetainedAudioMetadata
        do {
            metadata = try Self.writeAndVerifyRecording(
                audio,
                validated: validated,
                destination: staged,
                fileSystem: fileSystem
            )
        } catch {
            try? fileSystem.removeItem(at: staged)
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }

        let hadPriorRecording = fileSystem.fileExists(at: destination)
        do {
            if hadPriorRecording {
                _ = try regularFileSize(at: destination)
                try fileSystem.moveItem(at: destination, to: backup)
            }
            try fileSystem.moveItem(at: staged, to: destination)
            _ = try regularFileSize(at: destination)
        } catch {
            try? fileSystem.removeItem(at: staged)
            if hadPriorRecording, fileSystem.fileExists(at: backup) {
                try? fileSystem.moveItem(at: backup, to: destination)
            }
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }

        var updated = meeting
        updated.retainedAudio = metadata
        updated.audioRetentionState = .retained
        do {
            try store.save(updated, utterances: utterances)
        } catch {
            try? fileSystem.removeItem(at: destination)
            if hadPriorRecording, fileSystem.fileExists(at: backup) {
                try? fileSystem.moveItem(at: backup, to: destination)
            }
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }

        if hadPriorRecording, fileSystem.fileExists(at: backup) {
            // The new recording and its metadata are already durable. Leaving an
            // owner-only backup is safer than downgrading a completed
            // transcription when disposable-file cleanup fails.
            try? fileSystem.removeItem(at: backup)
        }

        if let priorMetadata = meeting.retainedAudio,
           Self.supports(priorMetadata),
           priorMetadata.filename != Self.retainedFilename {
            let priorURL = directory.appendingPathComponent(priorMetadata.filename)
            if fileSystem.fileExists(at: priorURL) {
                try? fileSystem.removeItem(at: priorURL)
            }
        }

        cleanupTemporaryAudio(validated)
        return updated
    }

    /// Transcript and retained-audio persistence have committed
    /// before this runs. Cleanup is therefore best-effort: one failed deletion
    /// must not prevent the remaining disposable files from being removed or
    /// turn a durable transcript into a retryable transcription failure.
    private func cleanupTemporaryAudio(_ audio: ValidatedTemporaryAudio) {
        for track in audio.tracks.values where fileSystem.fileExists(at: track.fileURL) {
            try? fileSystem.removeItem(at: track.fileURL)
        }
        if fileSystem.fileExists(at: audio.manifestURL) {
            try? fileSystem.removeItem(at: audio.manifestURL)
        }
    }

    private func validateTemporaryAudio(
        _ audio: MeetingAudioCaptureSummary,
        meetingID: UUID
    ) throws -> ValidatedTemporaryAudio {
        let directory = store.directoryURL(for: meetingID).standardizedFileURL
        let expectedSources = Set(MeetingAudioSource.allCases)
        guard audio.tracks.count == expectedSources.count,
              Set(audio.tracks.map(\.source)) == expectedSources else {
            throw AudioRetentionControllerError.invalidTemporaryAudio
        }

        var tracks: [MeetingAudioSource: MeetingAudioTrack] = [:]
        for track in audio.tracks {
            let expectedName = "\(track.source.rawValue).f32le.pcm"
            let resolved = track.fileURL.standardizedFileURL
            guard resolved.deletingLastPathComponent() == directory,
                  resolved.lastPathComponent == expectedName,
                  resolved.resolvingSymlinksInPath().deletingLastPathComponent()
                    == directory.resolvingSymlinksInPath(),
                  track.sampleRate == MeetingAudioWriter.sampleRate,
                  track.channelCount == MeetingAudioWriter.channelCount,
                  track.frameCount >= 0,
                  try regularFileSize(at: resolved) == track.frameCount * Int64(MemoryLayout<Float>.size) else {
                throw AudioRetentionControllerError.invalidTemporaryAudio
            }
            tracks[track.source] = MeetingAudioTrack(
                source: track.source,
                fileURL: resolved,
                sampleRate: track.sampleRate,
                channelCount: track.channelCount,
                frameCount: track.frameCount
            )
        }

        guard audio.chunks.allSatisfy({ chunk in
            guard chunk.timestampMilliseconds >= 0,
                  chunk.frameOffset >= 0,
                  chunk.frameCount > 0,
                  let track = tracks[chunk.source] else { return false }
            return chunk.frameOffset <= track.frameCount
                && Int64(chunk.frameCount) <= track.frameCount - chunk.frameOffset
        }), !audio.chunks.isEmpty else {
            throw AudioRetentionControllerError.invalidTemporaryAudio
        }

        return ValidatedTemporaryAudio(
            tracks: tracks,
            manifestURL: directory.appendingPathComponent(MeetingAudioWriter.manifestFilename)
        )
    }

    private func retainedAudioURL(for meeting: MeetingRecord) throws -> URL {
        guard let metadata = meeting.retainedAudio,
              Self.supports(metadata) else {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        let directory = store.directoryURL(for: meeting.id).standardizedFileURL
        let url = directory.appendingPathComponent(metadata.filename).standardizedFileURL
        guard url.deletingLastPathComponent() == directory,
              try regularFileSize(at: url) == metadata.sizeBytes else {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        return url
    }

    static func supports(_ metadata: RetainedAudioMetadata) -> Bool {
        guard metadata.channelCount == Self.channelCount else { return false }
        return (metadata.filename, metadata.format) == (
            Self.retainedFilename,
            Self.retainedFormat
        ) || (metadata.filename, metadata.format) == (
            Self.legacyRetainedFilename,
            Self.legacyRetainedFormat
        )
    }

    private func audioArtifacts(in directory: URL) throws -> [URL] {
        let directory = directory.standardizedFileURL
        let transcriptionDirectory = directory.appendingPathComponent(
            ".transcription",
            isDirectory: true
        )
        var artifacts: [URL] = []
        for entry in try fileSystem.contentsOfDirectory(at: directory) {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory else {
                throw AudioRetentionControllerError.deleteFailed
            }
            if Self.isTopLevelAudioArtifact(candidate.lastPathComponent) {
                let type = try fileSystem.attributes(at: candidate)[.type] as? FileAttributeType
                guard type == .typeRegular || (
                    type == .typeDirectory
                        && candidate.lastPathComponent.hasSuffix(".deleting")
                ) else {
                    throw AudioRetentionControllerError.deleteFailed
                }
                artifacts.append(candidate)
            } else if candidate == transcriptionDirectory {
                guard try fileSystem.attributes(at: candidate)[.type] as? FileAttributeType
                        == .typeDirectory else {
                    throw AudioRetentionControllerError.deleteFailed
                }
                for entry in try fileSystem.contentsOfDirectory(at: candidate) {
                    let wav = entry.standardizedFileURL
                    let name = wav.lastPathComponent
                    guard wav.deletingLastPathComponent() == candidate else {
                        throw AudioRetentionControllerError.deleteFailed
                    }
                    guard name.hasSuffix(".wav"),
                          name.hasPrefix("preview-") || name.hasPrefix("final-") else {
                        continue
                    }
                    guard try fileSystem.attributes(at: wav)[.type] as? FileAttributeType
                            == .typeRegular else {
                        throw AudioRetentionControllerError.deleteFailed
                    }
                    artifacts.append(wav)
                }
            }
        }
        return artifacts.sorted { $0.path < $1.path }
    }

    private func deletionQuarantines(in directory: URL) throws -> [URL] {
        let directory = directory.standardizedFileURL
        return try fileSystem.contentsOfDirectory(at: directory)
            .filter { Self.isDeletionQuarantineName($0.lastPathComponent) }
            .map { quarantine in
                let quarantine = quarantine.standardizedFileURL
                let type = try fileSystem.attributes(at: quarantine)[.type]
                    as? FileAttributeType
                guard quarantine.deletingLastPathComponent() == directory,
                      type == .typeDirectory || type == .typeRegular else {
                    throw AudioRetentionControllerError.deleteFailed
                }
                return quarantine
            }
            .sorted { $0.path < $1.path }
    }

    private func finishInterruptedDeletion(in directory: URL, quarantines: [URL]) {
        guard let artifacts = try? audioArtifacts(in: directory) else { return }
        let quarantinePaths = Set(quarantines.map(\.standardizedFileURL))
        var removalFailed = false

        for artifact in artifacts where !quarantinePaths.contains(artifact.standardizedFileURL) {
            do {
                try fileSystem.removeItem(at: artifact)
            } catch {
                removalFailed = true
            }
        }
        guard !removalFailed else { return }
        for quarantine in quarantines {
            try? fileSystem.removeItem(at: quarantine)
        }
    }

    private static func isTopLevelAudioArtifact(_ name: String) -> Bool {
        if [
            Self.retainedFilename,
            Self.legacyRetainedFilename,
            "microphone.f32le.pcm",
            "system.f32le.pcm",
            MeetingAudioWriter.manifestFilename,
        ].contains(name) {
            return true
        }
        if name.hasPrefix(".recording.") {
            return [".backup", ".caf", ".m4a", ".deleting"].contains {
                name.hasSuffix($0)
            }
        }
        return name.hasPrefix(".recovery-")
            && [".pcm", ".json"].contains { name.hasSuffix($0) }
    }

    private static func isDeletionQuarantineName(_ name: String) -> Bool {
        name.hasPrefix(".recording.") && name.hasSuffix(".deleting")
    }

    private static func recordAfterDeletingAudio(_ meeting: MeetingRecord) -> MeetingRecord {
        var updated = meeting
        updated.retainedAudio = nil
        updated.audioRetentionState = .deleted
        return updated
    }

    private func restore(_ moves: [AudioArtifactMove], quarantine: URL) {
        var restoredAll = true
        for move in moves.reversed() where fileSystem.fileExists(at: move.quarantined) {
            guard !fileSystem.fileExists(at: move.original) else {
                restoredAll = false
                continue
            }
            do {
                try fileSystem.moveItem(at: move.quarantined, to: move.original)
            } catch {
                restoredAll = false
            }
        }
        if restoredAll,
           (try? fileSystem.contentsOfDirectory(at: quarantine).isEmpty) == true {
            try? fileSystem.removeItem(at: quarantine)
        }
    }

    private func regularFileSize(at url: URL) throws -> Int64 {
        let attributes = try fileSystem.attributes(at: url)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        return size
    }

    private static func writeAndVerifyRecording(
        _ summary: MeetingAudioCaptureSummary,
        validated: ValidatedTemporaryAudio,
        destination: URL,
        fileSystem: any AudioRetentionFileSystem
    ) throws -> RetainedAudioMetadata {
        let chunks = try preparedChunks(summary.chunks)
        guard let totalFrames = chunks.map(\.endFrame).max(), totalFrames > 0 else {
            throw AudioRetentionControllerError.invalidTemporaryAudio
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: false
        ) else {
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(MeetingAudioWriter.sampleRate),
            AVNumberOfChannelsKey: Self.channelCount,
            AVEncoderBitRateKey: Self.retainedBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: destination,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let handles = try Dictionary(
            uniqueKeysWithValues: validated.tracks.map { source, track in
                (source, try FileHandle(forReadingFrom: track.fileURL))
            }
        )
        defer {
            for handle in handles.values { try? handle.close() }
        }

        var outputStart: Int64 = 0
        while outputStart < totalFrames {
            let frameCount = Int(min(Int64(Self.framesPerWrite), totalFrames - outputStart))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channels = buffer.floatChannelData else {
                throw AudioRetentionControllerError.recordingPersistenceFailed
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for index in 0..<Self.channelCount {
                channels[index].initialize(repeating: 0, count: frameCount)
            }

            let outputEnd = outputStart + Int64(frameCount)
            for chunk in chunks where chunk.startFrame < outputEnd && chunk.endFrame > outputStart {
                guard let handle = handles[chunk.source] else {
                    throw AudioRetentionControllerError.invalidTemporaryAudio
                }
                let overlapStart = max(outputStart, chunk.startFrame)
                let overlapEnd = min(outputEnd, chunk.endFrame)
                let count = Int(overlapEnd - overlapStart)
                let sourceFrame = chunk.sourceFrameOffset + (overlapStart - chunk.startFrame)
                try handle.seek(toOffset: UInt64(sourceFrame) * UInt64(MemoryLayout<Float>.size))
                guard let data = try handle.read(upToCount: count * MemoryLayout<Float>.size),
                      data.count == count * MemoryLayout<Float>.size else {
                    throw AudioRetentionControllerError.invalidTemporaryAudio
                }

                let channelIndex = chunk.source == .microphone ? 0 : 1
                let destinationOffset = Int(overlapStart - outputStart)
                data.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        memcpy(
                            channels[channelIndex].advanced(by: destinationOffset),
                            baseAddress,
                            data.count
                        )
                    }
                }
            }

            guard let output else {
                throw AudioRetentionControllerError.recordingPersistenceFailed
            }
            try output.write(from: buffer)
            outputStart = outputEnd
        }
        // AVAudioFile finalizes its container when released. Verify only after
        // that point so a short or malformed file can never become retained.
        output = nil

        try fileSystem.setOwnerOnlyPermissions(at: destination)
        let size = try regularFileSize(at: destination, fileSystem: fileSystem)
        let verification = try AVAudioFile(forReading: destination)
        guard verification.fileFormat.channelCount == AVAudioChannelCount(Self.channelCount),
              Int(verification.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate,
              verification.fileFormat.streamDescription.pointee.mFormatID
                == kAudioFormatMPEG4AAC,
              verification.length == totalFrames,
              size > 0 else {
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }

        return RetainedAudioMetadata(
            filename: Self.retainedFilename,
            format: Self.retainedFormat,
            sizeBytes: size,
            durationMilliseconds: Int64(
                (Double(totalFrames) * 1_000 / Double(MeetingAudioWriter.sampleRate)).rounded()
            ),
            channelCount: Self.channelCount
        )
    }

    private static func preparedChunks(
        _ chunks: [MeetingAudioChunk]
    ) throws -> [PreparedAudioChunk] {
        try chunks.map { chunk in
            guard chunk.timestampMilliseconds <= Int64.max / Int64(MeetingAudioWriter.sampleRate),
                  chunk.frameCount > 0 else {
                throw AudioRetentionControllerError.invalidTemporaryAudio
            }
            let scaled = chunk.timestampMilliseconds * Int64(MeetingAudioWriter.sampleRate)
            guard scaled <= Int64.max - 500 else {
                throw AudioRetentionControllerError.invalidTemporaryAudio
            }
            let startFrame = (scaled + 500) / 1_000
            guard startFrame <= Int64.max - Int64(chunk.frameCount) else {
                throw AudioRetentionControllerError.invalidTemporaryAudio
            }
            return PreparedAudioChunk(
                source: chunk.source,
                startFrame: startFrame,
                endFrame: startFrame + Int64(chunk.frameCount),
                sourceFrameOffset: chunk.frameOffset
            )
        }
    }

    private static func regularFileSize(
        at url: URL,
        fileSystem: any AudioRetentionFileSystem
    ) throws -> Int64 {
        let attributes = try fileSystem.attributes(at: url)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw AudioRetentionControllerError.recordingPersistenceFailed
        }
        return size
    }
}

private struct ValidatedTemporaryAudio {
    let tracks: [MeetingAudioSource: MeetingAudioTrack]
    let manifestURL: URL
}

private struct PreparedAudioChunk {
    let source: MeetingAudioSource
    let startFrame: Int64
    let endFrame: Int64
    let sourceFrameOffset: Int64
}

private struct AudioArtifactMove {
    let original: URL
    let quarantined: URL
}
