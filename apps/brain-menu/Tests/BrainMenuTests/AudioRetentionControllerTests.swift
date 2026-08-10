import AVFoundation
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct AudioRetentionControllerTests {
    @Test
    func alwaysRetainsRecordingAndCleansTemporaryAudioOnlyAfterPersistence() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let summary = try fixture.makeAudio()
        let temporaryURLs = summary.tracks.map(\.fileURL) + [fixture.manifestURL]

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        #expect(completed.retainedAudio != nil)
        #expect(try fixture.store.load(fixture.meeting.id).meeting == completed)
        #expect(temporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
    }

    @Test
    func voiceNoteRecordingPersistsUntilConfirmedDeletion() throws {
        let fixture = try AudioRetentionFixture(recordingKind: .voiceNote)
        let controller = fixture.controller()
        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        let beforeDeletion = try fixture.store.load(fixture.meeting.id)
        let beforeFiles = try FileManager.default.contentsOfDirectory(
            atPath: fixture.meetingDirectory.path
        ).sorted()

        #expect(completed.isVoiceNote)
        #expect(completed.retainedAudio?.filename == AudioRetentionController.retainedFilename)
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(throws: AudioRetentionControllerError.deletionRequiresConfirmation) {
            try controller.deleteRecording(for: completed.id, confirmed: false)
        }
        let survivedUnconfirmedDeletion = FileManager.default.fileExists(
            atPath: fixture.recordingURL.path
        )

        let deleted = try controller.deleteRecording(for: completed.id, confirmed: true)
        let afterDeletion = try fixture.store.load(fixture.meeting.id)
        let afterFiles = try FileManager.default.contentsOfDirectory(
            atPath: fixture.meetingDirectory.path
        ).sorted()

        #expect(survivedUnconfirmedDeletion)
        #expect(deleted.retainedAudio == nil)
        #expect(afterDeletion.utterances == fixture.utterances)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        try writeEvidence([
            "scenario": "Voice Note retained until explicit confirmed deletion",
            "recordingKind": beforeDeletion.meeting.recordingKind.rawValue,
            "retainedFilenameBeforeDeletion": completed.retainedAudio?.filename ?? "missing",
            "retainedFormatBeforeDeletion": completed.retainedAudio?.format ?? "missing",
            "directoryFilesBeforeDeletion": beforeFiles,
            "survivedUnconfirmedDeletion": survivedUnconfirmedDeletion,
            "recordingExistsAfterConfirmedDeletion": FileManager.default.fileExists(
                atPath: fixture.recordingURL.path
            ),
            "retainedMetadataClearedAfterConfirmedDeletion": afterDeletion.meeting.retainedAudio == nil,
            "transcriptPreservedAfterConfirmedDeletion": afterDeletion.utterances == fixture.utterances,
            "directoryFilesAfterDeletion": afterFiles,
        ], named: "voice-note-retention-deletion.json")
    }

    @Test
    func transcriptPersistenceFailurePreservesEveryTemporaryAudioFile() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let failingStore = MeetingStore(rootURL: fixture.rootURL) { event in
            if event == .beforeAtomicReplacement(.transcript) {
                throw InjectedAudioRetentionFailure()
            }
        }
        let controller = fixture.controller(store: failingStore)

        #expect(throws: AudioRetentionControllerError.transcriptPersistenceFailed) {
            try controller.finalize(
                meeting: fixture.meeting,
                utterances: fixture.utterances,
                audio: summary
            )
        }

        for track in summary.tracks {
            #expect(FileManager.default.fileExists(atPath: track.fileURL.path))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))

        let recordingFixture = try AudioRetentionFixture()
        let recordingSummary = try recordingFixture.makeAudio()
        let recordingFailure = FailingAudioRetentionFileSystem(failure: .permissions)
        let recordingController = recordingFixture.controller(fileSystem: recordingFailure)
        #expect(throws: AudioRetentionControllerError.recordingPersistenceFailed) {
            try recordingController.finalize(
                meeting: recordingFixture.meeting,
                utterances: recordingFixture.utterances,
                audio: recordingSummary
            )
        }
        for track in recordingSummary.tracks {
            #expect(FileManager.default.fileExists(atPath: track.fileURL.path))
        }
        #expect(FileManager.default.fileExists(atPath: recordingFixture.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: recordingFixture.recordingURL.path))
        let preserved = try recordingFixture.store.load(recordingFixture.meeting.id)
        #expect(preserved.meeting.transcriptionState == .processing)
        #expect(preserved.meeting.retainedAudio == nil)
        #expect(preserved.utterances == recordingFixture.utterances)
    }

    @Test
    func firstAttemptFinalTranscriptReplacesPreviewBeforeFallibleArchiving() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let preview = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10,
            text: "Earlier live preview.",
            baseSpeakerID: "you"
        )
        var processing = fixture.meeting
        processing.transcriptionState = .processing
        processing.transcriptionAttemptCount = 1
        try fixture.store.save(processing, utterances: [preview])

        #expect(throws: AudioRetentionControllerError.recordingPersistenceFailed) {
            try fixture.controller(
                fileSystem: FailingAudioRetentionFileSystem(failure: .permissions)
            ).finalize(
                meeting: processing,
                utterances: fixture.utterances,
                audio: summary
            )
        }

        let preserved = try fixture.store.load(fixture.meeting.id)
        #expect(preserved.meeting.transcriptionState == .processing)
        #expect(preserved.utterances == fixture.utterances)
        #expect(summary.tracks.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    @Test
    func firstAttemptFinalTranscriptPersistsBeforeAudioValidation() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let invalidSummary = MeetingAudioCaptureSummary(
            origin: summary.origin,
            originHostTimestamp: summary.originHostTimestamp,
            tracks: summary.tracks,
            chunks: [],
            discontinuities: summary.discontinuities,
            failures: summary.failures
        )
        let preview = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10,
            text: "Earlier live preview.",
            baseSpeakerID: "you"
        )
        var processing = fixture.meeting
        processing.transcriptionState = .processing
        processing.transcriptionAttemptCount = 1
        try fixture.store.save(processing, utterances: [preview])

        #expect(throws: AudioRetentionControllerError.invalidTemporaryAudio) {
            try fixture.controller().finalize(
                meeting: processing,
                utterances: fixture.utterances,
                audio: invalidSummary
            )
        }

        let preserved = try fixture.store.load(fixture.meeting.id)
        #expect(preserved.meeting.transcriptionState == .processing)
        #expect(preserved.utterances == fixture.utterances)
    }

    @Test
    func retryArchiveFailureRestoresPriorDurableMeetingSnapshot() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        var original = fixture.meeting
        original.transcriptionState = .completed
        original.transcriptionAttemptCount = 1
        original.analysisState = .completed
        original.uploadState = .delivered
        let archived = try controller.finalize(
            meeting: original,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        var retryCandidate = archived
        retryCandidate.title = "Replacement transcript title"
        retryCandidate.transcriptionAttemptCount = 2
        retryCandidate.analysisState = .notRequested
        retryCandidate.uploadState = .notUploaded
        let replacementUtterance = try MeetingUtterance(
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 500,
            text: "Replacement transcript.",
            baseSpeakerID: "remote"
        )
        let recordingFailure = SnapshottingRecordingFailureFileSystem(
            store: fixture.store,
            meetingID: fixture.meeting.id
        )

        #expect(throws: AudioRetentionControllerError.recordingPersistenceFailed) {
            try fixture.controller(
                fileSystem: recordingFailure
            ).finalize(
                meeting: retryCandidate,
                utterances: [replacementUtterance],
                audio: fixture.makeAudio()
            )
        }

        let stored = try fixture.store.load(fixture.meeting.id)
        let beforeRecordingCommit = try #require(recordingFailure.snapshot)
        #expect(beforeRecordingCommit.meeting == archived)
        #expect(beforeRecordingCommit.utterances == fixture.utterances)
        #expect(stored.meeting == archived)
        #expect(stored.utterances == fixture.utterances)
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
    }

    @Test
    func writesCompactPrivateM4AWithMicrophoneThenSystemChannels() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let frameCount = MeetingAudioWriter.sampleRate
        let summary = try fixture.makeAudio(
            microphone: [Float](repeating: 0.25, count: frameCount),
            system: [Float](repeating: -0.5, count: frameCount)
        )

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )
        let metadata = try #require(completed.retainedAudio)

        #expect(metadata.filename == AudioRetentionController.retainedFilename)
        #expect(metadata.format == AudioRetentionController.retainedFormat)
        #expect(metadata.channelCount == 2)
        #expect(metadata.durationMilliseconds == 1_000)
        #expect(metadata.sizeBytes > 0)
        #expect(metadata.sizeBytes < Int64(frameCount * 2 * MemoryLayout<Float>.size))
        #expect(try permissions(of: fixture.recordingURL) == 0o600)
        #expect(try permissions(of: fixture.meetingDirectory) == 0o700)
        #expect(summary.tracks.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        let files = try FileManager.default.contentsOfDirectory(
            atPath: fixture.meetingDirectory.path
        ).sorted()
        #expect(files == [
            MeetingStore.meetingFilename,
            MeetingStore.transcriptFilename,
            AudioRetentionController.retainedFilename,
        ].sorted())
        #expect(try fixture.store.load(fixture.meeting.id).meeting == completed)

        let recording = try AVAudioFile(
            forReading: fixture.recordingURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        #expect(recording.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(recording.fileFormat.channelCount == 2)
        #expect(Int(recording.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate)
        #expect(recording.length == AVAudioFramePosition(frameCount))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: recording.processingFormat,
            frameCapacity: AVAudioFrameCount(recording.length)
        ))
        try recording.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let midpoint = frameCount / 2
        #expect(abs(channels[AudioRetentionController.microphoneChannel - 1][midpoint] - 0.25) < 0.05)
        #expect(abs(channels[AudioRetentionController.systemAudioChannel - 1][midpoint] + 0.5) < 0.05)
        try writeEvidence([
            "scenario": "Completed Meeting archived as private compact local audio",
            "recordingKind": completed.recordingKind.rawValue,
            "retainedFilename": metadata.filename,
            "retainedFormat": metadata.format,
            "retainedSizeBytes": metadata.sizeBytes,
            "retainedDurationMilliseconds": metadata.durationMilliseconds,
            "channelCount": metadata.channelCount,
            "sampleRate": Int(recording.fileFormat.sampleRate.rounded()),
            "audioFormatID": recording.fileFormat.streamDescription.pointee.mFormatID,
            "recordingPermissions": String(try permissions(of: fixture.recordingURL), radix: 8),
            "directoryPermissions": String(try permissions(of: fixture.meetingDirectory), radix: 8),
            "temporarySourceAudioRemoved": summary.tracks.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.fileURL.path)
            },
            "persistedMeetingMatches": try fixture.store.load(fixture.meeting.id).meeting == completed,
            "directoryFiles": files,
        ], named: "meeting-retained-audio.json")
    }

    @Test
    func disposableCleanupFailureDoesNotDowngradePersistedTranscript() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let microphoneURL = try #require(
            summary.tracks.first(where: { $0.source == .microphone })?.fileURL
        )
        let systemURL = try #require(
            summary.tracks.first(where: { $0.source == .system })?.fileURL
        )
        let controller = fixture.controller(
            fileSystem: SelectiveCleanupFailureAudioRetentionFileSystem(
                failingFilename: microphoneURL.lastPathComponent
            )
        )

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(completed.transcriptionState == .completed)
        #expect(stored.meeting == completed)
        #expect(stored.utterances == fixture.utterances)
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        #expect(completed.retainedAudio != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
    }

    @Test
    func revealExportAndConfirmedDeleteAreFailureSafe() throws {
        let fixture = try AudioRetentionFixture()
        let revealer = RecordingRevealerSpy()
        let controller = fixture.controller(revealer: revealer)
        let summary = try fixture.makeAudio()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        try controller.revealRecording(for: fixture.meeting.id)
        #expect(revealer.revealedURLs == [fixture.recordingURL])

        let cancelled = try controller.exportRecording(for: fixture.meeting.id, to: nil)
        #expect(cancelled == nil)
        let exportURL = fixture.rootURL.appendingPathComponent("Selected export.m4a")
        #expect(try controller.exportRecording(
            for: fixture.meeting.id,
            to: exportURL
        ) == exportURL)
        #expect(try Data(contentsOf: exportURL) == Data(contentsOf: fixture.recordingURL))

        let failedExportURL = fixture.rootURL.appendingPathComponent("Failed export.caf")
        let exportFailure = FailingAudioRetentionFileSystem(failure: .copy)
        let exportFailingController = fixture.controller(fileSystem: exportFailure)
        #expect(throws: AudioRetentionControllerError.exportFailed) {
            try exportFailingController.exportRecording(
                for: fixture.meeting.id,
                to: failedExportURL
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(!FileManager.default.fileExists(atPath: failedExportURL.path))

        #expect(throws: AudioRetentionControllerError.deletionRequiresConfirmation) {
            try controller.deleteRecording(for: fixture.meeting.id, confirmed: false)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(try fixture.store.load(fixture.meeting.id).meeting.retainedAudio != nil)

        let microphoneURL = fixture.meetingDirectory.appendingPathComponent(
            "microphone.f32le.pcm"
        )
        let manifestURL = fixture.meetingDirectory.appendingPathComponent(
            MeetingAudioWriter.manifestFilename
        )
        let backupURL = fixture.meetingDirectory.appendingPathComponent(
            ".recording.\(UUID().uuidString).backup"
        )
        let recoveryURL = fixture.meetingDirectory.appendingPathComponent(
            ".recovery-\(UUID().uuidString)-microphone.pcm"
        )
        let transcriptionDirectory = fixture.meetingDirectory.appendingPathComponent(
            ".transcription",
            isDirectory: true
        )
        let wavURL = transcriptionDirectory.appendingPathComponent("final-microphone-0.wav")
        let unrelatedURL = transcriptionDirectory.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(
            at: transcriptionDirectory,
            withIntermediateDirectories: false
        )
        for url in [microphoneURL, manifestURL, backupURL, recoveryURL, wavURL, unrelatedURL] {
            try Data("private".utf8).write(to: url)
        }

        let deleteFailure = FailingAudioRetentionFileSystem(failure: .deleteRemoval)
        let deleteFailingController = fixture.controller(fileSystem: deleteFailure)
        #expect(throws: AudioRetentionControllerError.deleteFailed) {
            try deleteFailingController.deleteRecording(
                for: fixture.meeting.id,
                confirmed: true
            )
        }
        let pendingDeletion = try fixture.store.load(fixture.meeting.id).meeting
        #expect(pendingDeletion.audioRetentionState == .deleted)
        #expect(deleteFailingController.hasInterruptedDeletion(for: fixture.meeting.id))
        #expect(deleteFailingController.hasDeletableRecording(for: fixture.meeting.id))

        let deleted = try controller.deleteRecording(
            for: fixture.meeting.id,
            confirmed: true
        )

        #expect(deleted.retainedAudio == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        for url in [microphoneURL, manifestURL, backupURL, recoveryURL, wavURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
        #expect(try fixture.store.load(fixture.meeting.id).meeting.retainedAudio == nil)
        #expect(!controller.hasDeletableRecording(for: fixture.meeting.id))
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
    }

    @Test
    func launchReconciliationCompletesDurableAudioDeletionIntent() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        var processing = completed
        processing.transcriptionState = .processing
        try fixture.store.save(processing, utterances: fixture.utterances)
        let quarantine = fixture.meetingDirectory.appendingPathComponent(
            ".recording.\(UUID().uuidString).deleting",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        try FileManager.default.moveItem(
            at: fixture.recordingURL,
            to: quarantine.appendingPathComponent("0-\(fixture.recordingURL.lastPathComponent)")
        )

        let reconciled = controller.reconcileInterruptedDeletions()
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(reconciled.map(\.id) == [fixture.meeting.id])
        #expect(stored.meeting.transcriptionState == .failed)
        #expect(stored.meeting.transcriptionErrorMessage?.contains("deleted") == true)
        #expect(stored.meeting.retainedAudio == nil)
        #expect(stored.utterances == fixture.utterances)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!controller.hasInterruptedDeletion(for: fixture.meeting.id))
    }

    @Test
    func launchReconciliationCompletesLegacyFileDeletionIntent() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        let quarantine = fixture.meetingDirectory.appendingPathComponent(
            ".recording.\(UUID().uuidString).deleting",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: fixture.recordingURL, to: quarantine)

        let reconciled = controller.reconcileInterruptedDeletions()
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(reconciled.map(\.id) == [fixture.meeting.id])
        #expect(stored.meeting.transcriptionState == .completed)
        #expect(stored.meeting.retainedAudio == nil)
        #expect(stored.meeting.audioRetentionState == .deleted)
        #expect(stored.utterances == fixture.utterances)
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!controller.hasInterruptedDeletion(for: fixture.meeting.id))
    }

    @Test
    func deletingRecordingPreservesCompletedTranscriptWarning() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        var meeting = fixture.meeting
        meeting.transcriptionState = .completed
        meeting.transcriptionErrorMessage = "Transcript completed with 1 skipped audio span."
        let completed = try controller.finalize(
            meeting: meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        #expect(completed.transcriptionErrorMessage == meeting.transcriptionErrorMessage)

        let deleted = try controller.deleteRecording(
            for: fixture.meeting.id,
            confirmed: true
        )

        #expect(deleted.transcriptionState == .completed)
        #expect(deleted.transcriptionErrorMessage == meeting.transcriptionErrorMessage)
        #expect(deleted.retainedAudio == nil)
    }

    @Test
    func deletingAudioPreservesFailedTranscriptionMetadata() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        var failed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        failed.transcriptionState = .failed
        failed.transcriptionAttemptCount = 4
        failed.transcriptionErrorMessage = "Keep this retry failure."
        failed.analysisState = .completed
        failed.uploadState = .delivered
        try fixture.store.save(failed, utterances: fixture.utterances)

        let deleted = try controller.deleteRecording(
            for: fixture.meeting.id,
            confirmed: true
        )
        var expected = failed
        expected.retainedAudio = nil
        expected.audioRetentionState = .deleted

        #expect(deleted == expected)
        #expect(try fixture.store.load(fixture.meeting.id).meeting == expected)
    }

    @Test
    func confirmedDeletionRemovesInterruptedArchiveArtifactsWithoutCanonicalFile() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        let backup = fixture.meetingDirectory.appendingPathComponent(
            ".recording.interrupted.backup"
        )
        try FileManager.default.moveItem(at: fixture.recordingURL, to: backup)
        let staged = fixture.meetingDirectory.appendingPathComponent(
            ".recording.interrupted.m4a"
        )
        try Data("staged recording".utf8).write(to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: staged.path
        )

        let deleted = try controller.deleteRecording(
            for: completed.id,
            confirmed: true
        )

        #expect(deleted.audioRetentionState == .deleted)
        #expect(deleted.retainedAudio == nil)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.meetingDirectory,
            includingPropertiesForKeys: nil
        ).allSatisfy { !$0.lastPathComponent.hasSuffix(".deleting") })
    }

    @Test
    func sourceOnlyRecordingIsDiscoverableAndDeletable() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let capture = try fixture.makeAudio()
        var failed = fixture.meeting
        failed.transcriptionState = .failed
        failed.transcriptionAttemptCount = 1
        failed.transcriptionErrorMessage = "Keep this terminal failure."
        try fixture.store.save(failed, utterances: fixture.utterances)

        #expect(controller.hasDeletableRecording(for: failed.id))

        let deleted = try controller.deleteRecording(for: failed.id, confirmed: true)
        let stored = try fixture.store.load(failed.id)

        #expect(deleted.audioRetentionState == .deleted)
        #expect(deleted.transcriptionState == .failed)
        #expect(deleted.transcriptionErrorMessage == failed.transcriptionErrorMessage)
        #expect(stored.utterances == fixture.utterances)
        #expect(capture.tracks.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(!controller.hasDeletableRecording(for: failed.id))
    }

    @Test
    func activeRecordingAudioCannotBeDeleted() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let capture = try fixture.makeAudio()
        var active = fixture.meeting
        active.endedAt = nil
        active.lifecycleState = .recording
        try fixture.store.save(active, utterances: fixture.utterances)

        #expect(!controller.hasDeletableRecording(for: active.id))
        #expect(throws: AudioRetentionControllerError.deleteFailed) {
            try controller.deleteRecording(for: active.id, confirmed: true)
        }
        #expect(capture.tracks.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(try fixture.store.load(active.id).meeting == active)
    }

    @Test
    func launchReconciliationFinishesDeletionWithoutUsableMetadata() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        let quarantine = fixture.meetingDirectory.appendingPathComponent(
            ".recording.\(UUID().uuidString).deleting",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        try FileManager.default.moveItem(
            at: fixture.recordingURL,
            to: quarantine.appendingPathComponent("0-\(fixture.recordingURL.lastPathComponent)")
        )
        try FileManager.default.removeItem(at: fixture.meetingDirectory.appendingPathComponent(
            MeetingStore.meetingFilename
        ))

        let reconciled = controller.reconcileInterruptedDeletions()

        #expect(reconciled.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!controller.hasInterruptedDeletion(for: fixture.meeting.id))
    }

    @Test
    func failedRollbackKeepsQuarantineAndItsOnlyAudioCopy() throws {
        let fixture = try AudioRetentionFixture()
        _ = try fixture.controller().finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: fixture.makeAudio()
        )
        let failingStore = MeetingStore(rootURL: fixture.rootURL) { event in
            if event == .beforeAtomicReplacement(.meeting) {
                throw InjectedAudioRetentionFailure()
            }
        }
        let controller = fixture.controller(
            store: failingStore,
            fileSystem: RestorationFailureAudioRetentionFileSystem()
        )

        #expect(throws: AudioRetentionControllerError.deleteFailed) {
            try controller.deleteRecording(for: fixture.meeting.id, confirmed: true)
        }

        let stored = try fixture.store.load(fixture.meeting.id)
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: fixture.meetingDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".deleting") }
        let quarantine = try #require(quarantines.first)
        let quarantinedItems = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )

        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(stored.meeting.retainedAudio != nil)
        #expect(quarantinedItems.contains { $0.lastPathComponent.hasSuffix("recording.m4a") })
        #expect(controller.hasInterruptedDeletion(for: fixture.meeting.id))
    }

    @Test
    func retainedAudioNeverEntersCaptureRequestOrUploadSpy() async throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let summary = try fixture.makeAudio()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        let transcript = fixture.utterances.map(\.text).joined(separator: "\n")
        let request = BrainCaptureRequest(
            type: .transcript,
            source: "Brain.app",
            transcript: transcript,
            title: fixture.meeting.title
        )
        let spy = AudioRetentionCaptureSpy()
        _ = try await spy.capture(request, idempotencyKey: fixture.meeting.id)
        let captured = try #require(await spy.requests.first)
        let encoded = try JSONEncoder().encode(captured)
        let body = String(decoding: encoded, as: UTF8.self)

        #expect(captured == request)
        #expect(!body.contains(AudioRetentionController.retainedFilename))
        #expect(!body.contains(fixture.meetingDirectory.path))
        #expect(!body.contains("f32le.pcm"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["audio"] == nil)
        #expect(object["audio_url"] == nil)
        #expect(object["audio_path"] == nil)

        let controllerSource = try String(
            contentsOf: fixture.packageRoot
                .appendingPathComponent("Sources/BrainMenu/Meetings/AudioRetentionController.swift"),
            encoding: .utf8
        )
        #expect(!controllerSource.contains("BrainCaptureRequest"))
        #expect(!controllerSource.contains("MeetingUploadController"))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    private func writeEvidence(_ object: [String: Any], named filename: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BRAIN_TEST_EVIDENCE_DIR"] else {
            return
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(filename),
            options: .atomic
        )
    }
}

