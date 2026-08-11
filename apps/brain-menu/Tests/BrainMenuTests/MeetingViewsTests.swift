import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct MeetingViewsTests {
    @Test
    func listRendersNewestFirstAllBadgesAndSearchesOnlyCachedLocalContent() throws {
        let oldID = UUID()
        let newID = UUID()
        let old = meeting(
            id: oldID,
            title: "Older sync",
            start: Date(timeIntervalSince1970: 1_000),
            retainedAudio: nil
        )
        var newest = meeting(
            id: newID,
            title: "Roadmap",
            start: Date(timeIntervalSince1970: 2_000),
            retainedAudio: RetainedAudioMetadata(
                filename: "recording.caf",
                format: "CAF/Linear PCM",
                sizeBytes: 42,
                durationMilliseconds: 3_000
            )
        )
        newest.analysisState = .completed
        newest.uploadState = .delivered
        let transcript = try utterances()
        let analysis = analysisFixture(utteranceID: transcript[0].id)
        let speakerState = SpeakerEditingState(
            assignments: [
                transcript[0].id: SpeakerAssignment(speakerID: "owner", provenance: .manual),
            ],
            speakers: ["owner": MeetingSpeaker(id: "owner", displayName: "Alice Jones")]
        )
        let store = MemoryMeetingViewStore(values: [
            oldID: StoredMeeting(meeting: old, utterances: []),
            newID: StoredMeeting(meeting: newest, utterances: transcript),
        ], listOrder: [oldID, newID])
        let analyses = MemoryMeetingViewAnalysisStore(values: [
            newID: StoredMeetingAnalysis(analysis: analysis, speakerState: speakerState),
        ])
        let controller = MeetingsController(
            store: store,
            analysisStore: analyses,
            now: { Date(timeIntervalSince1970: 5_000) }
        )

        controller.load()

        #expect(controller.state == .loaded)
        #expect(controller.rows.map(\.id) == [newID, oldID])
        #expect(controller.rows[0].badges.map(\.kind) == [
            .recording,
            .transcription,
            .analysis,
            .audio,
            .upload,
        ])
        #expect(controller.rows[0].badges.allSatisfy { !$0.accessibilityLabel.isEmpty })
        #expect(controller.rows[0].accessibilityLabel.contains("Upload status: Delivered"))

        for term in ["roadmap", "Alice Jones", "concise summary", "launch timing"] {
            controller.query = term
            #expect(controller.viewModel.visibleRows.map(\.id) == [newID])
        }
        controller.query = "not on this mac"
        #expect(controller.viewModel.hasNoSearchResults)
        #expect(store.listCalls == 1)
        #expect(store.loadCalls == 2)
    }

    @Test
    func voiceNotesAndMeetingsAppearOnlyInTheirOwnLibraries() {
        let meetingID = UUID()
        let voiceNoteID = UUID()
        let meeting = meeting(
            id: meetingID,
            title: "Planning",
            start: Date(timeIntervalSince1970: 1_000)
        )
        let voiceNote = MeetingRecord(
            id: voiceNoteID,
            title: "Voice note",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endedAt: Date(timeIntervalSince1970: 2_060),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        let controller = MeetingsController(
            store: MemoryMeetingViewStore(values: [
                meetingID: StoredMeeting(meeting: meeting, utterances: []),
                voiceNoteID: StoredMeeting(meeting: voiceNote, utterances: []),
            ], listOrder: [meetingID, voiceNoteID]),
            analysisStore: MemoryMeetingViewAnalysisStore()
        )

        controller.load()

        #expect(controller.viewModel.visibleRows(in: .meetings).map(\.id) == [meetingID])
        #expect(controller.viewModel.visibleRows(in: .voiceNotes).map(\.id) == [voiceNoteID])
        #expect(controller.viewModel.visibleRows(in: .voiceNotes).first?.accessibilityLabel
            .contains("New voice note") == true)
        #expect(MeetingLibraryScope.meetings.loadingTitle == "Loading meetings")
        #expect(MeetingLibraryScope.voiceNotes.loadingTitle == "Loading voice notes")
        #expect(MeetingLibraryScope.meetings.loadingAccessibilityLabel
            == "Loading local meetings and processing states")
        #expect(MeetingLibraryScope.voiceNotes.loadingAccessibilityLabel
            == "Loading local voice notes and processing states")

        controller.query = "planning"
        #expect(controller.viewModel.visibleRows(in: .meetings).map(\.id) == [meetingID])
        #expect(controller.viewModel.visibleRows(in: .voiceNotes).isEmpty)
        #expect(controller.viewModel.hasNoSearchResults(in: .voiceNotes))
    }

    @Test
    func listRepresentsLoadingEmptyCorruptAndStoreFailure() {
        let empty = MeetingsController(
            store: MemoryMeetingViewStore(),
            analysisStore: MemoryMeetingViewAnalysisStore()
        )
        #expect(empty.state == .idle)
        empty.load()
        #expect(empty.viewModel.isEmpty)

        let unavailable = UnavailableMeeting(
            id: UUID(),
            directoryName: "broken-entry",
            reason: .corruptTranscript
        )
        let corrupt = MeetingsController(
            store: MemoryMeetingViewStore(extraEntries: [.unavailable(unavailable)]),
            analysisStore: MemoryMeetingViewAnalysisStore()
        )
        corrupt.load()
        #expect(corrupt.rows.first?.isAvailable == false)
        #expect(corrupt.rows.first?.badges.first?.kind == .corrupt)
        #expect(corrupt.rows.first?.unavailableReason?.contains("transcript is corrupt") == true)

        let failed = MeetingsController(
            store: MemoryMeetingViewStore(listError: TestMeetingViewError.failed),
            analysisStore: MemoryMeetingViewAnalysisStore()
        )
        failed.load()
        guard case .failed(let message) = failed.state else {
            Issue.record("Expected an explicit list failure")
            return
        }
        #expect(message.contains("test failure"))
    }

    @Test
    func newMeetingStaysUnreadUntilOpenedThenPersistsAndLosesNewBadge() {
        let id = UUID()
        let record = meeting(id: id, title: "Fresh planning", start: .now)
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: []),
        ])
        let controller = MeetingsController(
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore()
        )

        controller.load()
        #expect(controller.rows.first?.isUnread == true)
        #expect(controller.rows.first?.accessibilityLabel.contains("New meeting") == true)

        controller.markOpened(id)

        #expect(store.values[id]?.meeting.isUnread == false)
        #expect(controller.rows.first?.isUnread == false)
    }

    @Test
    func waveformModelUsesRealBoundedHistoryAndSilentAudioIsNotReceiving() {
        let history = MeetingLevelWaveformModel(
            samples: [-1, 0.2, 2],
            currentLevel: nil,
            barCount: 5
        )
        #expect(history.displaySamples == [0, 0, 0, 0.2, 1])

        let fallback = MeetingLevelWaveformModel(
            samples: [],
            currentLevel: 0.5,
            barCount: 3
        )
        #expect(fallback.displaySamples == [0, 0, 0.5])

        let quiet = RecordingIslandMeetingPresentation(
            phase: .recording,
            title: "Audio check",
            startedAt: Date(timeIntervalSince1970: 100),
            microphoneLevel: 0,
            systemLevel: 0,
            microphoneHistory: [0, 0],
            systemHistory: [0, 0],
            microphoneSignalState: .quiet,
            systemSignalState: .quiet
        )
        #expect(!quiet.isReceivingAudio)
        #expect(quiet.audioStatusText == "Connected — waiting for sound…")

        let microphoneOnly = RecordingIslandMeetingPresentation(
            phase: .recording,
            title: "Audio check",
            startedAt: Date(timeIntervalSince1970: 100),
            microphoneLevel: 0.4,
            systemLevel: 0,
            microphoneSignalState: .active,
            systemSignalState: .quiet
        )
        #expect(microphoneOnly.isReceivingAudio)
        #expect(microphoneOnly.audioStatusText == "Receiving microphone audio…")

        let voiceNoteStop = RecordingIslandMeetingPresentation(
            phase: .stopSuggested,
            title: "Field note",
            recordingKind: .voiceNote,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(voiceNoteStop.phaseTitle == "Finish this voice note?")
    }

    @Test
    func liveModelRendersChronologicalTranscriptLevelsLagAndOnlyValidControls() async throws {
        let transcript = try utterances().reversed()
        let activeMeeting = meeting(
            title: "Design review",
            start: Date(timeIntervalSince1970: 100)
        )
        let lag = LiveTranscriptPreviewLagState.lagging(
            droppedChunksBySource: [.system: 2]
        )
        let failure = LiveTranscriptFailure(
            source: .microphone,
            phase: .preview,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            message: "model unavailable"
        )
        let model = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .recording,
            utterances: Array(transcript),
            previewLag: lag,
            transcriptFailures: [failure],
            controllerFailure: nil,
            levels: [.microphone: 1.2, .system: -0.4],
            signalStates: [.microphone: .active, .system: .quiet],
            audioGuidance: [
                .microphone: "No voice signal detected on the selected microphone.",
            ],
            now: Date(timeIntervalSince1970: 165)
        ))

        #expect(model.state == .active)
        #expect(model.elapsedText == "1:05")
        #expect(model.audioStatusText == "Receiving microphone audio.")
        #expect(model.isReceivingAudio)
        #expect(model.transcript.map(\.text) == ["Launch timing", "Looks good"])
        #expect(model.levels.map(\.level) == [1, 0])
        #expect(model.levels.allSatisfy { $0.accessibilityLabel.contains("percent") })
        #expect(model.previewMessage?.contains("2 system audio chunks") == true)
        #expect(model.errorMessages == [
            "Microphone preview: model unavailable",
            "No voice signal detected on the selected microphone.",
        ])
        #expect(model.actions == [.pause, .stop])

        let starting = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .starting,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [:],
            now: activeMeeting.startedAt
        ))
        #expect(starting.actions == [.stop])
        #expect(starting.audioStatusText == "Waiting for audio.")
        #expect(!starting.isReceivingAudio)

        let connectedButQuiet = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .recording,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [.microphone: 0, .system: 0],
            signalStates: [.microphone: .quiet, .system: .quiet],
            now: activeMeeting.startedAt
        ))
        #expect(connectedButQuiet.audioStatusText == "Connected — waiting for sound.")
        #expect(!connectedButQuiet.isReceivingAudio)

        let actions = MeetingLiveActionSpy()
        await model.dispatch(.pause, to: actions)
        await model.dispatch(.stop, to: actions)
        await model.dispatch(.resume, to: actions)
        #expect(actions.actions == [.pause, .stop])

        let paused = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .paused,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [:],
            now: activeMeeting.startedAt
        ))
        #expect(paused.actions == [.resume, .stop])

        let final = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .completed,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [:],
            now: activeMeeting.startedAt
        ))
        #expect(final.state == .completed)
        #expect(final.actions.isEmpty)

        let error = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: activeMeeting,
            lifecycleState: .failed,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: .eightHourSafetyLimit,
            levels: [:],
            now: activeMeeting.startedAt
        ))
        guard case .failed(let message) = error.state else {
            Issue.record("Expected explicit live failure")
            return
        }
        #expect(message.contains("preserved for recovery"))
    }

    @Test
    func detailDispatchesSpeakerTalkTimeAnalysisCopyAudioUploadAndConfirmedDeletion() async throws {
        let id = UUID()
        let transcript = try utterances()
        let record = meeting(
            id: id,
            title: "Planning",
            start: Date(timeIntervalSince1970: 10),
            retainedAudio: RetainedAudioMetadata(
                filename: "recording.caf",
                format: "CAF/Linear PCM",
                sizeBytes: 100,
                durationMilliseconds: 3_000
            )
        )
        let analysis = analysisFixture(utteranceID: transcript[0].id)
        let storedAnalysis = StoredMeetingAnalysis(
            analysis: analysis,
            speakerState: SpeakerEditingState()
        )
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: transcript),
        ])
        let analyses = MemoryMeetingViewAnalysisStore(values: [id: storedAnalysis])
        let analysisActions = MeetingDetailAnalysisSpy(result: MeetingAnalysisRunResult(
            meeting: record,
            utterances: transcript,
            speakerState: SpeakerEditor(utterances: transcript).state,
            analysis: analysis,
            failure: nil
        ))
        let upload = MeetingDetailUploadSpy()
        upload.canRetry = false
        let uploadStore = MemoryMeetingViewUploadStore(value: MeetingUploadRevision(
            meetingID: id,
            revision: 1,
            transcriptDigest: "digest",
            idempotencyKey: UUID(),
            request: BrainCaptureRequest(
                type: .transcript,
                source: "Brain.app meeting",
                transcript: "transcript",
                title: "Planning"
            ),
            state: .failed,
            captureID: "capture-1",
            retryable: true,
            retryMode: .post,
            lastError: "offline",
            updatedAt: .now
        ))
        let audio = MeetingDetailAudioSpy(meeting: record)
        let clipboard = MeetingClipboardSpy()
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: analyses,
            analysisController: analysisActions,
            uploadController: upload,
            uploadStore: uploadStore,
            audioController: audio,
            audioChecker: FixedAudioChecker(value: true),
            clipboard: clipboard
        )

        controller.load()
        #expect(controller.state == .ready)
        #expect(controller.viewModel.transcript.map(\.text) == ["Launch timing", "Looks good"])
        #expect(controller.viewModel.talkTime.count == 2)
        #expect(controller.viewModel.talkTime.allSatisfy { !$0.accessibilityLabel.isEmpty })
        #expect(controller.viewModel.audioControls == [.reveal, .export, .delete])
        #expect(controller.viewModel.badges.first { $0.kind == .upload }?.title == "Upload failed")
        #expect(controller.viewModel.uploadCanRetry)

        await controller.perform(.renameSpeaker(id: "you", name: "the owner"))
        #expect(controller.viewModel.speakers.contains { $0.displayName == "the owner" })
        await controller.perform(.reassign(utteranceIDs: [transcript[1].id], to: "you"))
        #expect(controller.viewModel.talkTime.count == 1)
        await controller.perform(.split(
            speakerID: "you",
            utteranceIDs: [transcript[1].id],
            name: "Guest"
        ))
        #expect(controller.viewModel.speakers.contains { $0.displayName == "Guest" })
        await controller.perform(.undoSpeakerEdit)
        #expect(!controller.viewModel.speakers.contains { $0.displayName == "Guest" })
        await controller.perform(.mergeSpeakers(sourceIDs: ["remote"], into: "you"))

        await controller.perform(.reanalyze)
        #expect(analysisActions.reanalysisCalls == 1)
        await controller.perform(.analyze)
        #expect(analysisActions.analysisCalls == 1)

        await controller.perform(.copyDraft(.subject))
        await controller.perform(.copyDraft(.body))
        await controller.perform(.copyDraft(.all))
        #expect(clipboard.values == [
            "Follow up",
            "Thanks for the review.",
            "Subject: Follow up\n\nThanks for the review.",
        ])

        await controller.perform(.revealAudio)
        await controller.perform(.exportAudio(URL(fileURLWithPath: "/tmp/export.caf")))
        #expect(audio.revealCalls == 1)
        #expect(audio.exports.map(\.path) == ["/tmp/export.caf"])
        await controller.perform(.requestAudioDeletion)
        #expect(audio.deleteCalls == 0)
        #expect(controller.viewModel.audioDeletionWarning?.contains("saved recording") == true)
        await controller.perform(.confirmAudioDeletion)
        #expect(audio.deleteCalls == 1)

        await controller.perform(.retryUpload)
        await controller.perform(.reupload)
        #expect(upload.retries == [id])
        #expect(upload.reuploads == [id])

        await controller.perform(.requestMeetingDeletion)
        #expect(store.deleteConfirmations.isEmpty)
        #expect(controller.viewModel.meetingDeletionWarning?.contains("does not retract") == true)
        await controller.perform(.confirmMeetingDeletion)
        #expect(store.deleteConfirmations == [true])
        #expect(controller.state == .deleted)
    }

    @Test
    func detailRequiresLocalAudioAndConfirmationAndShowsCorruptOrErrorState() async throws {
        let id = UUID()
        let record = meeting(id: id, title: "No audio", start: .now)
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: []),
        ])
        let audio = MeetingDetailAudioSpy(meeting: record)
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: audio,
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )
        controller.load()
        #expect(controller.viewModel.audioControls.isEmpty)
        await controller.perform(.revealAudio)
        await controller.perform(.requestAudioDeletion)
        #expect(audio.revealCalls == 0)
        #expect(!controller.isAudioDeletionPending)

        let corrupt = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(loadError: MeetingStoreError.corruptMeeting(
                id,
                .corruptTranscript
            )),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: audio,
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )
        corrupt.load()
        guard case .corrupt = corrupt.state else {
            Issue.record("Expected corrupt meeting state")
            return
        }

        let failed = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(loadError: TestMeetingViewError.failed),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: audio,
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )
        failed.load()
        guard case .failed(let message) = failed.state else {
            Issue.record("Expected detail error state")
            return
        }
        #expect(message.contains("test failure"))
    }

    @Test
    func voiceNoteDetailKeepsItsKindThroughRenameValidationAndDeletion() async throws {
        let id = UUID()
        let record = MeetingRecord(
            id: id,
            title: "Field note",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: []),
        ])
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )

        controller.load()
        await controller.perform(.saveTitle("Renamed thought"))
        #expect(store.values[id]?.meeting.recordingKind == .voiceNote)
        #expect(controller.viewModel.isVoiceNote)

        await controller.perform(.saveTitle("   "))
        #expect(controller.viewModel.errorMessage == "A voice note title cannot be empty.")

        await controller.perform(.requestMeetingDeletion)
        await controller.perform(.confirmMeetingDeletion)
        #expect(controller.state == .deleted)
        #expect(controller.viewModel.isVoiceNote)
    }

    @Test
    func voiceNoteTranscriptIsPlainParagraphTextAndCopiesInFull() async throws {
        let id = UUID()
        let record = MeetingRecord(
            id: id,
            title: "Product thought",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        let utterances = [
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                text: "  The first   sentence. ",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 1_200,
                endMilliseconds: 2_000,
                text: "It continues here.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 4_000,
                endMilliseconds: 5_000,
                text: "This is a new thought.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 6_000,
                endMilliseconds: 7_000,
                text: "Hidden correction",
                baseSpeakerID: "you",
                suppressed: true
            ),
        ]
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: utterances),
        ])
        let clipboard = MeetingClipboardSpy()
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: clipboard
        )

        controller.load()

        #expect(controller.viewModel.tab == .transcript)
        #expect(controller.viewModel.voiceNoteTranscript.paragraphs == [
            "The first sentence. It continues here.",
            "This is a new thought.",
        ])
        #expect(controller.viewModel.voiceNoteTranscript.fullText
            == "The first sentence. It continues here.\n\nThis is a new thought.")

        await controller.perform(.copyFullTranscript)

        #expect(clipboard.values == [
            "The first sentence. It continues here.\n\nThis is a new thought.",
        ])
        #expect(controller.viewModel.copiedMessage == "Full transcript copied")
    }

    @Test
    func detailViewsRenderVoiceNoteReadingAndMeetingSpeakerWorkflows() async throws {
        let voiceNoteID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        var voiceNote = MeetingRecord(
            id: voiceNoteID,
            title: "Launch narrative",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 1_786_339_800),
            endedAt: Date(timeIntervalSince1970: 1_786_339_866),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        voiceNote.transcriptionState = .completed
        voiceNote.retainedAudio = RetainedAudioMetadata(
            filename: AudioRetentionController.retainedFilename,
            format: AudioRetentionController.retainedFormat,
            sizeBytes: 24_000,
            durationMilliseconds: 66_000
        )
        let voiceNoteUtterances = [
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 1_100,
                text: "The launch story should begin with the customer's problem.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 1_250,
                endMilliseconds: 2_500,
                text: "Then explain why the current workaround is too slow.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 4_500,
                endMilliseconds: 6_200,
                text: "The closing paragraph should make the next action unmistakable.",
                baseSpeakerID: "you"
            ),
        ]
        let voiceNoteClipboard = MeetingClipboardSpy()
        let voiceNoteController = MeetingDetailController(
            meetingID: voiceNoteID,
            store: MemoryMeetingViewStore(values: [
                voiceNoteID: StoredMeeting(
                    meeting: voiceNote,
                    utterances: voiceNoteUtterances
                ),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: voiceNote),
            audioChecker: FixedAudioChecker(value: true),
            clipboard: voiceNoteClipboard
        )
        voiceNoteController.load()
        await voiceNoteController.perform(.copyFullTranscript)

        #expect(voiceNoteController.viewModel.tab == .transcript)
        #expect(voiceNoteController.viewModel.copiedMessage == "Full transcript copied")
        #expect(voiceNoteClipboard.values == [
            "The launch story should begin with the customer's problem. "
                + "Then explain why the current workaround is too slow.\n\n"
                + "The closing paragraph should make the next action unmistakable.",
        ])
        try renderEvidence(
            MeetingDetailView(controller: voiceNoteController),
            named: "voice-note-transcript.png"
        )

        let meetingID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
        let ownerUtteranceID = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
        let guestUtteranceID = UUID(uuidString: "B0000000-0000-0000-0000-000000000003")!
        var meetingRecord = MeetingRecord(
            id: meetingID,
            title: "Monday planning",
            titleSource: .application,
            detectedApplication: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_786_339_800),
            endedAt: Date(timeIntervalSince1970: 1_786_339_866),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        meetingRecord.transcriptionState = .completed
        meetingRecord.retainedAudio = RetainedAudioMetadata(
            filename: AudioRetentionController.retainedFilename,
            format: AudioRetentionController.retainedFormat,
            sizeBytes: 24_000,
            durationMilliseconds: 66_000
        )
        let meetingUtterances = [
            try MeetingUtterance(
                id: ownerUtteranceID,
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 2_000,
                text: "I will send the revised launch brief this afternoon.",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                id: guestUtteranceID,
                source: .system,
                startMilliseconds: 2_400,
                endMilliseconds: 4_600,
                text: "Great, I will confirm the customer quotes before then.",
                baseSpeakerID: "remote"
            ),
        ]
        let speakerState = SpeakerEditingState(
            assignments: [
                ownerUtteranceID: SpeakerAssignment(
                    speakerID: "owner",
                    provenance: .manual
                ),
                guestUtteranceID: SpeakerAssignment(
                    speakerID: "guest",
                    provenance: .manual
                ),
            ],
            speakers: [
                "owner": MeetingSpeaker(id: "owner", displayName: "Reiss"),
                "guest": MeetingSpeaker(id: "guest", displayName: "Alex"),
            ]
        )
        let meetingController = MeetingDetailController(
            meetingID: meetingID,
            store: MemoryMeetingViewStore(values: [
                meetingID: StoredMeeting(
                    meeting: meetingRecord,
                    utterances: meetingUtterances
                ),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(values: [
                meetingID: StoredMeetingAnalysis(
                    analysis: analysisFixture(utteranceID: ownerUtteranceID),
                    speakerState: speakerState
                ),
            ]),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: meetingRecord),
            audioChecker: FixedAudioChecker(value: true),
            clipboard: MeetingClipboardSpy()
        )
        meetingController.load()
        await meetingController.perform(.selectTab(.transcript))

        #expect(meetingController.viewModel.transcript.map(\.speakerName) == ["Reiss", "Alex"])
        #expect(meetingController.viewModel.transcript.map(\.text) == meetingUtterances.map(\.text))
        try renderEvidence(
            MeetingDetailView(controller: meetingController),
            named: "meeting-speaker-transcript.png"
        )
    }

    @Test
    func privacySettingsRenderAlwaysRetainedPolicy() throws {
        try renderEvidence(
            SettingsView(selection: .constant(.audioPrivacy)),
            named: "audio-privacy-settings.png"
        )
    }

    @Test
    func ambiguousLegacyRecordingCanBeExplicitlyMovedToVoiceNotes() async throws {
        let id = UUID()
        let record = MeetingRecord(
            id: id,
            title: "Renamed older recording",
            recordingKind: .meeting,
            recordingKindNeedsReview: true,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: []),
        ])
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )

        controller.load()
        #expect(controller.viewModel.recordingKindNeedsReview)
        #expect(MeetingsController.badges(for: record).contains {
            $0.kind == .classification && $0.title == "Choose section"
        })

        await controller.perform(.setRecordingKind(.voiceNote))

        #expect(controller.viewModel.isVoiceNote)
        #expect(!controller.viewModel.recordingKindNeedsReview)
        #expect(store.values[id]?.meeting.recordingKind == .voiceNote)
        #expect(store.values[id]?.meeting.recordingKindNeedsReview == false)
    }

    @Test
    func detailDisablesRetryWhileOwnedAndCancelsBeforeConfirmedDeletion() async throws {
        let id = UUID()
        var record = meeting(id: id, title: "Failed transcript", start: .now)
        record.transcriptionState = .failed
        record.transcriptionErrorMessage = "Transcription failed."
        let store = MemoryMeetingViewStore(values: [
            id: StoredMeeting(meeting: record, utterances: []),
        ])
        let transcription = MeetingDetailTranscriptionSpy(isRunning: true)
        let controller = MeetingDetailController(
            meetingID: id,
            store: store,
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy(),
            transcriptionController: transcription
        )

        controller.load()
        #expect(!controller.viewModel.transcriptionCanRetry)

        await controller.perform(.requestMeetingDeletion)
        await controller.perform(.confirmMeetingDeletion)

        #expect(transcription.cancellations == [id])
        #expect(transcription.deletionReservations == [id])
        #expect(store.deleteConfirmations == [true])
        #expect(controller.state == .deleted)
    }

    @Test
    func detailDoesNotOfferOrStartRetryAfterAudioDeletion() async throws {
        let id = UUID()
        var record = meeting(id: id, title: "Deleted retry audio", start: .now)
        record.transcriptionState = .failed
        record.transcriptionErrorMessage = "Transcription failed before audio deletion."
        record.audioRetentionState = .deleted
        let transcription = MeetingDetailTranscriptionSpy(isRunning: false)
        let controller = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(values: [
                id: StoredMeeting(meeting: record, utterances: []),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy(),
            transcriptionController: transcription
        )

        controller.load()
        #expect(!controller.viewModel.transcriptionCanRetry)

        await controller.perform(.retryTranscription)

        #expect(transcription.retries.isEmpty)
        #expect(controller.viewModel.errorMessage?.contains("does not have") == true)
    }

    @Test
    func detailCancelsTranscriptionBeforeConfirmedAudioDeletion() async throws {
        let id = UUID()
        let record = meeting(
            id: id,
            title: "Retrying transcript",
            start: .now,
            retainedAudio: RetainedAudioMetadata(
                filename: AudioRetentionController.retainedFilename,
                format: AudioRetentionController.retainedFormat,
                sizeBytes: 100,
                durationMilliseconds: 3_000
            )
        )
        let audio = MeetingDetailAudioSpy(meeting: record)
        let transcription = MeetingDetailTranscriptionSpy(isRunning: true)
        let controller = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(values: [
                id: StoredMeeting(meeting: record, utterances: []),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: audio,
            audioChecker: FixedAudioChecker(value: true),
            clipboard: MeetingClipboardSpy(),
            transcriptionController: transcription
        )

        controller.load()
        await controller.perform(.requestAudioDeletion)
        await controller.perform(.confirmAudioDeletion)

        #expect(transcription.cancellations == [id])
        #expect(transcription.deletionReservations == [id])
        #expect(audio.deleteCalls == 1)
        #expect(controller.meeting?.retainedAudio == nil)
        #expect(!controller.isAudioDeletionInProgress)
    }

    @Test
    func openingQueuedMeetingResumesItsDurableUpload() async throws {
        let id = UUID()
        let record = meeting(id: id, title: "Queued upload", start: .now)
        var diagnosticUtterances = try utterances()
        diagnosticUtterances[0].text = """
            Loading Parakeet model...
            Loading audio file: "/private/tmp/meeting.wav"
            Audio format: 16000 Hz, 1 channel(s), Int
            Processing 32000 samples (2.00s)...

            Clean spoken text.
            """
        let upload = MeetingDetailUploadSpy()
        let controller = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(values: [
                id: StoredMeeting(meeting: record, utterances: diagnosticUtterances),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: upload,
            uploadStore: MemoryMeetingViewUploadStore(value: MeetingUploadRevision(
                meetingID: id,
                revision: 1,
                transcriptDigest: "digest",
                idempotencyKey: UUID(),
                request: BrainCaptureRequest(
                    type: .transcript,
                    source: "Brain.app meeting",
                    transcript: "transcript",
                    title: "Queued upload"
                ),
                state: .queued,
                captureID: "capture-queued",
                retryable: false,
                retryMode: .poll,
                lastError: nil,
                updatedAt: .now
            )),
            audioController: MeetingDetailAudioSpy(meeting: record),
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )

        controller.load()
        await controller.resumeUploadIfNeeded()

        #expect(upload.reconciliations == [id])
        #expect(controller.viewModel.transcript.first?.text == "Clean spoken text.")
    }

    @Test
    func viewsExposeKeyboardVoiceOverAndCopyOnlyFollowUpWithoutDirectBoundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Views", isDirectory: true)
        let meetings = try String(
            contentsOf: root.appendingPathComponent("MeetingsView.swift"),
            encoding: .utf8
        )
        let live = try String(
            contentsOf: root.appendingPathComponent("MeetingLiveView.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: root.appendingPathComponent("MeetingDetailView.swift"),
            encoding: .utf8
        )
        let combined = meetings + live + detail

        #expect(combined.contains("keyboardShortcut"))
        #expect(combined.contains("accessibilityLabel"))
        #expect(detail.contains("Copy Subject"))
        #expect(detail.contains("Copy Body"))
        #expect(detail.contains("Copy All"))
        #expect(!detail.contains("Send Email"))
        #expect(!detail.contains("mailto:"))
        #expect(!combined.contains("Process()"))
        #expect(!live.contains(".onDisappear"))
    }

    @Test
    func sparseMeetingLibraryStatesStayTopAligned() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Views", isDirectory: true)
        let meetings = try String(
            contentsOf: views.appendingPathComponent("MeetingsView.swift"),
            encoding: .utf8
        )
        let topAlignedFrame =
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"

        #expect(meetings.components(separatedBy: topAlignedFrame).count - 1 == 4)
        #expect(meetings.contains("ContentUnavailableView.search(text: query)"))
    }

    @Test
    func productionMeetingRouteWiresTheSavedCLIAnalysisProvider() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Views", isDirectory: true)
        let dashboard = try String(
            contentsOf: views.appendingPathComponent("DashboardView.swift"),
            encoding: .utf8
        )

        #expect(dashboard.contains("SavedMeetingAnalysisControllerFactory().make()"))
        #expect(!dashboard.contains("MeetingDetailController(meetingID: meetingID)"))
    }

    @Test
    func liveMeetingAndIslandKeepStateTextFocusAndReducedMotion() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Views", isDirectory: true)
        let live = try String(
            contentsOf: sourceRoot.appendingPathComponent("MeetingLiveView.swift"),
            encoding: .utf8
        )
        let island = try String(
            contentsOf: sourceRoot.appendingPathComponent("RecordingIslandView.swift"),
            encoding: .utf8
        )

        #expect(live.contains("accessibilityLabel(\"Meeting status\")"))
        #expect(live.contains("accessibilityFocused($accessibilityFocus, equals: .errorSummary)"))
        #expect(live.contains("keyboardShortcut(.defaultAction)"))
        #expect(live.contains("microphoneMissing"))
        #expect(island.contains("accessibilityReduceMotion"))
        #expect(island.contains(".animation(reduceMotion ? nil"))
        #expect(island.contains("brainAccessibleStatus(value.phase.accessibilityState)"))
        #expect(island.contains("accessibilityValue(value.latestTranscriptLine"))
        #expect(island.contains("accessibilityLabel(\"Active microphone\")"))
        #expect(island.contains("controller.selectMicrophone"))
        #expect(island.contains("\"mic.slash.fill\""))
    }

    private func meeting(
        id: UUID = UUID(),
        title: String,
        start: Date,
        retainedAudio: RetainedAudioMetadata? = nil
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: title,
            detectedApplication: "Zoom",
            startedAt: start,
            endedAt: start.addingTimeInterval(65),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3",
            retainedAudio: retainedAudio
        )
    }

    private func utterances() throws -> [MeetingUtterance] {
        [
            try MeetingUtterance(
                source: .microphone,
                startMilliseconds: 0,
                endMilliseconds: 2_000,
                text: "Launch timing",
                baseSpeakerID: "you"
            ),
            try MeetingUtterance(
                source: .system,
                startMilliseconds: 2_500,
                endMilliseconds: 4_000,
                text: "Looks good",
                baseSpeakerID: "remote"
            ),
        ]
    }

    private func analysisFixture(utteranceID: UUID) -> MeetingAnalysis {
        MeetingAnalysis(
            title: "Roadmap",
            summary: "A concise summary",
            topics: ["Launch"],
            decisions: ["Ship"],
            actionItems: [MeetingAnalysisActionItem(text: "Prepare release", owner: "the owner")],
            risks: [],
            quotes: [MeetingAnalysisQuote(utteranceID: utteranceID, text: "Launch timing")],
            speakerSuggestions: [],
            followUp: MeetingFollowUpDraft(
                subject: "Follow up",
                body: "Thanks for the review."
            )
        )
    }

    private func renderEvidence<V: View>(
        _ view: V,
        named filename: String,
        height: CGFloat = 700
    ) throws {
        let hostingView = NSHostingView(rootView: view
            .frame(width: 900, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = filename == "voice-note-transcript.png" ? "Voice Note" : "Meeting"
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)

        guard let directory = ProcessInfo.processInfo.environment["BRAIN_TEST_EVIDENCE_DIR"] else {
            return
        }
        try png.write(
            to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(filename),
            options: .atomic
        )
    }

    @Test
    func detailOffersTranscriptPreservingDeletionForSourceOnlyAudio() async throws {
        let id = UUID()
        var record = meeting(id: id, title: "Failed archive", start: .now)
        record.transcriptionState = .failed
        record.transcriptionAttemptCount = 1
        record.transcriptionErrorMessage = "Archival was interrupted."
        let transcript = try utterances()
        let audio = MeetingDetailAudioSpy(meeting: record, deletableAudio: true)
        let controller = MeetingDetailController(
            meetingID: id,
            store: MemoryMeetingViewStore(values: [
                id: StoredMeeting(meeting: record, utterances: transcript),
            ]),
            analysisStore: MemoryMeetingViewAnalysisStore(),
            uploadController: MeetingDetailUploadSpy(),
            audioController: audio,
            audioChecker: FixedAudioChecker(value: false),
            clipboard: MeetingClipboardSpy()
        )

        controller.load()

        #expect(audio.deletionAvailabilityChecks == 1)
        #expect(controller.viewModel.audioControls == [.delete])
        #expect(controller.viewModel.hasTranscript)
        _ = controller.viewModel
        _ = controller.viewModel
        #expect(audio.deletionAvailabilityChecks == 1)
        try renderEvidence(
            MeetingDetailView(controller: controller),
            named: "source-only-audio-deletion.png",
            height: 900
        )
        await controller.perform(.requestAudioDeletion)
        #expect(controller.isAudioDeletionPending)
        await controller.perform(.confirmAudioDeletion)
        #expect(audio.deleteCalls == 1)
        #expect(controller.viewModel.hasTranscript)
        #expect(controller.viewModel.audioRetentionState == .deleted)
    }
}

