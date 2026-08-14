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

struct MeetingDetailTranscriptRowModel: Equatable, Identifiable, Sendable {
    let id: UUID
    let utteranceIDs: [UUID]
    let timestamp: String
    let speakerID: String
    let speakerName: String
    let provenance: SpeakerAssignmentProvenance
    let text: String
    let isSelected: Bool

    var accessibilityLabel: String { "\(timestamp), \(speakerName): \(text)" }
}

struct VoiceNoteTranscriptViewModel: Equatable, Sendable {
    static let paragraphBreakPauseMilliseconds: Int64 = 1_500
    static let preferredMaximumParagraphCharacters = 700

    let paragraphs: [String]

    var fullText: String { paragraphs.joined(separator: "\n\n") }

    init(utterances: [MeetingUtterance]) {
        let ordered = utterances
            .filter { !$0.suppressed }
            .sorted {
                if $0.startMilliseconds != $1.startMilliseconds {
                    return $0.startMilliseconds < $1.startMilliseconds
                }
                if $0.endMilliseconds != $1.endMilliseconds {
                    return $0.endMilliseconds < $1.endMilliseconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var completed: [String] = []
        var current = ""
        var previousEnd: Int64?
        for utterance in ordered {
            let text = utterance.text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !text.isEmpty else { continue }

            let followsNaturalPause = previousEnd.map {
                utterance.startMilliseconds - $0 >= Self.paragraphBreakPauseMilliseconds
            } ?? false
            let wouldBecomeTooLong = !current.isEmpty
                && current.count + 1 + text.count > Self.preferredMaximumParagraphCharacters
            if followsNaturalPause || wouldBecomeTooLong {
                completed.append(current)
                current = text
            } else if current.isEmpty {
                current = text
            } else {
                current += " \(text)"
            }
            previousEnd = max(previousEnd ?? utterance.endMilliseconds, utterance.endMilliseconds)
        }
        if !current.isEmpty { completed.append(current) }
        paragraphs = completed
    }
}

struct MeetingDetailSpeakerModel: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

struct MeetingDetailViewModel: Equatable, Sendable {
    let state: MeetingDetailLoadState
    let meetingID: UUID?
    let isVoiceNote: Bool
    let recordingKindNeedsReview: Bool
    let title: String
    let dateText: String
    let durationText: String
    let badges: [MeetingStatusBadge]
    let tab: MeetingDetailTab
    let transcript: [MeetingDetailTranscriptRowModel]
    let transcriptReview: MeetingTranscriptReviewViewModel?
    let voiceNoteTranscript: VoiceNoteTranscriptViewModel
    let speakers: [MeetingDetailSpeakerModel]
    let talkTime: [SpeakerTalkTime]
    let analysis: MeetingAnalysis?
    let audioControls: [MeetingAudioControl]
    let audioRetentionState: MeetingAudioRetentionState?
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

    var hasTranscript: Bool {
        isVoiceNote
            ? !voiceNoteTranscript.paragraphs.isEmpty
            : !(transcriptReview?.rawRows.isEmpty ?? transcript.isEmpty)
    }
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

protocol MeetingTranscriptArtifactLoading: Sendable {
    func load(
        meeting: MeetingRecord,
        legacyTranscript: [MeetingUtterance]
    ) throws -> MeetingTranscriptArtifact
}

extension MeetingTranscriptArtifactStore: MeetingTranscriptArtifactLoading {}

protocol MeetingTranscriptProcessingControlling: Sendable {
    func process(
        meeting: MeetingRecord,
        artifact: MeetingTranscriptArtifact,
        speakerState: SpeakerEditingState,
        notes: String,
        terminology: [String],
        terminologyHash: String
    ) async -> MeetingTranscriptProcessingRunResult
    func regenerate(
        meeting: MeetingRecord,
        artifact: MeetingTranscriptArtifact,
        speakerState: SpeakerEditingState,
        notes: String,
        terminology: [String],
        terminologyHash: String
    ) async -> MeetingTranscriptProcessingRunResult
}

extension MeetingTranscriptProcessingControlling {
    func regenerate(
        meeting: MeetingRecord,
        artifact: MeetingTranscriptArtifact,
        speakerState: SpeakerEditingState,
        notes: String,
        terminology: [String],
        terminologyHash: String
    ) async -> MeetingTranscriptProcessingRunResult {
        await process(
            meeting: meeting,
            artifact: artifact,
            speakerState: speakerState,
            notes: notes,
            terminology: terminology,
            terminologyHash: terminologyHash
        )
    }
}

extension MeetingTranscriptProcessingService: MeetingTranscriptProcessingControlling {}

struct SavedMeetingTranscriptProcessingControllerFactory {
    private let settings: any AISettingsPersisting
    private let providerFactory: any AIProviderMaking

    init(
        settings: any AISettingsPersisting = AISettingsStore(),
        providerFactory: any AIProviderMaking = LocalAIProviderFactory()
    ) {
        self.settings = settings
        self.providerFactory = providerFactory
    }

    func make() -> (any MeetingTranscriptProcessingControlling)? {
        let configuration = settings.load().canonicalized()
        return MeetingTranscriptProcessingService(
            provider: providerFactory.makeProvider(configuration: configuration)
        )
    }
}

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
    func hasDeletableRecording(for meetingID: UUID) -> Bool
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
        guard let metadata = meeting.retainedAudio,
              AudioRetentionController.supports(metadata) else { return false }
        let url = rootURL
            .appendingPathComponent(meeting.id.uuidString, isDirectory: true)
            .appendingPathComponent(metadata.filename)
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
    case setRecordingKind(MeetingRecordingKind)
    case selectTab(MeetingDetailTab)
    case renameSpeaker(id: String, name: String)
    case mergeSpeakers(sourceIDs: Set<String>, into: String)
    case reassign(utteranceIDs: Set<UUID>, to: String)
    case split(speakerID: String, utteranceIDs: Set<UUID>, name: String?)
    case undoSpeakerEdit
    case acceptSpeakerSuggestion(UUID)
    case analyze
    case reanalyze
    case copyFullTranscript
    case selectTranscriptReviewMode(MeetingTranscriptReviewMode)
    case regenerateTranscript
    case seekAudio(Int64)
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
    static let audioDeletionWarning = "Delete this saved recording from this Mac? The transcript and any delivered vault capture remain available."

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
    private(set) var isAudioDeletionInProgress = false
    private(set) var isTranscriptionRetryInProgress = false
    private(set) var isMeetingDeletionInProgress = false
    private(set) var isPlayableAudioAvailable = false
    private(set) var isAudioDeletionAvailable = false
    var selectedTab: MeetingDetailTab = .summary
    var transcriptReviewMode: MeetingTranscriptReviewMode = .raw
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
    @ObservationIgnored private let transcriptArtifactStore: any MeetingTranscriptArtifactLoading
    @ObservationIgnored private let processedTranscriptStore: any MeetingProcessedTranscriptStoring
    @ObservationIgnored private let transcriptProcessingController: (any MeetingTranscriptProcessingControlling)?
    @ObservationIgnored private let terminologyStore: MeetingTerminologyStore
    @ObservationIgnored private var transcriptProcessingTask: Task<Void, Never>?
    let audioPlayback: MeetingAudioPlaybackController
    private(set) var rawTranscriptArtifact: MeetingTranscriptArtifact?
    private(set) var processedTranscript: MeetingProcessedTranscript?
    private(set) var transcriptProcessingMessage: String?
    private(set) var isTranscriptRegenerationInProgress = false
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
            MeetingTranscriptionCoordinator(),
        transcriptArtifactStore: any MeetingTranscriptArtifactLoading =
            MeetingTranscriptArtifactStore(),
        processedTranscriptStore: any MeetingProcessedTranscriptStoring =
            MeetingProcessedTranscriptStore(),
        transcriptProcessingController: (any MeetingTranscriptProcessingControlling)? =
            SavedMeetingTranscriptProcessingControllerFactory().make(),
        terminologyStore: MeetingTerminologyStore = MeetingTerminologyStore(),
        audioPlayback: MeetingAudioPlaybackController = MeetingAudioPlaybackController(
            engine: SystemMeetingAudioPlayer()
        )
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
        self.transcriptArtifactStore = transcriptArtifactStore
        self.processedTranscriptStore = processedTranscriptStore
        self.transcriptProcessingController = transcriptProcessingController
        self.terminologyStore = terminologyStore
        self.audioPlayback = audioPlayback
    }

    var viewModel: MeetingDetailViewModel {
        let meeting = meeting
        let assignments = editor.assignments
        let speakers = editor.speakers
        let rows = MeetingTranscriptTurnAssembler.assemble(
            utterances: editor.utterances,
            assignments: assignments,
            speakers: speakers
        )
            .map { turn -> MeetingDetailTranscriptRowModel in
                return MeetingDetailTranscriptRowModel(
                    id: turn.id,
                    utteranceIDs: turn.utteranceIDs,
                    timestamp: Self.timestamp(turn.startMilliseconds),
                    speakerID: turn.speakerID,
                    speakerName: turn.speakerLabel,
                    provenance: turn.provenance,
                    text: turn.text,
                    isSelected: !turn.utteranceIDs.isEmpty
                        && turn.utteranceIDs.allSatisfy(selectedUtteranceIDs.contains)
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
        var audioControls: [MeetingAudioControl] = isPlayableAudioAvailable
            ? [.reveal, .export]
            : []
        if meeting != nil, isAudioDeletionAvailable {
            audioControls.append(.delete)
        }
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
            recordingKindNeedsReview: meeting?.recordingKindNeedsReview ?? false,
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
            transcriptReview: transcriptReviewViewModel,
            voiceNoteTranscript: VoiceNoteTranscriptViewModel(utterances: editor.utterances),
            speakers: speakerModels,
            talkTime: TalkTimeCalculator().calculate(for: editor).data,
            analysis: analysis,
            audioControls: audioControls,
            audioRetentionState: meeting?.audioRetentionState,
            transcriptionState: effectiveTranscriptionState,
            analysisState: effectiveMeeting?.analysisState,
            transcriptionCanRetry: meeting?.transcriptionState == .failed
                && meeting?.audioRetentionState != .deleted
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

    var transcriptReviewViewModel: MeetingTranscriptReviewViewModel? {
        guard let attempt = selectedRawTranscriptAttempt else { return nil }
        let rawTurns = MeetingTranscriptTurnAssembler.assemble(
            utterances: attempt.utterances,
            assignments: editor.assignments,
            speakers: editor.speakers
        )
        let rawRows = reviewRows(rawTurns, selected: true)
        let processedRows: [MeetingTranscriptReviewRowModel]
        if let processedTranscript {
            var assignments: [UUID: SpeakerAssignment] = [:]
            var speakers: [String: MeetingSpeaker] = [:]
            let utterances = processedTranscript.turns.compactMap { turn -> MeetingUtterance? in
                assignments[turn.id] = SpeakerAssignment(
                    speakerID: turn.speakerID,
                    provenance: .manual
                )
                speakers[turn.speakerID] = MeetingSpeaker(
                    id: turn.speakerID,
                    displayName: turn.speakerLabel
                )
                return try? MeetingUtterance(
                    id: turn.id,
                    source: .microphone,
                    startMilliseconds: turn.startMilliseconds,
                    endMilliseconds: turn.endMilliseconds,
                    text: turn.text,
                    baseSpeakerID: turn.speakerID,
                    humanName: turn.speakerLabel
                )
            }
            processedRows = reviewRows(
                MeetingTranscriptTurnAssembler.assemble(
                    utterances: utterances,
                    assignments: assignments,
                    speakers: speakers
                ),
                selected: false
            )
        } else {
            processedRows = []
        }

        let attestation = attempt.modelAttestation
        let identityMatches = attestation.requestedSelection == attestation.effectiveSelection
        let isVerified = attestation.verificationState == .verified && identityMatches
        let verificationLabel: String
        if attestation.verificationState == .unverifiedLegacy {
            verificationLabel = "Unverified legacy model identity"
        } else if !identityMatches {
            verificationLabel = "Unverified model mismatch"
        } else {
            verificationLabel = "Verified model identity"
        }

        return MeetingTranscriptReviewViewModel(
            mode: transcriptReviewMode,
            processedIsCurrent: processedTranscript != nil,
            processingIsRegenerating: isTranscriptRegenerationInProgress,
            processingMessage: transcriptProcessingMessage,
            bullets: Array(processedTranscript?.bullets.prefix(8) ?? []),
            rawRows: rawRows,
            processedRows: processedRows,
            quality: MeetingTranscriptQualityViewModel(
                rawUtteranceCount: attempt.utterances.count,
                retainedPreviewCount: attempt.retainedPreviews.count,
                skippedFinalCount: attempt.failureTotals.final,
                correctionCount: processedTranscript?.corrections.count ?? 0
            ),
            model: MeetingTranscriptModelViewModel(
                requested: Self.modelIdentity(attestation.requestedSelection),
                effective: Self.modelIdentity(attestation.effectiveSelection),
                verificationLabel: verificationLabel,
                isVerified: isVerified
            ),
            canCreateImprovementPrompt: transcriptReviewMode == .raw
                || processedTranscript != nil
        )
    }

    func improvementPrompt() -> String? {
        guard let meeting, let attempt = selectedRawTranscriptAttempt else { return nil }
        return MeetingImprovementPrompt.make(
            meeting: meeting,
            attempt: attempt,
            processedTranscript: transcriptReviewMode == .processed
                ? processedTranscript
                : nil
        )
    }

    private var selectedRawTranscriptAttempt: MeetingTranscriptAttempt? {
        guard let artifact = rawTranscriptArtifact,
              let selectedID = artifact.selectedAttemptID,
              let attempt = artifact.attempts.first(where: {
                  $0.id == selectedID && $0.isSuccessful
              }) else { return nil }
        if let currentID = meeting?.selectedRawTranscriptAttemptID {
            guard currentID == selectedID else { return nil }
        } else {
            guard selectedID == meeting?.id else { return nil }
        }
        return attempt
    }

    private func reviewRows(
        _ turns: [MeetingTranscriptTurn],
        selected: Bool
    ) -> [MeetingTranscriptReviewRowModel] {
        turns.map { turn in
            MeetingTranscriptReviewRowModel(
                id: turn.id,
                utteranceIDs: turn.utteranceIDs,
                startMilliseconds: turn.startMilliseconds,
                timestamp: Self.timestamp(turn.startMilliseconds),
                speakerName: turn.speakerLabel,
                provenance: turn.provenance,
                text: turn.text,
                isSelected: selected && !turn.utteranceIDs.isEmpty
                    && turn.utteranceIDs.allSatisfy(selectedUtteranceIDs.contains)
            )
        }
    }

    private func loadTranscriptReview(
        meeting: MeetingRecord,
        fallbackUtterances: [MeetingUtterance]
    ) {
        terminologyStore.reload()
        let artifact: MeetingTranscriptArtifact
        do {
            artifact = try transcriptArtifactStore.load(
                meeting: meeting,
                legacyTranscript: fallbackUtterances
            )
            rawTranscriptArtifact = artifact
        } catch {
            rawTranscriptArtifact = nil
            processedTranscript = nil
            transcriptReviewMode = .raw
            transcriptProcessingMessage = "Raw transcript review data is unavailable: \(Self.bounded(error))"
            return
        }
        guard let attempt = selectedRawTranscriptAttempt else {
            processedTranscript = nil
            transcriptReviewMode = .raw
            transcriptProcessingMessage = "The selected raw transcript is unavailable."
            return
        }
        do {
            let loaded = try processedTranscriptStore.load(
                meetingID: meeting.id,
                rawAttemptID: attempt.id,
                terminologyHash: terminologyStore.contentHash
            )
            if let loaded,
               loaded.version == MeetingTranscriptProcessingSchema.currentVersion,
               loaded.rawAttemptID == attempt.id,
               loaded.terminologyHash == terminologyStore.contentHash {
                processedTranscript = loaded
            } else {
                processedTranscript = nil
            }
            transcriptReviewMode = .processed
            transcriptProcessingMessage = processedTranscript == nil
                ? "Preparing a clean, readable transcript…"
                : nil
        } catch {
            processedTranscript = nil
            transcriptReviewMode = .processed
            transcriptProcessingMessage = "Processed transcript review data is unavailable: \(Self.bounded(error))"
        }
    }

    private func clearTranscriptReview() {
        transcriptProcessingTask?.cancel()
        transcriptProcessingTask = nil
        rawTranscriptArtifact = nil
        processedTranscript = nil
        transcriptReviewMode = .raw
        transcriptProcessingMessage = nil
    }

    private func regenerateTranscript() async {
        guard !isTranscriptRegenerationInProgress,
              let transcriptProcessingController,
              let meeting,
              let artifact = rawTranscriptArtifact,
              selectedRawTranscriptAttempt != nil else {
            transcriptProcessingMessage = "Configure and test a local AI provider before retrying processing."
            return
        }
        isTranscriptRegenerationInProgress = true
        transcriptReviewMode = .processed
        transcriptProcessingMessage = "Comparing the raw transcript with audio-derived evidence…"
        defer { isTranscriptRegenerationInProgress = false }
        let result = await transcriptProcessingController.regenerate(
            meeting: meeting,
            artifact: artifact,
            speakerState: editor.state,
            notes: "",
            terminology: terminologyStore.terms,
            terminologyHash: terminologyStore.contentHash
        )
        guard !Task.isCancelled, self.meeting != nil else { return }
        guard result.failure == nil,
              let transcript = result.transcript,
              transcript.rawAttemptID == selectedRawTranscriptAttempt?.id,
              transcript.terminologyHash == terminologyStore.contentHash else {
            processedTranscript = nil
            transcriptProcessingMessage = Self.processingFailureMessage(result.failure)
            return
        }
        processedTranscript = transcript
        transcriptReviewMode = .processed
        transcriptProcessingMessage = nil
    }

    func load() {
        let isInitialLoad = state == .idle
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
            refreshAudioCapabilities(for: stored.meeting)
            lastKnownRecordingKind = stored.meeting.recordingKind
            if isInitialLoad, stored.meeting.isVoiceNote {
                selectedTab = .transcript
            }
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
            loadTranscriptReview(meeting: stored.meeting, fallbackUtterances: stored.utterances)
            state = .ready
            startTranscriptProcessingIfNeeded()
        } catch let error as MeetingStoreError {
            meeting = nil
            refreshAudioCapabilities(for: nil)
            utterances = []
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            clearTranscriptReview()
            switch error {
            case .corruptMeeting, .unsafeStorePath:
                state = .corrupt(error.localizedDescription)
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            meeting = nil
            refreshAudioCapabilities(for: nil)
            utterances = []
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            clearTranscriptReview()
            state = .failed(Self.bounded(error))
        }
    }

    private func startTranscriptProcessingIfNeeded() {
        guard processedTranscript == nil,
              selectedRawTranscriptAttempt != nil,
              transcriptProcessingTask == nil,
              transcriptProcessingController != nil else { return }
        transcriptProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.regenerateTranscript()
            self.transcriptProcessingTask = nil
        }
    }

    func resumeUploadIfNeeded() async {
        guard let uploadRevision,
              [.queued, .delivering].contains(uploadRevision.state) else { return }
        await uploadController.uploadAfterFinalTranscriptPersistence(meetingID: meetingID)
        reloadMeetingAfterTypedAction()
    }

    func toggleSelection(_ utteranceIDs: [UUID]) {
        if utteranceIDs.allSatisfy(selectedUtteranceIDs.contains) {
            selectedUtteranceIDs.subtract(utteranceIDs)
        } else {
            selectedUtteranceIDs.formUnion(utteranceIDs)
        }
    }

    func perform(_ action: MeetingDetailAction) async {
        copiedMessage = nil
        switch action {
        case .saveTitle(let title):
            saveTitle(title)
        case .setRecordingKind(let kind):
            setRecordingKind(kind)
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
        case .copyFullTranscript:
            copyFullTranscript()
        case .selectTranscriptReviewMode(let mode):
            transcriptReviewMode = mode
        case .regenerateTranscript:
            await regenerateTranscript()
        case .seekAudio(let milliseconds):
            audioPlayback.seek(to: milliseconds)
        case .revealAudio:
            revealAudio()
        case .exportAudio(let destination):
            exportAudio(to: destination)
        case .requestAudioDeletion:
            guard isAudioDeletionAvailable,
                  !isAudioDeletionInProgress,
                  !isMeetingDeletionInProgress else { return }
            isAudioDeletionPending = true
        case .confirmAudioDeletion:
            await deleteAudio()
        case .cancelAudioDeletion:
            if !isAudioDeletionInProgress { isAudioDeletionPending = false }
        case .retryTranscription:
            await retryTranscription()
        case .retryUpload:
            await uploadController.retry(meetingID: meetingID)
            reloadMeetingAfterTypedAction()
        case .reupload:
            await uploadController.reupload(meetingID: meetingID)
            reloadMeetingAfterTypedAction()
        case .requestMeetingDeletion:
            guard meeting != nil, !isAudioDeletionInProgress else { return }
            isMeetingDeletionPending = true
        case .confirmMeetingDeletion:
            await deleteMeeting()
        case .cancelMeetingDeletion:
            isMeetingDeletionPending = false
        }
    }

    private func retryTranscription() async {
        guard meeting?.audioRetentionState != .deleted else {
            errorMessage = MeetingTranscriptionCoordinatorError
                .transcriptionNotRetryable.localizedDescription
            return
        }
        guard !isTranscriptionRetryInProgress,
              !isAudioDeletionInProgress,
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
            guard !isAudioDeletionInProgress,
                  !isMeetingDeletionInProgress,
                  state != .deleted else { return }
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

    private func setRecordingKind(_ recordingKind: MeetingRecordingKind) {
        guard var meeting else { return }
        guard meeting.recordingKind != recordingKind || meeting.recordingKindNeedsReview else {
            return
        }
        let previousMeeting = meeting
        meeting.recordingKind = recordingKind
        meeting.recordingKindNeedsReview = false
        do {
            try store.save(meeting, utterances: utterances)
            self.meeting = meeting
            lastKnownRecordingKind = recordingKind
            errorMessage = nil
        } catch {
            self.meeting = previousMeeting
            errorMessage = "The recording section was not changed: \(Self.bounded(error))"
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

    private func copyFullTranscript() {
        let value: String
        let message: String
        if meeting?.isVoiceNote == true {
            value = viewModel.voiceNoteTranscript.fullText
            message = "Full transcript copied"
        } else {
            guard let review = transcriptReviewViewModel else { return }
            value = review.fullText
            message = "\(review.mode.rawValue) transcript copied"
        }
        guard !value.isEmpty else { return }
        clipboard.write(value)
        copiedMessage = message
    }

    private func revealAudio() {
        guard isPlayableAudioAvailable else { return }
        do {
            try audioController.revealRecording(for: meetingID)
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func exportAudio(to destination: URL?) {
        guard isPlayableAudioAvailable else { return }
        do {
            _ = try audioController.exportRecording(for: meetingID, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func deleteAudio() async {
        guard isAudioDeletionPending,
              !isAudioDeletionInProgress,
              isAudioDeletionAvailable else { return }
        isAudioDeletionPending = false
        isAudioDeletionInProgress = true
        audioPlayback.release()
        defer { isAudioDeletionInProgress = false }

        do {
            var deletedMeeting: MeetingRecord?
            try await transcriptionController.cancelAndWaitForDeletion(
                meetingID: meetingID
            ) {
                guard state != .deleted, !isMeetingDeletionInProgress else { return }
                deletedMeeting = try audioController.deleteRecording(
                    for: meetingID,
                    confirmed: true
                )
            }
            if let deletedMeeting {
                meeting = deletedMeeting
                isPlayableAudioAvailable = false
                isAudioDeletionAvailable = false
            }
            errorMessage = nil
        } catch {
            let deletionError = Self.bounded(error)
            reloadMeetingAfterTypedAction()
            errorMessage = deletionError
        }
    }

    private func deleteMeeting() async {
        guard isMeetingDeletionPending, !isMeetingDeletionInProgress else { return }
        isMeetingDeletionInProgress = true
        transcriptProcessingTask?.cancel()
        transcriptProcessingTask = nil
        do {
            try await transcriptionController.cancelAndWaitForDeletion(
                meetingID: meetingID
            ) {
                try store.delete(meetingID, confirmed: true)
            }
            isMeetingDeletionPending = false
            meeting = nil
            audioPlayback.release()
            refreshAudioCapabilities(for: nil)
            utterances = []
            analysis = nil
            uploadRevision = nil
            editor = SpeakerEditor(utterances: [])
            clearTranscriptReview()
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
            refreshAudioCapabilities(for: stored.meeting)
            loadTranscriptReview(meeting: stored.meeting, fallbackUtterances: stored.utterances)
            loadUploadRevision()
            errorMessage = uploadController.errorMessage ?? errorMessage
        } catch {
            errorMessage = Self.bounded(error)
        }
    }

    private func refreshAudioCapabilities(for meeting: MeetingRecord?) {
        guard let meeting else {
            isPlayableAudioAvailable = false
            isAudioDeletionAvailable = false
            audioPlayback.release()
            return
        }
        isPlayableAudioAvailable = meeting.retainedAudio != nil
            && audioChecker.hasLocalAudio(for: meeting)
        isAudioDeletionAvailable = audioController.hasDeletableRecording(for: meetingID)
        if isPlayableAudioAvailable {
            audioPlayback.load(meetingID: meetingID)
        } else {
            audioPlayback.release()
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

    private static func timestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", totalSeconds / 60, totalSeconds % 60)
    }

    private static func modelIdentity(_ selection: SpeechEngineSelection) -> String {
        "\(selection.engine.rawValue)/\(selection.modelID)"
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

    private static func processingFailureMessage(
        _ failure: MeetingTranscriptProcessingFailure?
    ) -> String {
        switch failure {
        case .noSelectedRawAttempt: "The selected raw transcript is unavailable."
        case .selectedRawAttemptNotSuccessful: "The selected raw attempt did not complete successfully."
        case .providerNotReady: "The configured local AI provider is not ready."
        case .providerFailure(let error): error.localizedDescription
        case .cancelled: "Transcript processing was cancelled."
        case .schemaFailure: "The processed transcript did not pass its evidence checks."
        case .persistenceFailure: "The processed transcript could not be saved."
        case nil: "The processed transcript is unavailable or stale."
        }
    }
}

struct MeetingDetailView: View {
    @State private var controller: MeetingDetailController
    @State private var speakerNames: [String: String] = [:]
    @State private var showsTranscriptHighlights = false

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
            .labelsHidden()
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
                Menu("Actions", systemImage: "ellipsis.circle") {
                    if model.audioControls.contains(.reveal) {
                        Button("Reveal in Finder", systemImage: "folder") {
                            Task { await controller.perform(.revealAudio) }
                        }
                    }
                    if model.audioControls.contains(.export) {
                        Button("Export", systemImage: "square.and.arrow.up") {
                            exportAudio()
                        }
                    }
                    if model.audioControls.contains(.reveal) || model.audioControls.contains(.export) {
                        Divider()
                    }
                    Button(
                        model.isVoiceNote ? "Move to Meetings" : "Move to Voice Notes",
                        systemImage: "arrow.left.arrow.right"
                    ) {
                        Task {
                            await controller.perform(.setRecordingKind(
                                model.isVoiceNote ? .meeting : .voiceNote
                            ))
                        }
                    }
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
            if model.recordingKindNeedsReview {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Choose a section for this older recording", systemImage: "questionmark.folder")
                        .font(.callout.weight(.semibold))
                    Text("Brain kept it in Meetings because older recordings did not store whether they were a meeting or a voice note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Keep in Meetings") {
                            Task { await controller.perform(.setRecordingKind(.meeting)) }
                        }
                        Button("Move to Voice Notes") {
                            Task { await controller.perform(.setRecordingKind(.voiceNote)) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
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
                transcriptHighlightsSection(model)
                analysisSection(model)
                if !model.isVoiceNote {
                    talkTimeSection(model)
                    speakerSection(model)
                }
                uploadSection(model)
                audioSection(model)
            }
            .padding()
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func transcriptHighlightsSection(_ model: MeetingDetailViewModel) -> some View {
        if let highlights = model.transcriptReview?.bullets, !highlights.isEmpty {
            DisclosureGroup(isExpanded: $showsTranscriptHighlights) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(highlights.enumerated()), id: \.offset) { _, highlight in
                        Text("• \(highlight)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Highlights").font(.title3.bold())
            }
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
                if !model.isVoiceNote, !analysis.speakerSuggestions.isEmpty {
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
            } else if model.analysisState == .running {
                MeetingWorkPlaceholder(
                    title: "Analyzing transcript",
                    detail: "Brain is creating the summary, topics, decisions, and action items."
                )
            } else {
                Text("No local analysis yet. The final transcript remains available and can be saved to the vault.")
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
            Text("Local vault").font(.title3.bold())
            HStack {
                if let badge = model.badges.first(where: { $0.kind == .upload }) {
                    Label(badge.title, systemImage: badge.systemImage)
                        .accessibilityLabel(badge.accessibilityLabel)
                }
                Spacer()
                if model.uploadCanRetry {
                    Button("Retry Local Ingest", systemImage: "arrow.clockwise") {
                        Task { await controller.perform(.retryUpload) }
                    }
                }
                if model.uploadCanReupload {
                    Button(
                        model.isVoiceNote ? "Save Changed Voice Note Again" : "Save Changed Meeting Again",
                        systemImage: "internaldrive"
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
            if !model.audioControls.contains(.reveal) {
                if model.audioControls.contains(.delete) {
                    Text("Brain keeps source audio available for transcript recovery. A playable recording will appear here after transcription completes.")
                        .foregroundStyle(.secondary)
                } else if model.audioRetentionState == .deleted {
                    Text("The local recording was deleted. Any saved transcript remains available.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No playable recording is available for this item.")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.audioControls.isEmpty {
                if model.audioControls.contains(.reveal), controller.audioPlayback.meetingID != nil {
                    MeetingAudioPlayerView(controller: controller.audioPlayback)
                }
                HStack {
                    if model.audioControls.contains(.reveal) {
                        Button("Reveal in Finder", systemImage: "folder") {
                            Task { await controller.perform(.revealAudio) }
                        }
                    }
                    if model.audioControls.contains(.export) {
                        Button("Export", systemImage: "square.and.arrow.up") {
                            exportAudio()
                        }
                    }
                    if model.audioControls.contains(.delete) {
                        Button("Delete Recording", systemImage: "trash", role: .destructive) {
                            Task { await controller.perform(.requestAudioDeletion) }
                        }
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
            if model.isVoiceNote {
                voiceNoteTranscript(model)
            } else if let review = model.transcriptReview {
                VStack(spacing: 0) {
                    if review.mode == .raw {
                        meetingTranscriptEditingControls(model)
                        Divider()
                    }
                    MeetingTranscriptReviewView(
                        model: review,
                        audioPlayback: controller.audioPlayback,
                        selectMode: { mode in
                            Task { await controller.perform(.selectTranscriptReviewMode(mode)) }
                        },
                        regenerateTranscript: {
                            Task { await controller.perform(.regenerateTranscript) }
                        },
                        seek: { milliseconds in
                            Task { await controller.perform(.seekAudio(milliseconds)) }
                        },
                        toggleSelection: controller.toggleSelection,
                        copyTranscript: {
                            Task { await controller.perform(.copyFullTranscript) }
                        },
                        createImprovementPrompt: controller.improvementPrompt
                    )
                }
            } else {
                editableMeetingTranscript(model)
            }
        }
    }

    private func voiceNoteTranscript(_ model: MeetingDetailViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcript")
                            .font(.title3.bold())
                        Text("Single-speaker text, split into readable paragraphs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy Full Transcript", systemImage: "doc.on.doc") {
                        Task { await controller.perform(.copyFullTranscript) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .accessibilityHint("Copies every paragraph of this voice note.")
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(
                        Array(model.voiceNoteTranscript.paragraphs.enumerated()),
                        id: \.offset
                    ) { _, paragraph in
                        Text(paragraph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Full voice note transcript")
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func editableMeetingTranscript(_ model: MeetingDetailViewModel) -> some View {
        VStack(spacing: 0) {
            meetingTranscriptEditingControls(model)
            Divider()
            List(model.transcript) { row in
                Button { controller.toggleSelection(row.utteranceIDs) } label: {
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

    private func meetingTranscriptEditingControls(_ model: MeetingDetailViewModel) -> some View {
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
        let pathExtension = controller.meeting?.retainedAudio.map {
            URL(fileURLWithPath: $0.filename).pathExtension
        } ?? "m4a"
        panel.nameFieldStringValue = "\(controller.titleDraft).\(pathExtension)"
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        Task { await controller.perform(.exportAudio(panel.url)) }
    }
}