private final class AudioRetentionFixture {
    let rootURL: URL
    let store: MeetingStore
    let meeting: MeetingRecord
    let utterances: [MeetingUtterance]

    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var meetingDirectory: URL { store.directoryURL(for: meeting.id) }
    var manifestURL: URL {
        meetingDirectory.appendingPathComponent(MeetingAudioWriter.manifestFilename)
    }
    var recordingURL: URL {
        meetingDirectory.appendingPathComponent(AudioRetentionController.retainedFilename)
    }

    init(recordingKind: MeetingRecordingKind = .meeting) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrainAudioRetentionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = MeetingStore(rootURL: rootURL)
        meeting = MeetingRecord(
            title: "Private planning",
            recordingKind: recordingKind,
            detectedApplication: "com.example.meeting",
            startedAt: Date(timeIntervalSince1970: 1_784_112_400),
            endedAt: Date(timeIntervalSince1970: 1_784_112_401),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        utterances = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10,
            text: "Transcript text only.",
            baseSpeakerID: "you"
        )]
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func controller(
        store selectedStore: (any AudioRetentionMeetingStoring)? = nil,
        fileSystem: any AudioRetentionFileSystem = LocalAudioRetentionFileSystem(),
        revealer: any MeetingAudioRevealing = RecordingRevealerSpy()
    ) -> AudioRetentionController {
        AudioRetentionController(
            store: selectedStore ?? store,
            fileSystem: fileSystem,
            revealer: revealer
        )
    }

    func makeAudio(
        microphone: [Float] = [Float](repeating: 0.25, count: 160),
        system: [Float] = [Float](repeating: -0.5, count: 160)
    ) throws -> MeetingAudioCaptureSummary {
        let writer = try MeetingAudioWriter(
            meetingDirectory: meetingDirectory,
            origin: meeting.startedAt
        )
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .system,
            sourceTimestamp: 90,
            hostTimestamp: 10,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: system
        ))
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 900,
            hostTimestamp: 10,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: microphone
        ))
        return try writer.finalize()
    }
}