private enum TestMeetingViewError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "test failure" }
}

private final class MemoryMeetingViewStore: MeetingLibraryStoring, @unchecked Sendable {
    private(set) var values: [UUID: StoredMeeting]
    private let listOrder: [UUID]
    private let extraEntries: [MeetingListEntry]
    private let listError: Error?
    private let loadError: Error?
    private(set) var listCalls = 0
    private(set) var loadCalls = 0
    private(set) var deleteConfirmations: [Bool] = []

    init(
        values: [UUID: StoredMeeting] = [:],
        listOrder: [UUID] = [],
        extraEntries: [MeetingListEntry] = [],
        listError: Error? = nil,
        loadError: Error? = nil
    ) {
        self.values = values
        self.listOrder = listOrder
        self.extraEntries = extraEntries
        self.listError = listError
        self.loadError = loadError
    }

    func list() throws -> [MeetingListEntry] {
        listCalls += 1
        if let listError { throw listError }
        let ids = listOrder.isEmpty ? Array(values.keys) : listOrder
        return ids.compactMap { values[$0].map { .available($0.meeting) } } + extraEntries
    }

    func load(_ id: UUID) throws -> StoredMeeting {
        loadCalls += 1
        if let loadError { throw loadError }
        guard let value = values[id] else { throw MeetingStoreError.meetingNotFound(id) }
        return value
    }

    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws {
        values[meeting.id] = StoredMeeting(meeting: meeting, utterances: utterances)
    }

