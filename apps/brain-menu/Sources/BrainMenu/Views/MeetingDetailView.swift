import AppKit
import Foundation
import Observation
import SwiftUI

enum MeetingDetailTab: String, CaseIterable, Identifiable, Equatable, Sendable {
    case summary = "Summary"
    case transcript = "Transcript"

    var id: Self { self }
}

enum MeetingDetailLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case corrupt(String)
    case failed(String)
    case deleted
}

enum MeetingAudioControl: String, CaseIterable, Equatable, Sendable {
    case reveal
    case export
    case delete
}

enum MeetingDraftCopyAction: String, CaseIterable, Equatable, Sendable {
    case subject
    case body
    case all
}

struct MeetingDetailTranscriptRowModel: Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: String
    let speakerID: String
    let speakerName: String
    let provenance: SpeakerAssignmentProvenance
    let text: String
    let isSelected: Bool

    var accessibilityLabel: String { "\(timestamp), \(speakerName): \(text)" }
}

struct MeetingDetailSpeakerModel: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

struct MeetingFollowUpViewModel: Equatable, Sendable {
    let subject: String
    let body: String
    let actions: [MeetingDraftCopyAction] = MeetingDraftCopyAction.allCases
}

struct MeetingDetailViewModel: Equatable, Sendable {
    let state: MeetingDetailLoadState
    let meetingID: UUID?
    let isVoiceNote: Bool
    let title: String
    let dateText: String
    let durationText: String
    let badges: [MeetingStatusBadge]
    let tab: MeetingDetailTab
    let transcript: [MeetingDetailTranscriptRowModel]
    let speakers: [MeetingDetailSpeakerModel]
    let talkTime: [SpeakerTalkTime]
    let analysis: MeetingAnalysis?
    let followUp: MeetingFollowUpViewModel?
    let audioControls: [MeetingAudioControl]
    let transcriptionState: MeetingTranscriptionState?
    let analysisState: MeetingAnalysisState?
    let transcriptionCanRetry: Bool
    let transcriptionMessage: String?
    let uploadCanRetry: Bool
    let uploadCanReupload: Bool
    let errorMessage: String?
    let copiedMessage: String?
    let meetingDeletionWarning: String?
    let audioDeletionWarning: String?

    var hasTranscript: Bool { !transcript.isEmpty }
    var hasAnalysis: Bool { analysis != nil }
}