private final class RecordingRevealerSpy: MeetingAudioRevealing, @unchecked Sendable {
    private(set) var revealedURLs: [URL] = []

    func revealFile(_ url: URL) throws {
        revealedURLs.append(url)
    }
}

private final class FailingAudioRetentionFileSystem: AudioRetentionFileSystem, @unchecked Sendable {
    enum Failure {
        case copy
        case deleteRemoval
        case permissions
    }

    let failure: Failure
    private let base = LocalAudioRetentionFileSystem()

    init(failure: Failure) {
        self.failure = failure
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        if failure == .copy { throw InjectedAudioRetentionFailure() }
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        if failure == .deleteRemoval, url.lastPathComponent.hasSuffix(".deleting") {
            throw InjectedAudioRetentionFailure()
        }
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        if failure == .permissions { throw InjectedAudioRetentionFailure() }
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private final class SnapshottingRecordingFailureFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let base = LocalAudioRetentionFileSystem()
    private let store: MeetingStore
    private let meetingID: UUID
    private(set) var snapshot: StoredMeeting?

    init(store: MeetingStore, meetingID: UUID) {
        self.store = store
        self.meetingID = meetingID
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        snapshot = try store.load(meetingID)
        throw InjectedAudioRetentionFailure()
    }
}

private final class SelectiveCleanupFailureAudioRetentionFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let failingFilename: String
    private let base = LocalAudioRetentionFileSystem()

    init(failingFilename: String) {
        self.failingFilename = failingFilename
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingFilename {
            throw InjectedAudioRetentionFailure()
        }
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private final class RestorationFailureAudioRetentionFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let base = LocalAudioRetentionFileSystem()

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func createOwnerOnlyDirectory(at url: URL) throws {
        try base.createOwnerOnlyDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        if source.deletingLastPathComponent().lastPathComponent.hasSuffix(".deleting") {
            throw InjectedAudioRetentionFailure()
        }
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private actor AudioRetentionCaptureSpy: BrainCaptureAPI {
    private(set) var requests: [BrainCaptureRequest] = []

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        requests.append(capture)
        return BrainCaptureReceipt(id: idempotencyKey.uuidString, state: "queued")
    }
}

private struct InjectedAudioRetentionFailure: Error {}