    func delete(_ id: UUID, confirmed: Bool) throws {
        deleteConfirmations.append(confirmed)
        guard confirmed else { throw MeetingStoreError.deletionRequiresConfirmation }
        values.removeValue(forKey: id)
    }
}

private final class MemoryMeetingViewAnalysisStore: MeetingAnalysisStoring, @unchecked Sendable {
    private var values: [UUID: StoredMeetingAnalysis]

    init(values: [UUID: StoredMeetingAnalysis] = [:]) {
        self.values = values
    }

    func load(meetingID: UUID) throws -> StoredMeetingAnalysis? { values[meetingID] }
    func replace(_ value: StoredMeetingAnalysis, meetingID: UUID) throws {
        values[meetingID] = value
    }
}

private final class MemoryMeetingViewUploadStore: MeetingUploadStoring, @unchecked Sendable {
    private var value: MeetingUploadRevision?

    init(value: MeetingUploadRevision? = nil) { self.value = value }

    func load(meetingID: UUID) throws -> MeetingUploadRevision? {
        guard value?.meetingID == meetingID else { return nil }
        return value
    }

    func save(_ revision: MeetingUploadRevision) throws { value = revision }
}

@MainActor
private final class MeetingLiveActionSpy: MeetingLiveActionHandling {
    private(set) var actions: [MeetingLiveAction] = []
    func pause() async { actions.append(.pause) }
    func resume() async { actions.append(.resume) }
    func stop() async { actions.append(.stop) }
}