protocol MeetingDetailAnalysisControlling: Sendable {
    func analyzeAfterFinalTranscription(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult
    func reanalyze(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult
    func acceptSpeakerSuggestion(
        meetingID: UUID,
        utteranceID: UUID,
        editor: inout SpeakerEditor
    ) throws -> Bool
}

extension MeetingAnalysisService: MeetingDetailAnalysisControlling {}

struct SavedMeetingAnalysisControllerFactory {
    private let settings: any AISettingsPersisting
    private let providerFactory: any AIProviderMaking

    init(
        settings: any AISettingsPersisting = AISettingsStore(),
        providerFactory: any AIProviderMaking = LocalAIProviderFactory()
    ) {
        self.settings = settings
        self.providerFactory = providerFactory
    }

    func make() -> (any MeetingDetailAnalysisControlling)? {
        let configuration = settings.load().canonicalized()
        guard configuration.provider != .disabled else { return nil }
        return MeetingAnalysisService(
            provider: providerFactory.makeProvider(configuration: configuration),
            contextChoice: configuration.contextChoice
        )
    }
}

@MainActor
protocol MeetingDetailUploadControlling: AnyObject {
    var uploadState: MeetingUploadState { get }
    var errorMessage: String? { get }
    var canRetry: Bool { get }
    var canReupload: Bool { get }
    func uploadAfterFinalTranscriptPersistence(meetingID: UUID) async
    func retry(meetingID: UUID) async
    func reupload(meetingID: UUID) async
}

extension MeetingUploadController: MeetingDetailUploadControlling {}

protocol MeetingDetailAudioControlling: Sendable {
    func revealRecording(for meetingID: UUID) throws
    func exportRecording(for meetingID: UUID, to destination: URL?) throws -> URL?
    func deleteRecording(for meetingID: UUID, confirmed: Bool) throws -> MeetingRecord
}

extension AudioRetentionController: MeetingDetailAudioControlling {}

protocol MeetingLocalAudioChecking: Sendable {
    func hasLocalAudio(for meeting: MeetingRecord) -> Bool
}

struct FileMeetingLocalAudioChecker: MeetingLocalAudioChecking {
    let rootURL: URL

    init(rootURL: URL = MeetingStore.productionRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func hasLocalAudio(for meeting: MeetingRecord) -> Bool {
        guard meeting.retainedAudio != nil else { return false }
        let url = rootURL
            .appendingPathComponent(meeting.id.uuidString, isDirectory: true)
            .appendingPathComponent(AudioRetentionController.retainedFilename)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}

@MainActor
protocol MeetingClipboardWriting: AnyObject {
    func write(_ value: String)
}

@MainActor
final class SystemMeetingClipboard: MeetingClipboardWriting {
    func write(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

enum MeetingDetailAction: Equatable, Sendable {
    case saveTitle(String)
    case selectTab(MeetingDetailTab)
    case renameSpeaker(id: String, name: String)
    case mergeSpeakers(sourceIDs: Set<String>, into: String)
    case reassign(utteranceIDs: Set<UUID>, to: String)
    case split(speakerID: String, utteranceIDs: Set<UUID>, name: String?)
    case undoSpeakerEdit
    case acceptSpeakerSuggestion(UUID)
    case analyze
    case reanalyze
    case copyDraft(MeetingDraftCopyAction)
    case revealAudio
    case exportAudio(URL?)
    case requestAudioDeletion
    case confirmAudioDeletion
    case cancelAudioDeletion
    case retryTranscription
    case retryUpload
    case reupload
    case requestMeetingDeletion
    case confirmMeetingDeletion
    case cancelMeetingDeletion
}

@MainActor
@Observable
final class MeetingDetailController {
    static let meetingDeletionWarning = "Delete this meeting from this Mac? This removes only local application state. It does not retract a capture already delivered to the Brain vault."
    static let voiceNoteDeletionWarning = "Delete this voice note from this Mac? This removes only local application state. It does not retract a capture already delivered to the Brain vault."
    static let audioDeletionWarning = "Delete this retained recording from this Mac? The transcript and any delivered vault capture remain available."

    private(set) var state: MeetingDetailLoadState = .idle
    private(set) var meeting: MeetingRecord?
    private(set) var utterances: [MeetingUtterance] = []
    private(set) var analysis: MeetingAnalysis?
    private(set) var editor = SpeakerEditor(utterances: [])
    private(set) var uploadRevision: MeetingUploadRevision?
    private(set) var errorMessage: String?
    private(set) var copiedMessage: String?
    private(set) var isMeetingDeletionPending = false
    private(set) var isAudioDeletionPending = false
    private(set) var isTranscriptionRetryInProgress = false
    private(set) var isMeetingDeletionInProgress = false
    var selectedTab: MeetingDetailTab = .summary
    var selectedUtteranceIDs: Set<UUID> = []
    var titleDraft = ""

    let meetingID: UUID

    @ObservationIgnored private let store: any MeetingLibraryStoring
    @ObservationIgnored private let analysisStore: any MeetingAnalysisStoring
    @ObservationIgnored private let analysisController: (any MeetingDetailAnalysisControlling)?
    @ObservationIgnored private let uploadController: any MeetingDetailUploadControlling
    @ObservationIgnored private let uploadStore: any MeetingUploadStoring
    @ObservationIgnored private let audioController: any MeetingDetailAudioControlling
    @ObservationIgnored private let audioChecker: any MeetingLocalAudioChecking
    @ObservationIgnored private let clipboard: any MeetingClipboardWriting
    @ObservationIgnored private let transcriptionController: any MeetingTranscriptionRetrying
    @ObservationIgnored private var lastKnownRecordingKind: MeetingRecordingKind = .meeting

    init(
        meetingID: UUID,
        store: any MeetingLibraryStoring = MeetingStore(),
        analysisStore: any MeetingAnalysisStoring = FileMeetingAnalysisStore(),
        analysisController: (any MeetingDetailAnalysisControlling)? = nil,
        uploadController: any MeetingDetailUploadControlling = MeetingUploadController(),
        uploadStore: any MeetingUploadStoring = FileMeetingUploadStore(),
        audioController: any MeetingDetailAudioControlling = AudioRetentionController(),
        audioChecker: any MeetingLocalAudioChecking = FileMeetingLocalAudioChecker(),
        clipboard: any MeetingClipboardWriting = SystemMeetingClipboard(),
        transcriptionController: any MeetingTranscriptionRetrying =
            MeetingTranscriptionCoordinator()
    ) {
        self.meetingID = meetingID
        self.store = store
        self.analysisStore = analysisStore
        self.analysisController = analysisController
        self.uploadController = uploadController
        self.uploadStore = uploadStore
        self.audioController = audioController
        self.audioChecker = audioChecker
        self.clipboard = clipboard
        self.transcriptionController = transcriptionController
    }

    var viewModel: MeetingDetailViewModel {
        let meeting = meeting
        let assignments = editor.assignments
        let speakers = editor.speakers
        let rows = editor.utterances
            .filter { !$0.suppressed }
            .sorted(by: Self.transcriptOrder)
            .map { utterance -> MeetingDetailTranscriptRowModel in
                let assignment = assignments[utterance.id]
                    ?? SpeakerAssignment(
                        speakerID: utterance.baseSpeakerID,
                        provenance: .sourceDefault
                    )
                return MeetingDetailTranscriptRowModel(
                    id: utterance.id,
                    timestamp: Self.timestamp(utterance.startMilliseconds),
                    speakerID: assignment.speakerID,
                    speakerName: speakers[assignment.speakerID]?.displayName
                        ?? SpeakerEditor.defaultDisplayName(for: assignment.speakerID),
                    provenance: assignment.provenance,
                    text: utterance.text,
                    isSelected: selectedUtteranceIDs.contains(utterance.id)
                )
            }
        let speakerModels = speakers.values
            .map { MeetingDetailSpeakerModel(id: $0.id, displayName: $0.displayName) }
            .sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return $0.id < $1.id
            }
        let localAudioExists = meeting.map {
            $0.retainedAudio != nil && audioChecker.hasLocalAudio(for: $0)
        } ?? false
        var effectiveMeeting = meeting
        if let uploadRevision {
            effectiveMeeting?.uploadState = uploadRevision.state
        }
        let effectiveTranscriptionState: MeetingTranscriptionState? =
            isTranscriptionRetryInProgress ? .processing : meeting?.transcriptionState

        return MeetingDetailViewModel(
            state: state,
            meetingID: meeting?.id,
            isVoiceNote: (meeting?.recordingKind ?? lastKnownRecordingKind) == .voiceNote,
            title: meeting?.title ?? "Meeting",
            dateText: meeting.map { Self.dateFormatter.string(from: $0.startedAt) } ?? "",
            durationText: meeting.map {
                MeetingsController.durationText(
                    from: $0.startedAt,
                    to: $0.endedAt ?? $0.startedAt
                )
            } ?? "",
            badges: effectiveMeeting.map(MeetingsController.badges) ?? [],
            tab: selectedTab,
            transcript: rows,
            speakers: speakerModels,
            talkTime: TalkTimeCalculator().calculate(for: editor).data,
            analysis: analysis,
            followUp: analysis.map {
                MeetingFollowUpViewModel(
                    subject: $0.followUp.subject,
                    body: $0.followUp.body
                )
            },
            audioControls: localAudioExists ? MeetingAudioControl.allCases : [],
            transcriptionState: effectiveTranscriptionState,
            analysisState: effectiveMeeting?.analysisState,
            transcriptionCanRetry: meeting?.transcriptionState == .failed
                && !isTranscriptionRetryInProgress
                && !transcriptionController.isRunning(meetingID: meetingID),
            transcriptionMessage: isTranscriptionRetryInProgress
                ? nil
                : meeting?.transcriptionErrorMessage,
            uploadCanRetry: uploadController.canRetry
                || (uploadRevision?.state == .failed && uploadRevision?.retryable == true),
            uploadCanReupload: uploadController.canReupload,
            errorMessage: errorMessage ?? uploadController.errorMessage,
            copiedMessage: copiedMessage,
            meetingDeletionWarning: isMeetingDeletionPending
                ? (meeting?.isVoiceNote == true
                    ? Self.voiceNoteDeletionWarning
                    : Self.meetingDeletionWarning)
                : nil,
            audioDeletionWarning: isAudioDeletionPending
                ? Self.audioDeletionWarning
                : nil
        )
    }

    func load() {
        state = .loading
        errorMessage = nil
        do {
            var stored = try store.load(meetingID)
            let cleanedUtterances = stored.utterances.map { utterance in
                var cleaned = utterance
                if let text = VoxTypeClient.transcriptText(from: Data(utterance.text.utf8)) {
                    cleaned.text = text
                }
                return cleaned
            }
            let shouldMarkRead = stored.meeting.isUnread
            if shouldMarkRead { stored.meeting.isUnread = false }
            if cleanedUtterances != stored.utterances || shouldMarkRead {
                try store.save(stored.meeting, utterances: cleanedUtterances)
                stored = StoredMeeting(meeting: stored.meeting, utterances: cleanedUtterances)
            }
            meeting = stored.meeting
            lastKnownRecordingKind = stored.meeting.recordingKind
            utterances = stored.utterances
            titleDraft = stored.meeting.title
            loadUploadRevision()
            do {
                let storedAnalysis = try analysisStore.load(meetingID: meetingID)
                analysis = storedAnalysis?.analysis
                editor = SpeakerEditor(
                    utterances: stored.utterances,
                    state: storedAnalysis?.speakerState ?? SpeakerEditingState()
                )
            } catch {
                analysis = nil
                editor = SpeakerEditor(utterances: stored.utterances)
                errorMessage = "Local analysis is unavailable: \(Self.bounded(error))"
            }
            state = .ready
        } catch let error as MeetingStoreError {
            meeting = nil
            utterances = []
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            switch error {
            case .corruptMeeting, .unsafeStorePath:
                state = .corrupt(error.localizedDescription)
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            meeting = nil
            utterances = []
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            state = .failed(Self.bounded(error))
        }
    }

    func resumeUploadIfNeeded() async {
        guard let uploadRevision,
              [.queued, .delivering].contains(uploadRevision.state) else { return }
        await uploadController.uploadAfterFinalTranscriptPersistence(meetingID: meetingID)
        reloadMeetingAfterTypedAction()
    }

    func toggleSelection(_ utteranceID: UUID) {
        if selectedUtteranceIDs.contains(utteranceID) {
            selectedUtteranceIDs.remove(utteranceID)
        } else {
            selectedUtteranceIDs.insert(utteranceID)
        }
    }

    func perform(_ action: MeetingDetailAction) async {
        copiedMessage = nil
        switch action {
        case .saveTitle(let title):
            saveTitle(title)
        case .selectTab(let tab):
            selectedTab = tab
        case .renameSpeaker(let id, let name):
            applySpeakerEdit { $0.rename(speakerID: id, to: name) }
        case .mergeSpeakers(let sourceIDs, let target):
            applySpeakerEdit { $0.merge(speakerIDs: Array(sourceIDs), into: target) }
        case .reassign(let utteranceIDs, let speakerID):
            applySpeakerEdit { $0.reassign(utteranceIDs: utteranceIDs, to: speakerID) }
        case .split(let speakerID, let utteranceIDs, let name):
            applySpeakerEdit {
                $0.split(speakerID: speakerID, utteranceIDs: utteranceIDs, displayName: name)
                    != speakerID
            }
        case .undoSpeakerEdit:
            applySpeakerEdit { $0.undo() }
        case .acceptSpeakerSuggestion(let utteranceID):
            acceptSpeakerSuggestion(utteranceID)
        case .analyze:
            await runAnalysis(isReanalysis: false)
        case .reanalyze:
            await runAnalysis(isReanalysis: true)
        case .copyDraft(let copyAction):
            copyDraft(copyAction)
        case .revealAudio:
            revealAudio()
        case .exportAudio(let destination):
            exportAudio(to: destination)
        case .requestAudioDeletion:
            guard !viewModel.audioControls.isEmpty else { return }
            isAudioDeletionPending = true
        case .confirmAudioDeletion:
            deleteAudio()
        case .cancelAudioDeletion:
            isAudioDeletionPending = false
        case .retryTranscription:
            await retryTranscription()
        case .retryUpload:
            await uploadController.retry(meetingID: meetingID)
            reloadMeetingAfterTypedAction()
        case .reupload:
            await uploadController.reupload(meetingID: meetingID)
            reloadMeetingAfterTypedAction()
        case .requestMeetingDeletion:
            guard meeting != nil else { return }
            isMeetingDeletionPending = true
        case .confirmMeetingDeletion:
            await deleteMeeting()
        case .cancelMeetingDeletion:
            isMeetingDeletionPending = false
        }
    }

    private func retryTranscription() async {
        guard !isTranscriptionRetryInProgress,
              !isMeetingDeletionInProgress,
              !transcriptionController.isRunning(meetingID: meetingID) else {
            errorMessage = MeetingTranscriptionCoordinatorError
                .transcriptionAlreadyRunning.localizedDescription
            return
        }
        isTranscriptionRetryInProgress = true
        defer { isTranscriptionRetryInProgress = false }
        errorMessage = nil
        do {
            _ = try await transcriptionController.retry(meetingID: meetingID)
            guard !isMeetingDeletionInProgress, state != .deleted else { return }
            load()
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func saveTitle(_ proposed: String) {
        guard var meeting else { return }
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = meeting.isVoiceNote
                ? "A voice note title cannot be empty."
                : "A meeting title cannot be empty."
            titleDraft = meeting.title
            return
        }
        guard meeting.title != title else { return }
        meeting.title = title
        meeting.titleSource = .manual
        do {
            try store.save(meeting, utterances: utterances)
            self.meeting = meeting
            titleDraft = title
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
            titleDraft = self.meeting?.title ?? ""
        }
    }

    private func applySpeakerEdit(_ edit: (inout SpeakerEditor) -> Bool) {
        var candidate = editor
        guard edit(&candidate) else { return }
        do {
            if let analysis {
                try analysisStore.replace(
                    StoredMeetingAnalysis(analysis: analysis, speakerState: candidate.state),
                    meetingID: meetingID
                )
            }
            editor = candidate
            selectedUtteranceIDs.formIntersection(Set(editor.utterances.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = "Speaker change was not saved: \(Self.bounded(error))"
        }
    }

    private func acceptSpeakerSuggestion(_ utteranceID: UUID) {
        guard let analysisController else {
            errorMessage = meeting?.isVoiceNote == true
                ? "Voice note analysis is not configured."
                : "Meeting analysis is not configured."
            return
        }
        var candidate = editor
        do {
            guard try analysisController.acceptSpeakerSuggestion(
                meetingID: meetingID,
                utteranceID: utteranceID,
                editor: &candidate
            ) else { return }
            editor = candidate
            errorMessage = nil
        } catch {
            errorMessage = "Speaker suggestion was not saved: \(Self.bounded(error))"
        }
    }

    private func runAnalysis(isReanalysis: Bool) async {
        guard let analysisController, var meeting else {
            errorMessage = "Configure and test a local AI provider before analyzing."
            return
        }
        meeting.analysisState = .running
        self.meeting = meeting
        try? store.save(meeting, utterances: utterances)

        let result = if isReanalysis {
            await analysisController.reanalyze(
                meeting: meeting,
                utterances: utterances,
                speakerState: editor.state
            )
        } else {
            await analysisController.analyzeAfterFinalTranscription(
                meeting: meeting,
                utterances: utterances,
                speakerState: editor.state
            )
        }
        self.meeting = result.meeting
        analysis = result.analysis
        editor = SpeakerEditor(utterances: result.utterances, state: result.speakerState)
        do {
            try store.save(result.meeting, utterances: result.utterances)
        } catch {
            let item = result.meeting.isVoiceNote ? "voice note" : "meeting"
            errorMessage = "Analysis finished, but its \(item) state was not saved: \(Self.bounded(error))"
            return
        }
        errorMessage = result.failure.map(Self.analysisFailureMessage)
    }

    private func copyDraft(_ action: MeetingDraftCopyAction) {
        guard let draft = analysis?.followUp else { return }
        let value: String
        switch action {
        case .subject:
            value = draft.subjectForCopy
            copiedMessage = "Subject copied"
        case .body:
            value = draft.bodyForCopy
            copiedMessage = "Body copied"
        case .all:
            value = "Subject: \(draft.subjectForCopy)\n\n\(draft.bodyForCopy)"
            copiedMessage = "Follow-up draft copied"
        }
        clipboard.write(value)
    }

    private func revealAudio() {
        guard viewModel.audioControls.contains(.reveal) else { return }
        do {
            try audioController.revealRecording(for: meetingID)
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func exportAudio(to destination: URL?) {
        guard viewModel.audioControls.contains(.export) else { return }
        do {
            _ = try audioController.exportRecording(for: meetingID, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func deleteAudio() {
        guard isAudioDeletionPending,
              viewModel.audioControls.contains(.delete) else { return }
        do {
            meeting = try audioController.deleteRecording(for: meetingID, confirmed: true)
            isAudioDeletionPending = false
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func deleteMeeting() async {
        guard isMeetingDeletionPending, !isMeetingDeletionInProgress else { return }
        isMeetingDeletionInProgress = true
        await transcriptionController.cancelAndWait(meetingID: meetingID)
        do {
            try store.delete(meetingID, confirmed: true)
            isMeetingDeletionPending = false
            meeting = nil
            utterances = []
            analysis = nil
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            state = .deleted
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
        isMeetingDeletionInProgress = false
    }

    private func reloadMeetingAfterTypedAction() {
        do {
            let stored = try store.load(meetingID)
            meeting = stored.meeting
            utterances = stored.utterances
            editor.reprocessFinalUtterances(stored.utterances)
            loadUploadRevision()
            errorMessage = uploadController.errorMessage ?? errorMessage
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func loadUploadRevision() {
        do {
            uploadRevision = try uploadStore.load(meetingID: meetingID)
        } catch {
            uploadRevision = nil
            errorMessage = "Local delivery state is unavailable: \(Self.bounded(error))"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    private static func transcriptOrder(
        _ lhs: MeetingUtterance,
        _ rhs: MeetingUtterance
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
    }

    private static func bounded(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }

    private static func analysisFailureMessage(_ failure: MeetingAnalysisFailure) -> String {
        switch failure {
        case .transcriptionNotFinal: "Analysis requires a final transcript."
        case .providerNotReady: "The configured local AI provider is not ready."
        case .providerFailure(let failure): failure.localizedDescription
        case .cancelled: "Analysis was cancelled."
        case .schemaFailure: "The AI response did not match the expected analysis schema."
        case .persistenceFailure: "The previous analysis remains because the new result could not be saved."
        }
    }
}

struct MeetingDetailView: View {
    @State private var controller: MeetingDetailController
    @State private var speakerNames: [String: String] = [:]

    init(controller: MeetingDetailController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .loading:
                MeetingWorkPlaceholder(
                    title: "Loading meeting",
                    detail: "Reading the local transcript and analysis."
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            case .corrupt(let message):
                unavailable(title: "Meeting data is corrupt", message: message)
            case .failed(let message):
                unavailable(title: "Meeting unavailable", message: message)
            case .deleted:
                ContentUnavailableView(
                    controller.viewModel.isVoiceNote
                        ? "Voice note deleted locally"
                        : "Meeting deleted locally",
                    systemImage: "trash",
                    description: Text("A previously delivered vault capture was not retracted.")
                )
            case .ready:
                detail(controller.viewModel)
            }
        }
        .navigationTitle(controller.viewModel.isVoiceNote ? "Voice Note" : "Meeting")
        .task {
            controller.load()
            await controller.resumeUploadIfNeeded()
        }
        .onChange(of: controller.viewModel.speakers) { _, speakers in
            synchronizeSpeakerNames(speakers)
        }
        .confirmationDialog(
            "Delete retained audio?",
            isPresented: audioConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                Task { await controller.perform(.confirmAudioDeletion) }
            }
            Button("Cancel", role: .cancel) {
                Task { await controller.perform(.cancelAudioDeletion) }
            }
        } message: {
            Text(controller.viewModel.audioDeletionWarning ?? "")
        }
        .confirmationDialog(
            controller.viewModel.isVoiceNote
                ? "Delete voice note from this Mac?"
                : "Delete meeting from this Mac?",
            isPresented: meetingConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(
                controller.viewModel.isVoiceNote ? "Delete Local Voice Note" : "Delete Local Meeting",
                role: .destructive
            ) {
                Task { await controller.perform(.confirmMeetingDeletion) }
            }
            Button("Cancel", role: .cancel) {
                Task { await controller.perform(.cancelMeetingDeletion) }
            }
        } message: {
            Text(controller.viewModel.meetingDeletionWarning ?? "")
        }
    }

    private func unavailable(title: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ model: MeetingDetailViewModel) -> some View {
        VStack(spacing: 0) {
            detailHeader(model)
            Divider()
            Picker(model.isVoiceNote ? "Voice note section" : "Meeting section", selection: tabBinding) {
                ForEach(MeetingDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Divider()
            if model.tab == .summary {
                summary(model)
            } else {
                transcript(model)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private func detailHeader(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(model.isVoiceNote ? "Voice note title" : "Meeting title", text: $controller.titleDraft)
                    .font(.title2.bold())
                    .onSubmit {
                        Task { await controller.perform(.saveTitle(controller.titleDraft)) }
                    }
                    .accessibilityLabel(model.isVoiceNote ? "Voice note title" : "Meeting title")
                Spacer()
                Menu(model.isVoiceNote ? "Voice note actions" : "Meeting actions", systemImage: "ellipsis.circle") {
                    Button(
                        model.isVoiceNote ? "Delete Local Voice Note" : "Delete Local Meeting",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        Task { await controller.perform(.requestMeetingDeletion) }
                    }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                }
            }
            HStack {
                Text(model.dateText)
                Text("•")
                Text(model.durationText).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(model.badges) { badge in
                    Label(badge.title, systemImage: badge.systemImage)
                        .font(.caption2)
                        .accessibilityLabel(badge.accessibilityLabel)
                }
            }
            if model.transcriptionState == .processing || model.transcriptionState == .pending {
                Label("Processing the saved recording…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.transcriptionState == .failed {
                HStack {
                    Label(
                        model.transcriptionMessage ?? "The saved recording could not be transcribed.",
                        systemImage: "exclamationmark.bubble.fill"
                    )
                    .foregroundStyle(.red)
                    .font(.caption)
                    Spacer()
                    Button("Retry Transcript", systemImage: "arrow.clockwise") {
                        Task { await controller.perform(.retryTranscription) }
                    }
                    .disabled(!model.transcriptionCanRetry)
                }
            } else if let message = model.transcriptionMessage {
                Label(message, systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if let copied = model.copiedMessage {
                Label(copied, systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding()
    }

    private func summary(_ model: MeetingDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                analysisSection(model)
                talkTimeSection(model)
                speakerSection(model)
                uploadSection(model)
                audioSection(model)
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func analysisSection(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Analysis").font(.title3.bold())
                Spacer()
                Button(model.hasAnalysis ? "Re-analyze" : "Analyze", systemImage: "sparkles") {
                    Task {
                        await controller.perform(model.hasAnalysis ? .reanalyze : .analyze)
                    }
                }
                .disabled(model.transcriptionState != .completed)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            if let analysis = model.analysis {
                Text(analysis.summary).textSelection(.enabled)
                valueList("Topics", values: analysis.topics)
                valueList("Decisions", values: analysis.decisions)
                valueList("Risks", values: analysis.risks)
                if !analysis.speakerSuggestions.isEmpty {
                    Text("Speaker suggestions").font(.headline)
                    ForEach(analysis.speakerSuggestions, id: \.utteranceID) { suggestion in
                        HStack {
                            Text(suggestion.suggestedName)
                            Spacer()
                            Button("Accept") {
                                Task {
                                    await controller.perform(
                                        .acceptSpeakerSuggestion(suggestion.utteranceID)
                                    )
                                }
                            }
                        }
                    }
                }
                if !analysis.actionItems.isEmpty {
                    Text("Action items").font(.headline)
                    ForEach(Array(analysis.actionItems.enumerated()), id: \.offset) { _, item in
                        Text("• \(item.text)" + actionMetadata(item))
                            .textSelection(.enabled)
                    }
                }
                if let draft = model.followUp {
                    Divider()
                    Text("Follow-up draft").font(.headline)
                    LabeledContent("Subject") { Text(draft.subject).textSelection(.enabled) }
                    Text(draft.body).textSelection(.enabled)
                    HStack {
                        Button("Copy Subject") {
                            Task { await controller.perform(.copyDraft(.subject)) }
                        }
                        Button("Copy Body") {
                            Task { await controller.perform(.copyDraft(.body)) }
                        }
                        Button("Copy All") {
                            Task { await controller.perform(.copyDraft(.all)) }
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }
            } else if model.analysisState == .running {
                MeetingWorkPlaceholder(
                    title: "Analyzing transcript",
                    detail: "Brain is creating the summary, topics, decisions, and follow-up draft."
                )
            } else {
                Text("No local analysis yet. The final transcript remains available and uploadable.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func talkTimeSection(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk time").font(.title3.bold())
            if model.talkTime.isEmpty {
                Text("No attributed speech.").foregroundStyle(.secondary)
            } else {
                ForEach(model.talkTime) { speaker in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(speaker.displayName)
                            Spacer()
                            Text(String(format: "%.1f%%", speaker.percentage))
                                .monospacedDigit()
                        }
                        ProgressView(value: speaker.percentage, total: 100)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(speaker.accessibilityLabel)
                }
            }
        }
    }

    private func speakerSection(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Speakers").font(.title3.bold())
                Spacer()
                Button("Undo speaker edit", systemImage: "arrow.uturn.backward") {
                    Task { await controller.perform(.undoSpeakerEdit) }
                }
                .keyboardShortcut("z", modifiers: [.command])
            }
            ForEach(model.speakers) { speaker in
                HStack {
                    TextField(
                        "Speaker name",
                        text: speakerNameBinding(speaker)
                    )
                    .onSubmit {
                        Task {
                            await controller.perform(.renameSpeaker(
                                id: speaker.id,
                                name: speakerNames[speaker.id] ?? speaker.displayName
                            ))
                        }
                    }
                    Menu("Merge") {
                        ForEach(model.speakers.filter { $0.id != speaker.id }) { target in
                            Button("Into \(target.displayName)") {
                                Task {
                                    await controller.perform(.mergeSpeakers(
                                        sourceIDs: [speaker.id],
                                        into: target.id
                                    ))
                                }
                            }
                        }
                    }
                    .disabled(model.speakers.count < 2)
                }
            }
        }
    }

    private func uploadSection(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vault delivery").font(.title3.bold())
            HStack {
                if let badge = model.badges.first(where: { $0.kind == .upload }) {
                    Label(badge.title, systemImage: badge.systemImage)
                        .accessibilityLabel(badge.accessibilityLabel)
                }
                Spacer()
                if model.uploadCanRetry {
                    Button("Retry Delivery", systemImage: "arrow.clockwise") {
                        Task { await controller.perform(.retryUpload) }
                    }
                }
                if model.uploadCanReupload {
                    Button(
                        model.isVoiceNote ? "Re-upload Changed Voice Note" : "Re-upload Changed Meeting",
                        systemImage: "icloud.and.arrow.up"
                    ) {
                        Task { await controller.perform(.reupload) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func audioSection(_ model: MeetingDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local audio").font(.title3.bold())
            if model.audioControls.isEmpty {
                Text("No retained recording. Audio retention is off by default.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Reveal", systemImage: "folder") {
                        Task { await controller.perform(.revealAudio) }
                    }
                    Button("Export", systemImage: "square.and.arrow.up") {
                        exportAudio()
                    }
                    Button("Delete Recording", systemImage: "trash", role: .destructive) {
                        Task { await controller.perform(.requestAudioDeletion) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcript(_ model: MeetingDetailViewModel) -> some View {
        if !model.hasTranscript {
            if model.transcriptionState == .processing || model.transcriptionState == .pending {
                MeetingWorkPlaceholder(
                    title: model.transcriptionState == .processing
                        ? (model.isVoiceNote ? "Transcribing voice note" : "Transcribing meeting")
                        : "Transcript queued",
                    detail: model.transcriptionState == .processing
                        ? "Brain is processing the saved recording locally. The transcript will appear here when it is ready."
                        : "The saved recording is ready for local transcription."
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView(
                    model.transcriptionState == .failed ? "Transcript failed" : "No transcript yet",
                    systemImage: model.transcriptionState == .failed
                        ? "exclamationmark.bubble"
                        : "text.quote",
                    description: Text(
                        model.transcriptionMessage
                            ?? (model.isVoiceNote
                                ? "The voice note completed without visible utterances."
                                : "The meeting completed without visible utterances.")
                    )
                )
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Select utterances to reassign or split.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("Reassign") {
                        ForEach(model.speakers) { speaker in
                            Button(speaker.displayName) {
                                Task {
                                    await controller.perform(.reassign(
                                        utteranceIDs: controller.selectedUtteranceIDs,
                                        to: speaker.id
                                    ))
                                }
                            }
                        }
                    }
                    .disabled(controller.selectedUtteranceIDs.isEmpty)
                    Menu("Split to new speaker") {
                        ForEach(model.speakers) { speaker in
                            Button("From \(speaker.displayName)") {
                                Task {
                                    await controller.perform(.split(
                                        speakerID: speaker.id,
                                        utteranceIDs: controller.selectedUtteranceIDs,
                                        name: nil
                                    ))
                                }
                            }
                        }
                    }
                    .disabled(controller.selectedUtteranceIDs.isEmpty)
                }
                .padding()
                Divider()
                List(model.transcript) { row in
                    Button { controller.toggleSelection(row.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            Text(row.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.speakerName).font(.caption.bold())
                                    Text(row.provenance.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(row.text).textSelection(.enabled)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((row.isSelected ? "Selected, " : "") + row.accessibilityLabel)
                }
            }
        }
    }

    private struct MeetingWorkPlaceholder: View {
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func valueList(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if values.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)").textSelection(.enabled)
                }
            }
        }
    }

    private func actionMetadata(_ item: MeetingAnalysisActionItem) -> String {
        [item.owner, item.due].compactMap { $0 }.map { " — \($0)" }.joined()
    }

    private var tabBinding: Binding<MeetingDetailTab> {
        Binding(
            get: { controller.selectedTab },
            set: { tab in Task { await controller.perform(.selectTab(tab)) } }
        )
    }

    private var audioConfirmationBinding: Binding<Bool> {
        Binding(
            get: { controller.isAudioDeletionPending },
            set: { presented in
                if !presented {
                    Task { await controller.perform(.cancelAudioDeletion) }
                }
            }
        )
    }

    private var meetingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { controller.isMeetingDeletionPending },
            set: { presented in
                if !presented {
                    Task { await controller.perform(.cancelMeetingDeletion) }
                }
            }
        )
    }

    private func speakerNameBinding(_ speaker: MeetingDetailSpeakerModel) -> Binding<String> {
        Binding(
            get: { speakerNames[speaker.id] ?? speaker.displayName },
            set: { speakerNames[speaker.id] = $0 }
        )
    }

    private func synchronizeSpeakerNames(_ speakers: [MeetingDetailSpeakerModel]) {
        for speaker in speakers where speakerNames[speaker.id] == nil {
            speakerNames[speaker.id] = speaker.displayName
        }
        speakerNames = speakerNames.filter { id, _ in speakers.contains { $0.id == id } }
    }

    private func exportAudio() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(controller.titleDraft).caf"
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        Task { await controller.perform(.exportAudio(panel.url)) }
    }
}
