import AppKit
import AVFoundation
import Foundation

protocol AudioRetentionMeetingStoring {
    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws
    func load(_ id: UUID) throws -> StoredMeeting
    func directoryURL(for id: UUID) -> URL
}

extension MeetingStore: AudioRetentionMeetingStoring {}

protocol AudioRetentionFileSystem {
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
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
    static let keepMeetingRecordingsKey = "brain.meetings.keep-recordings"
    static let retainedFilename = "recording.caf"
    static let retainedFormat = "CAF/Linear PCM"
    static let channelCount = 2
    static let microphoneChannel = 1
    static let systemAudioChannel = 2

    private static let framesPerWrite = 8_192

    private let defaults: UserDefaults
    private let store: any AudioRetentionMeetingStoring
    private let fileSystem: any AudioRetentionFileSystem
    private let revealer: any MeetingAudioRevealing

    init(
        defaults: UserDefaults = .standard,
        store: any AudioRetentionMeetingStoring = MeetingStore(),
        fileSystem: any AudioRetentionFileSystem = LocalAudioRetentionFileSystem(),
        revealer: any MeetingAudioRevealing = FinderMeetingAudioRevealer()
    ) {
        self.defaults = defaults
        self.store = store
        self.fileSystem = fileSystem
        self.revealer = revealer
    }

    /// A missing preference is deliberately false, giving new installs a
    /// privacy-preserving default without writing any additional preference.
    var keepMeetingRecordings: Bool {
        get { defaults.object(forKey: Self.keepMeetingRecordingsKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.keepMeetingRecordingsKey) }
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
        let validated: ValidatedTemporaryAudio
        do {
            validated = try validateTemporaryAudio(audio, meetingID: meeting.id)
        } catch {
            throw AudioRetentionControllerError.invalidTemporaryAudio
        }

        do {
            try store.save(meeting, utterances: utterances)
        } catch {
            throw AudioRetentionControllerError.transcriptPersistenceFailed
        }

        guard keepMeetingRecordings else {
            cleanupTemporaryAudio(validated)
            return meeting
        }

        return try retain(
            meeting: meeting,
            utterances: utterances,
            audio: audio,
            validated: validated
        )
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
        let quarantine = source.deletingLastPathComponent().appendingPathComponent(
            ".recording.\(UUID().uuidString).deleting",
            isDirectory: false
        )

        var updated = stored.meeting
        updated.retainedAudio = nil

        do {
            try fileSystem.moveItem(at: source, to: quarantine)
        } catch {
            throw AudioRetentionControllerError.deleteFailed
        }

        do {
            try store.save(updated, utterances: stored.utterances)
        } catch {
            try? fileSystem.moveItem(at: quarantine, to: source)
            throw AudioRetentionControllerError.deleteFailed
        }

        do {
            try fileSystem.removeItem(at: quarantine)
            return updated
        } catch {
            // Restore both pieces when the destructive step fails. Even if the
            // metadata rollback itself fails, the last audio copy is retained.
            try? fileSystem.moveItem(at: quarantine, to: source)
            try? store.save(stored.meeting, utterances: stored.utterances)
            throw AudioRetentionControllerError.deleteFailed
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
            ".recording.\(UUID().uuidString).caf",
            isDirectory: false
        )
        let backup = directory.appendingPathComponent(
            ".recording.\(UUID().uuidString).backup",
            isDirectory: false
        )

        let metadata: RetainedAudioMetadata
        do {
            metadata = try Self.writeAndVerifyCAF(
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
            // The new CAF and its metadata are already durable. Leaving an
            // owner-only backup is safer than downgrading a completed
            // transcription when disposable-file cleanup fails.
            try? fileSystem.removeItem(at: backup)
        }

        cleanupTemporaryAudio(validated)
        return updated
    }

    /// Transcript (and, when selected, retained-CAF) persistence has committed
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
              metadata.filename == Self.retainedFilename,
              metadata.format == Self.retainedFormat,
              metadata.channelCount == Self.channelCount else {
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

    private func regularFileSize(at url: URL) throws -> Int64 {
        let attributes = try fileSystem.attributes(at: url)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw AudioRetentionControllerError.retainedAudioUnavailable
        }
        return size
    }

    private static func writeAndVerifyCAF(
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

        var fileSettings = format.settings
        fileSettings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
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
        // AVAudioFile finalizes its CAF header when released. Verify only after
        // that point so a short or malformed file can never become retained.
        output = nil

        try fileSystem.setOwnerOnlyPermissions(at: destination)
        let size = try regularFileSize(at: destination, fileSystem: fileSystem)
        let verification = try AVAudioFile(forReading: destination)
        guard verification.fileFormat.channelCount == AVAudioChannelCount(Self.channelCount),
              Int(verification.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate,
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