private final class MeetingDetailAnalysisSpy: MeetingDetailAnalysisControlling, @unchecked Sendable {
    let result: MeetingAnalysisRunResult
    private(set) var analysisCalls = 0
    private(set) var reanalysisCalls = 0

    init(result: MeetingAnalysisRunResult) { self.result = result }

    func analyzeAfterFinalTranscription(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        analysisCalls += 1
        return result
    }

    func reanalyze(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        reanalysisCalls += 1
        return result
    }

    func acceptSpeakerSuggestion(
        meetingID: UUID,
        utteranceID: UUID,
        editor: inout SpeakerEditor
    ) throws -> Bool { false }
}

@MainActor
private final class MeetingDetailUploadSpy: MeetingDetailUploadControlling {
    var uploadState: MeetingUploadState = .failed
    var errorMessage: String?
    var canRetry = true
    var canReupload = true
    private(set) var retries: [UUID] = []
    private(set) var reuploads: [UUID] = []
    private(set) var reconciliations: [UUID] = []

    func uploadAfterFinalTranscriptPersistence(meetingID: UUID) async {
        reconciliations.append(meetingID)
    }
    func retry(meetingID: UUID) async { retries.append(meetingID) }
    func reupload(meetingID: UUID) async { reuploads.append(meetingID) }
}

private final class MeetingDetailAudioSpy: MeetingDetailAudioControlling, @unchecked Sendable {
    private var meeting: MeetingRecord
    private var deletableAudio: Bool
    private(set) var revealCalls = 0
    private(set) var exports: [URL] = []
    private(set) var deleteCalls = 0
    private(set) var deletionAvailabilityChecks = 0

    init(meeting: MeetingRecord, deletableAudio: Bool? = nil) {
        self.meeting = meeting
        self.deletableAudio = deletableAudio ?? (meeting.retainedAudio != nil)
    }

    func revealRecording(for meetingID: UUID) throws { revealCalls += 1 }
    func exportRecording(for meetingID: UUID, to destination: URL?) throws -> URL? {
        if let destination { exports.append(destination) }
        return destination
    }
    func hasDeletableRecording(for meetingID: UUID) -> Bool {
        deletionAvailabilityChecks += 1
        return deletableAudio
    }
    func deleteRecording(for meetingID: UUID, confirmed: Bool) throws -> MeetingRecord {
        guard confirmed else { throw AudioRetentionControllerError.deletionRequiresConfirmation }
        deleteCalls += 1
        meeting.retainedAudio = nil
        meeting.audioRetentionState = .deleted
        deletableAudio = false
        return meeting
    }
}

@MainActor
private final class MeetingDetailTranscriptionSpy: MeetingTranscriptionRetrying {
    private var running: Bool
    private(set) var retries: [UUID] = []
    private(set) var cancellations: [UUID] = []
    private(set) var deletionReservations: [UUID] = []

    init(isRunning: Bool) {
        running = isRunning
    }

    func retry(meetingID: UUID) async throws -> MeetingRecord {
        retries.append(meetingID)
        throw TestMeetingViewError.failed
    }

    func isRunning(meetingID: UUID) -> Bool {
        running
    }

    func cancelAndWait(meetingID: UUID) async {
        cancellations.append(meetingID)
        running = false
    }

    func cancelAndWaitForDeletion(
        meetingID: UUID,
        operation: @MainActor () throws -> Void
    ) async throws {
        await cancelAndWait(meetingID: meetingID)
        deletionReservations.append(meetingID)
        try operation()
    }
}

private struct FixedAudioChecker: MeetingLocalAudioChecking {
    let value: Bool
    func hasLocalAudio(for meeting: MeetingRecord) -> Bool { value }
}

@MainActor
private final class MeetingClipboardSpy: MeetingClipboardWriting {
    private(set) var values: [String] = []
    func write(_ value: String) { values.append(value) }
}
