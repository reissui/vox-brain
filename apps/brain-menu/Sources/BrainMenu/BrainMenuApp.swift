import AppKit
import Foundation
import Observation
import SwiftUI

extension Notification.Name {
    static let brainOpenDashboardWindow = Notification.Name("BrainOpenDashboardWindow")
}

@MainActor
final class BrainApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .brainOpenDashboardWindow, object: nil)
        return true
    }
}

enum BrainAppLaunchDestination: Equatable, Sendable {
    case setup
    case dashboard
}

enum BrainAppActivity: Equatable, Sendable {
    case idle
    case meeting(label: String, startedAt: Date)
    case dictation(label: String, startedAt: Date)
    case transcribing(String)

    var label: String {
        switch self {
        case .idle: "Brain"
        case .meeting(let label, _), .dictation(let label, _), .transcribing(let label):
            label
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "brain.head.profile"
        case .meeting: "record.circle.fill"
        case .dictation: "mic.fill"
        case .transcribing: "waveform"
        }
    }

    var startedAt: Date? {
        switch self {
        case .meeting(_, let startedAt), .dictation(_, let startedAt):
            startedAt
        case .idle, .transcribing:
            nil
        }
    }
}

struct BrainMenuBarPresentation: Equatable, Sendable {
    let symbolName: String
    let accessibilityLabel: String
    let elapsedText: String?

    init(activity: BrainAppActivity, now: Date) {
        symbolName = activity.symbolName
        if let startedAt = activity.startedAt {
            let elapsed = Self.elapsed(from: startedAt, to: now)
            elapsedText = elapsed
            accessibilityLabel = "\(activity.label), \(elapsed) elapsed"
        } else {
            elapsedText = nil
            accessibilityLabel = activity.label
        }
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

struct MeetingSavedNotice: Equatable, Identifiable, Sendable {
    let meetingID: UUID
    let title: String
    let recordingKind: MeetingRecordingKind

    var id: UUID { meetingID }
    var isVoiceNote: Bool { recordingKind == .voiceNote }
    var message: String {
        isVoiceNote
            ? "Added to Voice Notes. It is now at the top of the list."
            : "Added to Meetings. It is now at the top of the list."
    }
}

extension MeetingController {
    var isCapturingAudio: Bool {
        switch state {
        case .starting, .recording, .paused, .stopSuggested, .finalizing:
            true
        case .idle, .startSuggested, .sourceSelectionRequired, .completed, .failed:
            false
        }
    }

    var shouldPresentRecordingIsland: Bool {
        isCapturingAudio || state == .sourceSelectionRequired
    }
}

/// The application-lifetime dependency root. SwiftUI scenes borrow these
/// objects; they never construct event taps, recorders, pollers, or islands.
@MainActor
@Observable
final class BrainAppControllerGraph {
    let store: BrainStore
    let onboarding: OnboardingController
    let capture: CaptureController
    let quickCapture: QuickCaptureController
    let quickCapturePresenter: QuickCapturePanelPresenter
    let adaptiveCapture: AdaptiveCaptureController
    let captureHotkey: CaptureHotkeyController
    let dictationHistory: DictationHistoryStore
    let dictation: DictationController
    let continuousDictation: ContinuousDictationController
    let meeting: MeetingController
    let meetingHotkey: MeetingHotkeyController
    let meetingNotes: MeetingNotesController
    let meetingLiveDashboard: MeetingLiveDashboardController
    let meetingLivePanel: MeetingLivePanelController
    let recordingIsland: RecordingIslandController
    let meetings: MeetingsController
    let launchAtLogin: LaunchAtLoginController
    let speechSettings: SpeechSettingsController
    let aiSettings: AISettingsController
    let librarianAI: LibrarianAIController
    let updates: UpdateController
    let audioRetention: AudioRetentionController

    private(set) var startCount = 0
    private(set) var activityRevision: UInt64 = 0
    private(set) var meetingSavedNotice: MeetingSavedNotice?

    @ObservationIgnored private let meetingAudioOwnership: MeetingAudioOwnership
    @ObservationIgnored private let meetingTranscription: MeetingTranscriptionCoordinator?
    @ObservationIgnored private let actionRouter: BrainAppActionRouter
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var automaticMeetingAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private let meetingAnalysisFactory: @MainActor () -> (any MeetingDetailAnalysisControlling)?
    @ObservationIgnored private var lastNotifiedMeetingID: UUID?
    @ObservationIgnored private var dictationStartedAt: Date?
    @ObservationIgnored private var activityClockTask: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> Date

    var launchDestination: BrainAppLaunchDestination {
        store.isReady ? .dashboard : .setup
    }

    var activity: BrainAppActivity {
        _ = activityRevision
        if meeting.state == .completed,
           meeting.currentMeeting?.transcriptionState == .processing {
            return .transcribing("Transcribing saved recording")
        }
        switch meeting.state {
        case .finalizing:
            return .transcribing(
                meeting.currentMeeting?.recordingKind == .voiceNote
                    ? "Finalizing voice note"
                    : "Finalizing meeting"
            )
        case .starting, .recording, .paused, .stopSuggested:
            if let startedAt = meeting.currentMeeting?.startedAt {
                if meeting.currentMeeting?.recordingKind == .voiceNote {
                    return .dictation(
                        label: meeting.state == .paused
                            ? "Voice note paused"
                            : "Recording voice note",
                        startedAt: startedAt
                    )
                }
                return .meeting(
                    label: meeting.state == .paused ? "Meeting paused" : "Recording meeting",
                    startedAt: startedAt
                )
            }
        case .idle, .startSuggested, .sourceSelectionRequired, .completed, .failed:
            break
        }
        switch dictation.state {
        case .listening, .locked:
            if let dictationStartedAt {
                return .dictation(label: "Dictating", startedAt: dictationStartedAt)
            }
        case .transcribing:
            return .transcribing("Transcribing dictation")
        case .idle, .unavailable, .failed:
            break
        }
        return .idle
    }

    init(
        store: BrainStore = BrainStore(),
        onboarding: OnboardingController = OnboardingController(),
        capture: CaptureController = CaptureController(),
        meeting: MeetingController? = nil,
        meetingNotesStore: (any MeetingNotesStoring)? = nil,
        dictationHistory: DictationHistoryStore = DictationHistoryStore(),
        dictation: DictationController? = nil,
        continuousDictation: ContinuousDictationController? = nil,
        recordingIsland: RecordingIslandController? = nil,
        meetings: MeetingsController = MeetingsController(),
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        captureHotkeyRegistrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(),
        frontmostApplications: any FrontmostApplicationProviding = WorkspaceFrontmostApplicationProvider(),
        speechSettings: SpeechSettingsController? = nil,
        aiSettings: AISettingsController = AISettingsController(settings: AISettingsStore()),
        librarianAI: LibrarianAIController = LibrarianAIController(),
        updates: UpdateController = UpdateController(),
        audioRetention: AudioRetentionController = AudioRetentionController(),
        now: @escaping @MainActor () -> Date = Date.init,
        meetingAnalysisFactory: @escaping @MainActor () -> (any MeetingDetailAnalysisControlling)? = {
            SavedMeetingAnalysisControllerFactory().make()
        }
    ) {
        self.store = store
        self.onboarding = onboarding
        self.capture = capture
        self.meetings = meetings
        self.launchAtLogin = launchAtLogin
        self.aiSettings = aiSettings
        self.librarianAI = librarianAI
        self.updates = updates
        self.audioRetention = audioRetention
        self.now = now
        self.meetingAnalysisFactory = meetingAnalysisFactory
        self.dictationHistory = dictationHistory
        let router = BrainAppActionRouter()
        actionRouter = router

        let ownership = MeetingAudioOwnership()
        meetingAudioOwnership = ownership
        let voxType = try? VoxTypeClient.discover()
        let modelActivator: VoxTypeModelActivator? = voxType.map {
            VoxTypeModelActivator(
                configuration: VoxTypeConfigurationEditor(),
                statuses: $0
            )
        }
        let modelSource: VoxTypeModelSourceOfTruth? = voxType.map {
            VoxTypeModelSourceOfTruth(
                activator: modelActivator,
                voxType: $0
            )
        }
        let nativeDictation = dictation ?? DictationController(
            voxType: voxType,
            audioCapture: ownership
        )
        self.dictation = nativeDictation
        self.continuousDictation = continuousDictation ?? ContinuousDictationController(
            voxType: voxType,
            statuses: voxType,
            dictation: nativeDictation,
            audioCapture: ownership
        )
        let microphoneSelections = MeetingMicrophoneSelectionStore()
        let microphoneInventory = CoreAudioMeetingMicrophoneInventory()
        let nativeMeeting: MeetingController
        let nativeNotesStore: any MeetingNotesStoring
        if let meeting {
            nativeMeeting = meeting
            nativeNotesStore = meetingNotesStore ?? MeetingNotesStore()
            meetingTranscription = nil
        } else {
            let built = Self.makeMeetingController(
                audioRetention: audioRetention,
                ownership: ownership,
                microphoneSelections: microphoneSelections,
                microphoneInventory: microphoneInventory,
                modelAttester: modelSource
            )
            nativeMeeting = built.controller
            nativeNotesStore = meetingNotesStore ?? built.notesStore
            meetingTranscription = built.transcription
        }
        self.meeting = nativeMeeting
        let notesController = MeetingNotesController(store: nativeNotesStore)
        meetingNotes = notesController
        let liveDashboard = MeetingLiveDashboardController(
            meetingController: nativeMeeting,
            notesController: notesController
        )
        meetingLiveDashboard = liveDashboard
        meetingLivePanel = MeetingLivePanelController(dashboardController: liveDashboard)
        meetingHotkey = MeetingHotkeyController(
            registrar: SystemCaptureHotkeyRegistrar(identifier: 4)
        ) {
            router.toggleMeeting()
        }
        let quickCapture = QuickCaptureController(
            captureController: capture,
            permissionGate: OnboardingQuickCapturePermissionGate(onboarding: onboarding)
        )
        self.quickCapture = quickCapture
        let presenter = QuickCapturePanelPresenter(controller: quickCapture)
        quickCapturePresenter = presenter
        let adaptiveCapture = AdaptiveCaptureController(captureController: capture)
        self.adaptiveCapture = adaptiveCapture
        captureHotkey = CaptureHotkeyController(
            panel: presenter,
            registrar: captureHotkeyRegistrar,
            applications: frontmostApplications,
            adaptiveCapture: adaptiveCapture
        )

        let island = recordingIsland ?? RecordingIslandController(actionHandler: { action in
            router.perform(action)
        }, microphoneSelectionHandler: { selection in
            router.selectMicrophone(selection)
        })
        self.recordingIsland = island

        self.speechSettings = speechSettings ?? Self.makeSpeechSettings(
            client: voxType,
            modelActivator: modelActivator,
            modelSource: modelSource,
            microphoneSelections: microphoneSelections,
            microphoneService: SystemMeetingMicrophoneService(
                inventoryProvider: microphoneInventory
            )
        )
        capture.setDeliveryHandler { [weak librarianAI] _ in
            librarianAI?.captureDelivered()
        }
        router.graph = self
        nativeMeeting.setTransitionHandler { [weak self] in
            self?.meetingDidTransition()
        }
        nativeMeeting.setLiveTranscriptControllerHandler { [weak self] transcript in
            guard let self else { return }
            guard let transcript,
                  let kind = self.meeting.currentMeeting?.recordingKind else {
                self.meetingLivePanel.endSession()
                return
            }
            self.meetingLivePanel.beginSession(
                transcriptController: transcript,
                recordingKind: kind,
                meetingID: self.meeting.currentMeeting?.id
            )
        }
        nativeMeeting.setMeetingNotesFlushHandler { [weak notesController] in
            await notesController?.flush()
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startCount += 1
        store.start()
        librarianAI.start()
        _ = meetingHotkey.start()
        _ = continuousDictation.startShortcut()
        updates.start()
        dictationHistory.startMonitoring()
        observeDictation()
        dictation.startMonitoring()
        observeMeetingAudio()
        syncActivityClock()
        if meetingTranscription?.reconcileInterruptedJobs().isEmpty == false {
            meetings.load()
        }
        Task {
            if ProcessInfo.processInfo.environment["RUST_LOG"] == "warn" {
                try? await SystemVoxTypeApplicationRestarter().restart()
            }
            await onboarding.refresh()
            await speechSettings.refresh()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        store.stop()
        librarianAI.stop()
        meetingHotkey.stop()
        continuousDictation.stopShortcut()
        updates.stop()
        dictationHistory.stopMonitoring()
        dictation.stopMonitoring()
        activityClockTask?.cancel()
        activityClockTask = nil
        automaticMeetingAnalysisTask?.cancel()
        automaticMeetingAnalysisTask = nil
        meetingLivePanel.hide()
        recordingIsland.hideImmediately()
    }

    func openQuickCapture() {
        quickCapturePresenter.open(
            sourceApplication: WorkspaceFrontmostApplicationProvider().frontmostApplication
        )
    }

    func toggleMeeting() async {
        switch meeting.state {
        case .starting, .recording, .paused, .stopSuggested:
            await meeting.stop()
        case .idle, .completed, .failed, .startSuggested:
            guard await recordingSetupIsReady(for: .meeting) else { return }
            meetingSavedNotice = nil
            if meeting.state == .completed { meeting.resetCompletedMeeting() }
            if meeting.state == .failed { meeting.resetFailedMeeting() }
            await meeting.startRecording(application: nil)
        case .sourceSelectionRequired, .finalizing:
            return
        }
    }

    func startVoiceNote() async {
        guard [.idle, .completed, .failed, .startSuggested].contains(meeting.state) else { return }
        guard await recordingSetupIsReady(for: .voiceNote) else { return }
        meetingSavedNotice = nil
        if meeting.state == .completed { meeting.resetCompletedMeeting() }
        if meeting.state == .failed { meeting.resetFailedMeeting() }
        await meeting.startVoiceNote()
    }

    func recordingSetupCheck(for kind: MeetingRecordingKind) -> OnboardingCheck? {
        let requiredPermissions: [OnboardingCheckID] = kind == .meeting
            ? [.microphone, .systemAudio]
            : [.microphone]
        return requiredPermissions
            .map(onboarding.check)
            .first { $0.state != .ready }
    }

    func performRecordingSetupAction(_ action: OnboardingAction) async {
        await onboarding.perform(action)
    }

    func refreshRecordingSetup() async {
        await onboarding.refresh()
    }

    func dismissMeetingSavedNotice() {
        meetingSavedNotice = nil
    }

    fileprivate func performRecordingIslandAction(_ action: RecordingIslandAction) async {
        switch action {
        case .cancel:
            dictation.handle(.cancel)
        case .pause:
            await meeting.pause()
        case .resume:
            await meeting.resume()
        case .stop:
            if continuousDictation.state.isActive {
                continuousDictation.stop()
            } else {
                await meeting.stop()
            }
        case .keepRecording:
            meeting.keepRecording()
        case .showTranscript:
            guard meeting.isCapturingAudio else { return }
            meetingLivePanel.showTranscript()
        }
    }

    private func observeMeetingAudio() {
        withObservationTracking {
            _ = meeting.audioMonitor.levels
            _ = meeting.audioMonitor.histories
            _ = meeting.audioMonitor.signalStates
            _ = meeting.audioMonitor.guidance
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.activityRevision &+= 1
                self.syncRecordingIsland()
                self.observeMeetingAudio()
            }
        }
    }

    private func recordingSetupIsReady(for kind: MeetingRecordingKind) async -> Bool {
        await refreshRecordingSetup()
        return recordingSetupCheck(for: kind) == nil
    }

    private func observeDictation() {
        guard isStarted else { return }
        withObservationTracking {
            _ = dictation.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                switch self.dictation.state {
                case .listening, .locked, .transcribing:
                    if self.dictationStartedAt == nil {
                        self.dictationStartedAt = self.now()
                    }
                case .idle, .unavailable, .failed:
                    self.dictationStartedAt = nil
                }
                self.activityRevision &+= 1
                self.syncActivityClock()
                self.observeDictation()
            }
        }
    }

    private func syncActivityClock() {
        guard isStarted, activity.startedAt != nil else {
            activityClockTask?.cancel()
            activityClockTask = nil
            return
        }
        guard activityClockTask == nil else { return }
        activityClockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.isStarted, self.activity.startedAt != nil else {
                    return
                }
                self.activityRevision &+= 1
            }
        }
    }

    private func syncRecordingIsland() {
        if meeting.shouldPresentRecordingIsland {
            recordingIsland.updateMeeting(
                meeting.state,
                meeting: meeting.currentMeeting,
                levels: meeting.audioLevels,
                histories: meeting.audioHistories,
                signalStates: meeting.audioSignalStates,
                guidance: meeting.audioGuidance,
                microphone: meeting.microphonePresentation
            )
        } else {
            recordingIsland.hideImmediately()
        }
    }

    private func meetingDidTransition() {
        activityRevision &+= 1
        if meeting.isCapturingAudio {
            dictationStartedAt = nil
        }
        syncActivityClock()
        if meeting.state == .completed,
           let record = meeting.currentMeeting {
            let meetingID = record.id
            if meetingID != lastNotifiedMeetingID {
                lastNotifiedMeetingID = meetingID
                meetingDidSave()
            } else {
                meetings.load()
                if meetingSavedNotice?.meetingID == meetingID {
                    meetingSavedNotice = MeetingSavedNotice(
                        meetingID: meetingID,
                        title: record.title,
                        recordingKind: record.recordingKind
                    )
                }
                startAutomaticMeetingAnalysisIfReady(for: record)
            }
            return
        }
        syncRecordingIsland()
    }

    private func meetingDidSave() {
        guard let record = meeting.currentMeeting else { return }
        meetings.load()
        meetingSavedNotice = MeetingSavedNotice(
            meetingID: record.id,
            title: record.title,
            recordingKind: record.recordingKind
        )
        recordingIsland.meetingSaved(record)
        startAutomaticMeetingAnalysisIfReady(for: record)
    }

    private func startAutomaticMeetingAnalysisIfReady(for record: MeetingRecord) {
        guard record.transcriptionState == .completed,
              record.analysisState == .notRequested else { return }
        startAutomaticMeetingAnalysis(for: record.id)
    }

    private func startAutomaticMeetingAnalysis(for meetingID: UUID) {
        automaticMeetingAnalysisTask?.cancel()
        guard let stored = try? meetings.storedMeetingForPostProcessing(meetingID),
              let analysisController = meetingAnalysisFactory() else { return }
        let runningMeeting: MeetingRecord
        do {
            runningMeeting = try meetings.markAnalysisRunning(stored)
            meeting.replaceCompletedMeeting(runningMeeting)
        } catch {
            return
        }

        automaticMeetingAnalysisTask = Task { @MainActor [weak self] in
            let result: MeetingAnalysisRunResult
            if let processingAnalysis = analysisController as? MeetingAnalysisService,
               let self {
                let terminology = self.speechSettings.meetingTerminology
                result = await processingAnalysis.analyzeAfterFinalTranscription(
                    meeting: runningMeeting,
                    utterances: stored.utterances,
                    artifact: stored.rawTranscriptArtifacts,
                    speakerState: SpeakerEditingState(),
                    terminology: terminology.terms,
                    terminologyHash: terminology.contentHash
                )
            } else {
                result = await analysisController.analyzeAfterFinalTranscription(
                    meeting: runningMeeting,
                    utterances: stored.utterances,
                    speakerState: SpeakerEditingState()
                )
            }
            guard !Task.isCancelled, let self else { return }
            guard let merged = try? self.meetings.mergeAnalysisResult(result) else { return }
            self.meeting.replaceCompletedMeeting(merged)
            if self.meetingSavedNotice?.meetingID == merged.id {
                self.meetingSavedNotice = MeetingSavedNotice(
                    meetingID: merged.id,
                    title: merged.title,
                    recordingKind: merged.recordingKind
                )
            }
        }
    }

    private static func makeMeetingController(
        audioRetention: AudioRetentionController,
        ownership: MeetingAudioOwnership,
        microphoneSelections: MeetingMicrophoneSelectionStore,
        microphoneInventory: any MeetingMicrophoneInventoryProviding,
        modelAttester: (any VoxTypeModelAttesting)?
    ) -> (
        controller: MeetingController,
        transcription: MeetingTranscriptionCoordinator,
        notesStore: MeetingNotesStore
    ) {
        let store = MeetingStore()
        let notesStore = MeetingNotesStore(rootURL: store.rootURL)
        let audioMonitor = MeetingAudioMonitor()
        let uploader = MeetingUploadController(
            meetingStore: store,
            notesStore: notesStore
        )
        let transcription = MeetingTranscriptionCoordinator(
            store: store,
            retention: audioRetention,
            uploader: uploader
        )
        let recorder = BrainNativeMeetingRecorder(
            store: store,
            transcription: transcription,
            ownership: ownership,
            audioMonitor: audioMonitor,
            microphoneSelections: microphoneSelections,
            microphoneInventory: microphoneInventory,
            speechEngine: SpeechEngineID.whisper.rawValue,
            speechModel: OnboardingController.defaultMeetingModelID
        )
        let controller = MeetingController(
            detector: MeetingDetector(),
            recorder: recorder,
            speechEngine: SpeechEngineID.whisper.rawValue,
            speechModel: OnboardingController.defaultMeetingModelID,
            modelAttester: modelAttester,
            audioMonitor: audioMonitor
        )
        return (controller, transcription, notesStore)
    }

    private static func makeSpeechSettings(
        client: VoxTypeClient?,
        modelActivator: VoxTypeModelActivator?,
        modelSource: VoxTypeModelSourceOfTruth?,
        microphoneSelections: MeetingMicrophoneSelectionStore,
        microphoneService: any MeetingMicrophoneSettingsServing
    ) -> SpeechSettingsController {
        guard let client else {
            return SpeechSettingsController(
                voxType: nil,
                inventory: UnavailableSpeechModelInventory(),
                selections: SpeechSelectionStore(),
                microphoneService: microphoneService,
                microphoneSelectionStore: microphoneSelections
            )
        }
        return SpeechSettingsController(
            voxType: client,
            inventory: ModelInventory(client: client),
            selections: SpeechSelectionStore(),
            modelActivator: modelActivator,
            modelSource: modelSource,
            microphoneService: microphoneService,
            microphoneSelectionStore: microphoneSelections
        )
    }
}

@MainActor
private final class BrainAppActionRouter {
    weak var graph: BrainAppControllerGraph?

    func perform(_ action: RecordingIslandAction) {
        Task { [weak graph] in
            await graph?.performRecordingIslandAction(action)
        }
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) {
        Task { [weak graph] in
            await graph?.meeting.selectMicrophone(selection)
        }
    }

    func toggleMeeting() {
        Task { [weak graph] in
            await graph?.toggleMeeting()
        }
    }
}

private final class MeetingAudioOwnership: DictationAudioCaptureChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var ownsAudio = false

    var meetingOwnsAudioCapture: Bool {
        lock.withLock { ownsAudio }
    }

    func set(_ value: Bool) {
        lock.withLock { ownsAudio = value }
    }
}

private actor UnavailableSpeechModelInventory: SpeechModelInventoryControlling {
    func refresh() async -> ModelInventorySnapshot { .unknown }

    func install(
        modelID: String,
        progress: @Sendable (ModelInstallProgress) -> Void
    ) async throws -> ModelInventorySnapshot {
        throw ModelInventoryError.installFailed
    }
}

private struct UnavailableMeetingTranscriptionClient: LiveTranscriptionClient {
    func transcribe(wavURL: URL, engine: String) async throws -> String {
        throw VoxTypeClientError.launchFailed(command: .transcribe)
    }
}

/// Joins the already-tested native dual-source recorder to MeetingController.
/// Final text and a durable local recording are persisted together. This object
/// has no ingest dependency and can never send audio outside the meeting store.
private enum BrainNativeMeetingRecorderError: LocalizedError {
    case startupFailure(String)

    var errorDescription: String? {
        switch self {
        case .startupFailure(let message): message
        }
    }
}

private actor BrainMeetingAudioWritePipeline {
    private let writer: MeetingAudioWriter

    init(writer: MeetingAudioWriter) {
        self.writer = writer
    }

    func append(_ buffer: MeetingAudioSampleBuffer) throws -> MeetingAudioAppendResult {
        try writer.append(buffer)
    }

    func recordDiscontinuity(
        source: MeetingAudioSource,
        reason: MeetingAudioDiscontinuityReason,
        sourceTimestamp: TimeInterval? = nil,
        hostTimestamp: TimeInterval,
        detail: String? = nil
    ) throws {
        _ = try writer.recordDiscontinuity(
            source: source,
            reason: reason,
            sourceTimestamp: sourceTimestamp,
            hostTimestamp: hostTimestamp,
            detail: detail
        )
    }

    func recordFailure(
        source: MeetingAudioSource?,
        reason: MeetingAudioFailureReason,
        hostTimestamp: TimeInterval,
        message: String
    ) throws {
        _ = try writer.recordFailure(
            source: source,
            reason: reason,
            hostTimestamp: hostTimestamp,
            message: message
        )
    }

    func finalize() throws -> MeetingAudioCaptureSummary {
        try writer.finalize()
    }
}

@MainActor
private final class BrainNativeMeetingRecorder: MeetingRecording, MeetingMicrophoneSwitching {
    private let store: MeetingStore
    private let transcription: MeetingTranscriptionCoordinator
    private let ownership: MeetingAudioOwnership
    private let audioMonitor: MeetingAudioMonitor
    private let microphoneSelections: MeetingMicrophoneSelectionStore
    private let microphoneInventory: any MeetingMicrophoneInventoryProviding
    private let speechEngine: String
    private let speechModel: String

    private var request: MeetingRecordingRequest?
    private var writer: MeetingAudioWriter?
    private var writePipeline: BrainMeetingAudioWritePipeline?
    private var transcript: LiveTranscriptController?
    private var systemAudio: (any MeetingAudioSourceCapturing)?
    private var microphone: (any MeetingAudioSourceCapturing)?
    private var eventGate: BrainMeetingEventGate?
    private var runtimeFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private var postProcessingHandler: (@MainActor @Sendable (MeetingRecord) -> Void)?
    private var liveTranscriptControllerHandler:
        (@MainActor @Sendable (LiveTranscriptController?) -> Void)?
    private var meetingNotesFlushHandler: (@MainActor @Sendable () async -> Void)?
    private var microphonePresentationHandler: (@MainActor @Sendable () -> Void)?
    private var currentMicrophoneSelection: MeetingMicrophoneSelection?
    private var microphoneRefreshTask: Task<Void, Never>?
    private var microphoneSwitchTask: Task<Void, Never>?
    private var lastTranscriptCheckpoint: [MeetingUtterance] = []
    private var activeMicrophoneSwitchID: UUID?
    private var sessionGeneration: UInt64 = 0
    private var isSwitchingMicrophone = false
    private var sessionIsReady = false
    private(set) var microphonePresentation: RecordingIslandMicrophonePresentation?
    var liveTranscriptController: LiveTranscriptController? { transcript }

    init(
        store: MeetingStore,
        transcription: MeetingTranscriptionCoordinator,
        ownership: MeetingAudioOwnership,
        audioMonitor: MeetingAudioMonitor,
        microphoneSelections: MeetingMicrophoneSelectionStore,
        microphoneInventory: any MeetingMicrophoneInventoryProviding =
            CoreAudioMeetingMicrophoneInventory(),
        speechEngine: String,
        speechModel: String
    ) {
        self.store = store
        self.transcription = transcription
        self.ownership = ownership
        self.audioMonitor = audioMonitor
        self.microphoneSelections = microphoneSelections
        self.microphoneInventory = microphoneInventory
        self.speechEngine = speechEngine
        self.speechModel = speechModel
    }

    func setRuntimeFailureHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        runtimeFailureHandler = handler
    }

    func setPostProcessingHandler(
        _ handler: @escaping @MainActor @Sendable (MeetingRecord) -> Void
    ) {
        postProcessingHandler = handler
    }

    func setLiveTranscriptControllerHandler(
        _ handler: @escaping @MainActor @Sendable (LiveTranscriptController?) -> Void
    ) {
        liveTranscriptControllerHandler = handler
        handler(transcript)
    }

    func setMeetingNotesFlushHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    ) {
        meetingNotesFlushHandler = handler
    }

    func setMicrophonePresentationHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        microphonePresentationHandler = handler
    }

    func start(_ request: MeetingRecordingRequest) async throws {
        guard writer == nil else { return }
        sessionGeneration &+= 1
        let inventory = try microphoneInventory.snapshot()
        let microphoneSelection = microphoneSelections.selection
        let selectedMicrophone = activeMicrophone(
            for: microphoneSelection,
            inventory: inventory
        )
        do {
            _ = try inventory.deviceID(for: microphoneSelection)
        } catch {
            let startError = MeetingRecordingStartError.microphoneSelectionRequired(
                deviceName: selectedMicrophone?.name
            )
            updateMicrophonePresentation(
                inventory: inventory,
                selection: microphoneSelection,
                switchState: .failed(message: startError.localizedDescription)
            )
            audioMonitor.warn(MeetingAudioWarning(
                source: .microphone,
                message: startError.localizedDescription
            ))
            throw startError
        }

        let discoveredClient = try? VoxTypeClient.discover()
        let transcriptionClient: any LiveTranscriptionClient = if let discoveredClient {
            discoveredClient
        } else {
            UnavailableMeetingTranscriptionClient()
        }
        let engine = request.speechModelAttestation?.effectiveSelection.engine
            ?? SpeechEngineID(rawValue: speechEngine)
            ?? .whisper
        let transcript = LiveTranscriptController(service: try LiveTranscriptionService(
            client: transcriptionClient,
            engine: engine,
            attestedModel: request.speechModelAttestation?.effectiveSelection.modelID,
            originHostTimestamp: ProcessInfo.processInfo.systemUptime,
            wavDirectory: store.directoryURL(for: request.meetingID)
                .appendingPathComponent(".transcription", isDirectory: true)
        ))
        let writer = try MeetingAudioWriter(
            meetingDirectory: store.directoryURL(for: request.meetingID),
            origin: request.startedAt
        )
        try store.save(
            record(
                for: request,
                endedAt: nil,
                lifecycleState: .starting,
                transcriptionState: .pending,
                errorMessage: nil
            ),
            utterances: []
        )
        let systemAudio: (any MeetingAudioSourceCapturing)? = request.capturesSystemAudio
            ? ScreenCaptureKitMeetingAudioSource()
            : nil
        let microphone = AVAudioEngineMeetingAudioSource(
            selection: microphoneSelection,
            inventory: microphoneInventory
        )
        let microphoneReadiness = MeetingMicrophoneReadiness()
        let gate = BrainMeetingEventGate()
        self.request = request
        self.writer = writer
        writePipeline = BrainMeetingAudioWritePipeline(writer: writer)
        self.transcript = transcript
        liveTranscriptControllerHandler?(transcript)
        transcript.setUtteranceCheckpointHandler { [weak self] utterances in
            self?.scheduleTranscriptCheckpoint(utterances)
        }
        self.systemAudio = systemAudio
        self.microphone = microphone
        currentMicrophoneSelection = microphoneSelection
        updateMicrophonePresentation(
            inventory: inventory,
            selection: microphoneSelection,
            switchState: .ready
        )
        eventGate = gate

        let systemHandler = eventHandler(source: .system, gate: gate)
        let microphoneHandler = eventHandler(
            source: .microphone,
            gate: gate,
            readiness: microphoneReadiness
        )
        ownership.set(true)
        sessionIsReady = false
        do {
            if let systemAudio {
                try await systemAudio.start(eventHandler: systemHandler)
            }
            do {
                try await microphone.start(eventHandler: microphoneHandler)
            } catch {
                gate.stopAccepting()
                if let systemAudio { await systemAudio.stop() }
                await gate.waitUntilIdle()
                guard shouldRequestAnotherMicrophone(after: error) else { throw error }
                let startError = MeetingRecordingStartError.microphoneSelectionRequired(
                    deviceName: selectedMicrophone?.name
                )
                updateMicrophonePresentation(
                    inventory: inventory,
                    selection: microphoneSelection,
                    switchState: .failed(message: startError.localizedDescription)
                )
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: startError.localizedDescription
                ))
                throw startError
            }
            let readiness: MeetingMicrophoneReadinessResult
            do {
                readiness = try await microphoneReadiness.wait(timeout: .seconds(3))
            } catch {
                guard shouldRequestAnotherMicrophone(after: error) else { throw error }
                let startError = MeetingRecordingStartError.microphoneSelectionRequired(
                    deviceName: selectedMicrophone?.name
                )
                updateMicrophonePresentation(
                    inventory: inventory,
                    selection: microphoneSelection,
                    switchState: .failed(message: startError.localizedDescription)
                )
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: startError.localizedDescription
                ))
                throw startError
            }
            switch readiness {
            case .signalDetected:
                break
            case .flatSignal:
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: "No usable microphone signal was detected yet. Check the selected input and its input level; recording will continue while Brain listens for it."
                ))
            case .noFrames:
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: "No microphone audio has arrived yet. Check the selected input and microphone permission; recording will continue while Brain listens for it."
                ))
            }
            await gate.waitUntilIdle()
            if let startupFailureMessage = gate.startupFailureMessage {
                throw BrainNativeMeetingRecorderError.startupFailure(startupFailureMessage)
            }
            sessionIsReady = true
            try persistActiveRecord(lifecycleState: .recording)
            startMicrophoneInventoryRefresh()
        } catch {
            await meetingNotesFlushHandler?()
            gate.stopAccepting()
            let activeSwitch = beginSessionShutdown()
            await activeSwitch?.value
            await microphone.stop()
            if let systemAudio { await systemAudio.stop() }
            await gate.waitUntilIdle()
            await transcript.waitForPendingPreview()
            let utterances = transcript.utterances
            do {
                try flushTranscriptCheckpoint(utterances)
            } catch {
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: "The live transcript could not be saved: \(error.localizedDescription)"
                ))
            }
            await transcript.cancel()
            try? persistRetryableRecord(
                for: request,
                at: Date(),
                lifecycleState: .failed,
                message: "Meeting capture could not start: \(error.localizedDescription)",
                utterances: utterances
            )
            clearSession()
            ownership.set(false)
            throw error
        }
    }

    func pause(at date: Date) async throws {
        eventGate?.setPaused(true)
        try persistActiveRecord(lifecycleState: .paused)
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) async {
        guard microphoneSwitchTask == nil else { return }
        guard sessionIsReady,
              writer != nil,
              let gate = eventGate,
              let priorSelection = currentMicrophoneSelection,
              selection != priorSelection else {
            if writer == nil {
                guard let inventory = try? microphoneInventory.snapshot(),
                      (try? inventory.deviceID(for: selection)) != nil else { return }
                microphoneSelections.select(selection)
                updateMicrophonePresentation(
                    inventory: inventory,
                    selection: selection,
                    switchState: .ready
                )
            }
            return
        }

        let switchID = UUID()
        let generation = sessionGeneration
        activeMicrophoneSwitchID = switchID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performMicrophoneSwitch(
                to: selection,
                from: priorSelection,
                gate: gate,
                generation: generation,
                switchID: switchID
            )
        }
        microphoneSwitchTask = task
        await task.value
        if activeMicrophoneSwitchID == switchID {
            microphoneSwitchTask = nil
            activeMicrophoneSwitchID = nil
            isSwitchingMicrophone = false
        }
    }

    private func performMicrophoneSwitch(
        to selection: MeetingMicrophoneSelection,
        from priorSelection: MeetingMicrophoneSelection,
        gate: BrainMeetingEventGate,
        generation: UInt64,
        switchID: UUID
    ) async {
        guard isCurrentMicrophoneSwitch(
            generation: generation,
            switchID: switchID,
            gate: gate
        ) else { return }

        let inventory: MeetingMicrophoneInventorySnapshot
        do {
            inventory = try microphoneInventory.snapshot()
            _ = try inventory.deviceID(for: selection)
        } catch {
            updateMicrophonePresentation(
                inventory: (try? microphoneInventory.snapshot())
                    ?? MeetingMicrophoneInventorySnapshot(devices: [], defaultDeviceUID: nil),
                selection: priorSelection,
                switchState: .failed(message: "That microphone is no longer available.")
            )
            return
        }

        isSwitchingMicrophone = true
        updateMicrophonePresentation(
            inventory: inventory,
            selection: priorSelection,
            switchState: .switching(to: selection)
        )
        let priorDevice = activeMicrophone(
            for: priorSelection,
            inventory: inventory
        )
        let targetDevice = activeMicrophone(for: selection, inventory: inventory)
        let priorSource = microphone
        await priorSource?.stop()
        guard isCurrentMicrophoneSwitch(
            generation: generation,
            switchID: switchID,
            gate: gate
        ) else { return }
        await gate.waitUntilIdle()
        guard isCurrentMicrophoneSwitch(
            generation: generation,
            switchID: switchID,
            gate: gate
        ) else { return }

        let candidate = AVAudioEngineMeetingAudioSource(
            selection: selection,
            inventory: microphoneInventory
        )
        do {
            try await startMicrophone(candidate, gate: gate)
            guard isCurrentMicrophoneSwitch(
                generation: generation,
                switchID: switchID,
                gate: gate
            ) else {
                await candidate.stop()
                return
            }
            microphone = candidate
            currentMicrophoneSelection = selection
            microphoneSelections.select(selection)
            try? await writePipeline?.recordDiscontinuity(
                source: .microphone,
                reason: .deviceChanged,
                hostTimestamp: ProcessInfo.processInfo.systemUptime,
                detail: "Microphone changed from \(priorDevice?.name ?? "unknown") to \(targetDevice?.name ?? "unknown")."
            )
            isSwitchingMicrophone = false
            sessionIsReady = true
            updateMicrophonePresentation(
                inventory: inventory,
                selection: selection,
                switchState: .ready
            )
        } catch {
            await candidate.stop()
            guard isCurrentMicrophoneSwitch(
                generation: generation,
                switchID: switchID,
                gate: gate
            ) else { return }
            let rollback = AVAudioEngineMeetingAudioSource(
                selection: priorSelection,
                inventory: microphoneInventory
            )
            do {
                try await startMicrophone(rollback, gate: gate)
                guard isCurrentMicrophoneSwitch(
                    generation: generation,
                    switchID: switchID,
                    gate: gate
                ) else {
                    await rollback.stop()
                    return
                }
                microphone = rollback
                isSwitchingMicrophone = false
                sessionIsReady = true
                updateMicrophonePresentation(
                    inventory: inventory,
                    selection: priorSelection,
                    switchState: .failed(
                        message: "Could not switch to \(targetDevice?.name ?? "that microphone"). The previous microphone is still active."
                    )
                )
            } catch {
                await rollback.stop()
                guard isCurrentMicrophoneSwitch(
                    generation: generation,
                    switchID: switchID,
                    gate: gate
                ) else { return }
                isSwitchingMicrophone = false
                sessionIsReady = true
                updateMicrophonePresentation(
                    inventory: inventory,
                    selection: priorSelection,
                    switchState: .failed(
                        message: "Both the selected and previous microphones became unavailable."
                    )
                )
                scheduleRuntimeFailure(
                    "Brain could not restore microphone capture after changing devices."
                )
            }
        }
    }

    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {
        eventGate?.setPaused(false)
        try persistActiveRecord(lifecycleState: .recording)
    }

    func stop(at date: Date) async throws -> MeetingRecord? {
        guard let writePipeline, let request, let transcript else { return nil }
        await meetingNotesFlushHandler?()
        defer {
            clearSession()
            ownership.set(false)
        }
        eventGate?.stopAccepting()
        let activeSwitch = beginSessionShutdown()
        await activeSwitch?.value
        await microphone?.stop()
        await systemAudio?.stop()
        await eventGate?.waitUntilIdle()
        await transcript.waitForPendingPreview()
        let previewUtterances = transcript.utterances
        do {
            try flushTranscriptCheckpoint(previewUtterances)
        } catch {
            try? persistRetryableRecord(
                for: request,
                at: date,
                lifecycleState: .failed,
                message: "The transcript checkpoint could not be saved: \(error.localizedDescription)",
                utterances: previewUtterances
            )
            throw error
        }
        let summary: MeetingAudioCaptureSummary
        do {
            summary = try await writePipeline.finalize()
        } catch {
            try? persistRetryableRecord(
                for: request,
                at: date,
                lifecycleState: .failed,
                message: "Brain could not finalize this recording: \(error.localizedDescription)",
                utterances: previewUtterances
            )
            throw error
        }
        let completed = MeetingRecord(
            id: request.meetingID,
            title: request.title,
            recordingKind: request.recordingKind,
            titleSource: request.titleSource,
            detectedApplication: request.application?.displayName,
            startedAt: request.startedAt,
            endedAt: date,
            lifecycleState: .completed,
            speechEngine: request.speechModelAttestation?.effectiveSelection.engine.rawValue
                ?? speechEngine,
            speechModel: request.speechModelAttestation?.effectiveSelection.modelID ?? speechModel,
            speechModelAttestation: request.speechModelAttestation
        )
        let processing: MeetingRecord
        do {
            processing = try transcription.stage(
                meeting: completed,
                capture: summary,
                utterances: previewUtterances
            )
        } catch {
            try? persistRetryableRecord(
                for: request,
                at: date,
                lifecycleState: .completed,
                message: "The recording was saved, but transcription could not start: \(error.localizedDescription)",
                utterances: previewUtterances
            )
            throw error
        }
        let completion = postProcessingHandler
        Task { [transcription, store] in
            let result = await transcription.complete(
                meeting: processing,
                capture: summary,
                transcript: transcript
            )
            guard (try? store.load(result.id)) != nil else { return }
            completion?(result)
        }
        return processing
    }

    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {
        await meetingNotesFlushHandler?()
        eventGate?.stopAccepting()
        let activeSwitch = beginSessionShutdown()
        await activeSwitch?.value
        await microphone?.stop()
        await systemAudio?.stop()
        await eventGate?.waitUntilIdle()
        await transcript?.waitForPendingPreview()
        let utterances = transcript?.utterances ?? []
        var recoveryMessage = "Recording reached Brain's eight-hour safety limit. Retry the saved transcript when ready."
        do {
            try flushTranscriptCheckpoint(utterances)
        } catch {
            recoveryMessage += " The live transcript checkpoint failed: \(error.localizedDescription)"
            audioMonitor.warn(MeetingAudioWarning(source: .microphone, message: recoveryMessage))
        }
        await transcript?.cancel()
        if let request {
            _ = await finalizeAsRetryable(
                request: request,
                at: date,
                message: recoveryMessage,
                utterances: utterances
            )
        }
        clearSession()
        ownership.set(false)
    }

    private func startMicrophone(
        _ source: any MeetingAudioSourceCapturing,
        gate: BrainMeetingEventGate
    ) async throws {
        let readiness = MeetingMicrophoneReadiness()
        try await source.start(eventHandler: eventHandler(
            source: .microphone,
            gate: gate,
            readiness: readiness
        ))
        let result = try await readiness.wait(timeout: .seconds(3))
        switch result {
        case .signalDetected:
            break
        case .flatSignal:
            audioMonitor.warn(MeetingAudioWarning(
                source: .microphone,
                message: "The selected microphone is connected but no voice signal has been detected yet."
            ))
        case .noFrames:
            throw MeetingAudioCaptureError.microphoneNotReady
        }
    }

    private func activeMicrophone(
        for selection: MeetingMicrophoneSelection,
        inventory: MeetingMicrophoneInventorySnapshot
    ) -> MeetingMicrophoneDevice? {
        switch selection {
        case .systemDefault:
            guard let uid = inventory.defaultDeviceUID else { return nil }
            return inventory.devices.first { $0.id == uid }
        case .device(let uid):
            return inventory.devices.first { $0.id == uid }
        }
    }

    private func shouldRequestAnotherMicrophone(after error: Error) -> Bool {
        if let native = error as? NativeMeetingAudioSourceError {
            return native != .permissionDenied && native != .microphonePermissionDenied
        }
        if case .sourceStartFailed(.microphone, let reason) = error as? MeetingAudioCaptureError {
            return reason != .permissionDenied && reason != .permissionRevoked
        }
        return true
    }

    private func updateMicrophonePresentation(
        inventory: MeetingMicrophoneInventorySnapshot,
        selection: MeetingMicrophoneSelection,
        switchState: RecordingIslandMicrophoneSwitchState
    ) {
        microphonePresentation = RecordingIslandMicrophonePresentation(
            activeDevice: activeMicrophone(for: selection, inventory: inventory),
            availableDevices: inventory.devices,
            selectedPreference: selection,
            switchState: switchState
        )
        microphonePresentationHandler?()
    }

    private func startMicrophoneInventoryRefresh() {
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled,
                      let self,
                      self.writer != nil,
                      !self.isSwitchingMicrophone,
                      let selection = self.currentMicrophoneSelection,
                      let inventory = try? self.microphoneInventory.snapshot() else { continue }

                if case .device(let uid) = selection,
                   !inventory.devices.contains(where: { $0.id == uid }),
                   inventory.defaultDeviceUID != nil {
                    self.audioMonitor.warn(MeetingAudioWarning(
                        source: .microphone,
                        message: "The selected microphone disconnected. Brain is switching to the system default."
                    ))
                    await self.selectMicrophone(.systemDefault)
                } else {
                    self.updateMicrophonePresentation(
                        inventory: inventory,
                        selection: selection,
                        switchState: self.microphonePresentation?.switchState ?? .ready
                    )
                }
            }
        }
    }

    private func eventHandler(
        source: MeetingAudioSource,
        gate: BrainMeetingEventGate,
        readiness: MeetingMicrophoneReadiness? = nil
    ) -> @Sendable (MeetingAudioSourceEvent) -> Void {
        { [weak self, gate] event in
            if case .failure(let failure) = event {
                gate.recordStartupFailure(failure.message)
            }
            if source == .microphone {
                switch event {
                case .samples(let buffer): readiness?.receive(buffer)
                case .failure(let failure):
                    readiness?.fail(reason: failure.reason, message: failure.message)
                case .discontinuity: break
                }
            }
            switch gate.beginEvent() {
            case .accepted:
                break
            case .ignored:
                return
            case .overloaded:
                let message = "Meeting audio processing fell behind and was stopped before memory could grow without bound."
                gate.recordStartupFailure(message)
                Task { @MainActor [weak self] in
                    self?.scheduleRuntimeFailure(message)
                }
                return
            }
            Task { @MainActor [weak self, gate] in
                defer { gate.endEvent() }
                await self?.receive(event, source: source)
            }
        }
    }

    private func receive(
        _ event: MeetingAudioSourceEvent,
        source: MeetingAudioSource
    ) async {
        guard let writePipeline else { return }
        switch event {
        case .samples(let buffer):
            guard buffer.source == source else {
                try? await writePipeline.recordFailure(
                    source: source,
                    reason: .sourceFailed,
                    hostTimestamp: buffer.hostTimestamp,
                    message: "The source emitted audio with the wrong source identifier."
                )
                return
            }
            do {
                let result = try await writePipeline.append(buffer)
                if let level = result.level { audioMonitor.receive(level) }
                await transcript?.append(buffer)
            } catch {
                eventGate?.recordStartupFailure(
                    "Meeting audio could not be written: \(error.localizedDescription)"
                )
                try? await writePipeline.recordFailure(
                    source: source,
                    reason: .writerFailed,
                    hostTimestamp: buffer.hostTimestamp,
                    message: error.localizedDescription
                )
                scheduleRuntimeFailure("Meeting audio could not be written: \(error.localizedDescription)")
                audioMonitor.warn(MeetingAudioWarning(
                    source: source,
                    message: "Meeting audio could not be written. Recording was stopped safely."
                ))
            }

        case .discontinuity(let value):
            try? await writePipeline.recordDiscontinuity(
                source: source,
                reason: value.reason,
                sourceTimestamp: value.sourceTimestamp,
                hostTimestamp: value.hostTimestamp,
                detail: value.detail
            )
            if value.reason == .streamInterrupted {
                audioMonitor.warn(MeetingAudioWarning(
                    source: source,
                    message: value.detail
                        ?? "Audio callbacks were interrupted. Brain is rebuilding the stream."
                ))
            }

        case .failure(let value):
            if source == .microphone, isSwitchingMicrophone {
                return
            }
            if source == .microphone,
               case .device = currentMicrophoneSelection,
               value.reason == .sourceUnavailable {
                audioMonitor.warn(MeetingAudioWarning(
                    source: .microphone,
                    message: "The selected microphone disconnected. Brain is switching to the system default."
                ))
                Task { @MainActor [weak self] in
                    await self?.selectMicrophone(.systemDefault)
                }
                return
            }
            try? await writePipeline.recordDiscontinuity(
                source: source,
                reason: value.reason == .permissionRevoked ? .permissionRevoked : .sourceFailure,
                hostTimestamp: value.hostTimestamp,
                detail: value.message
            )
            try? await writePipeline.recordFailure(
                source: source,
                reason: value.reason,
                hostTimestamp: value.hostTimestamp,
                message: value.message
            )
            scheduleRuntimeFailure(value.message)
            audioMonitor.warn(MeetingAudioWarning(
                source: source,
                message: "\(value.message) Recording was stopped; fix the audio source before trying again."
            ))
        }
    }

    private func scheduleRuntimeFailure(_ message: String) {
        guard sessionIsReady else { return }
        sessionIsReady = false
        Task { @MainActor [weak self] in
            await self?.stopForRuntimeFailure(message)
        }
    }

    private func stopForRuntimeFailure(_ message: String) async {
        guard writer != nil, let request else { return }
        await meetingNotesFlushHandler?()
        eventGate?.stopAccepting()
        let activeSwitch = beginSessionShutdown()
        await activeSwitch?.value
        await microphone?.stop()
        await systemAudio?.stop()
        await eventGate?.waitUntilIdle()
        await transcript?.waitForPendingPreview()
        let utterances = transcript?.utterances ?? []
        var failureMessage = "Recording stopped after an audio failure: \(message)"
        do {
            try flushTranscriptCheckpoint(utterances)
        } catch {
            failureMessage += " The live transcript checkpoint failed: \(error.localizedDescription)"
            audioMonitor.warn(MeetingAudioWarning(source: .microphone, message: failureMessage))
        }
        await transcript?.cancel()
        _ = await finalizeAsRetryable(
            request: request,
            at: Date(),
            message: failureMessage,
            utterances: utterances
        )
        clearSession()
        ownership.set(false)
        runtimeFailureHandler?(message)
    }

    private func persistActiveRecord(lifecycleState: MeetingLifecycleState) throws {
        guard let request else { return }
        let existing = try? store.load(request.meetingID)
        try store.save(
            record(
                for: request,
                endedAt: nil,
                lifecycleState: lifecycleState,
                transcriptionState: .pending,
                errorMessage: nil
            ),
            utterances: existing?.utterances ?? []
        )
    }

    @discardableResult
    private func finalizeAsRetryable(
        request: MeetingRecordingRequest,
        at date: Date,
        message: String,
        utterances: [MeetingUtterance]
    ) async -> MeetingRecord {
        let finalizationError: String?
        do {
            guard let writePipeline else {
                throw MeetingAudioWriterError.fileWriteFailed
            }
            _ = try await writePipeline.finalize()
            finalizationError = nil
        } catch {
            finalizationError = error.localizedDescription
        }
        let combinedMessage = [message, finalizationError]
            .compactMap { $0 }
            .joined(separator: " ")
        let lifecycleState: MeetingLifecycleState = finalizationError == nil ? .completed : .failed
        let failed = record(
            for: request,
            endedAt: date,
            lifecycleState: lifecycleState,
            transcriptionState: .failed,
            errorMessage: combinedMessage
        )
        try? store.save(failed, utterances: utterances)
        return failed
    }

    private func persistRetryableRecord(
        for request: MeetingRecordingRequest,
        at date: Date,
        lifecycleState: MeetingLifecycleState,
        message: String,
        utterances: [MeetingUtterance]
    ) throws {
        try store.save(
            record(
                for: request,
                endedAt: date,
                lifecycleState: lifecycleState,
                transcriptionState: .failed,
                errorMessage: message
            ),
            utterances: utterances
        )
    }

    private func scheduleTranscriptCheckpoint(_ utterances: [MeetingUtterance]) {
        do {
            try persistTranscriptCheckpoint(utterances)
        } catch {
            let message = "The live transcript could not be saved. Recording was stopped safely: \(error.localizedDescription)"
            eventGate?.recordStartupFailure(message)
            audioMonitor.warn(MeetingAudioWarning(source: .microphone, message: message))
            scheduleRuntimeFailure(message)
        }
    }

    private func flushTranscriptCheckpoint(_ utterances: [MeetingUtterance]) throws {
        try persistTranscriptCheckpoint(utterances)
    }

    private func persistTranscriptCheckpoint(_ utterances: [MeetingUtterance]) throws {
        guard let request, utterances != lastTranscriptCheckpoint else { return }
        let stored = try store.load(request.meetingID)
        guard stored.meeting.audioRetentionState != .deleted,
              [
                  MeetingLifecycleState.starting,
                  .recording,
                  .paused,
                  .stopSuggested,
                  .finalizing,
              ].contains(stored.meeting.lifecycleState) else { return }
        try store.save(stored.meeting, utterances: utterances)
        lastTranscriptCheckpoint = utterances
    }

    private func record(
        for request: MeetingRecordingRequest,
        endedAt: Date?,
        lifecycleState: MeetingLifecycleState,
        transcriptionState: MeetingTranscriptionState,
        errorMessage: String?
    ) -> MeetingRecord {
        MeetingRecord(
            id: request.meetingID,
            title: request.title,
            recordingKind: request.recordingKind,
            titleSource: request.titleSource,
            detectedApplication: request.application?.displayName,
            startedAt: request.startedAt,
            endedAt: endedAt,
            lifecycleState: lifecycleState,
            speechEngine: request.speechModelAttestation?.effectiveSelection.engine.rawValue
                ?? speechEngine,
            speechModel: request.speechModelAttestation?.effectiveSelection.modelID ?? speechModel,
            speechModelAttestation: request.speechModelAttestation,
            transcriptionState: transcriptionState,
            transcriptionErrorMessage: errorMessage
        )
    }

    private func isCurrentMicrophoneSwitch(
        generation: UInt64,
        switchID: UUID,
        gate: BrainMeetingEventGate
    ) -> Bool {
        !Task.isCancelled
            && sessionGeneration == generation
            && activeMicrophoneSwitchID == switchID
            && writer != nil
            && eventGate === gate
    }

    private func beginSessionShutdown() -> Task<Void, Never>? {
        sessionGeneration &+= 1
        sessionIsReady = false
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = nil
        activeMicrophoneSwitchID = nil
        microphoneSwitchTask?.cancel()
        return microphoneSwitchTask
    }

    private func clearSession() {
        lastTranscriptCheckpoint = []
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = nil
        microphoneSwitchTask?.cancel()
        microphoneSwitchTask = nil
        activeMicrophoneSwitchID = nil
        request = nil
        writer = nil
        writePipeline = nil
        transcript = nil
        liveTranscriptControllerHandler?(nil)
        systemAudio = nil
        microphone = nil
        eventGate = nil
        currentMicrophoneSelection = nil
        isSwitchingMicrophone = false
        sessionIsReady = false
    }
}

/// Bounds source callbacks during pause/stop and gives finalization one exact
/// point at which every admitted buffer has reached the writer/transcriber.
private final class BrainMeetingEventGate: @unchecked Sendable {
    enum Admission {
        case accepted
        case ignored
        case overloaded
    }

    private static let maximumPendingEvents = 512
    private let lock = NSLock()
    private var accepting = true
    private var paused = false
    private var pendingEvents = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedStartupFailure: String?

    var startupFailureMessage: String? {
        lock.withLock { recordedStartupFailure }
    }

    func recordStartupFailure(_ message: String) {
        lock.withLock {
            if recordedStartupFailure == nil { recordedStartupFailure = message }
        }
    }

    func beginEvent() -> Admission {
        lock.withLock {
            guard accepting, !paused else { return .ignored }
            guard pendingEvents < Self.maximumPendingEvents else {
                accepting = false
                return .overloaded
            }
            pendingEvents += 1
            return .accepted
        }
    }

    func endEvent() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pendingEvents = max(0, pendingEvents - 1)
            guard pendingEvents == 0 else { return [] }
            defer { idleWaiters.removeAll() }
            return idleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard pendingEvents > 0 else { return true }
                idleWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

@main
struct BrainMenuApp: App {
    static let dashboardWindowID = "brain-dashboard"

    @NSApplicationDelegateAdaptor(BrainApplicationDelegate.self)
    private var applicationDelegate
    @State private var graph = BrainAppControllerGraph()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(graph: graph)
        } label: {
            BrainMenuBarLabel(graph: graph)
        }
        .menuBarExtraStyle(.window)

        Window("Brain", id: Self.dashboardWindowID) {
            BrainRootView(graph: graph)
                .task { graph.start() }
        }
        .defaultSize(
            width: BrainWindowSizeGuard.preferredSize.width,
            height: BrainWindowSizeGuard.preferredSize.height
        )
    }
}

private struct BrainMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @State private var didPresentInitialWindow = false

    let graph: BrainAppControllerGraph

    var body: some View {
        let presentation = BrainMenuBarPresentation(
            activity: graph.activity,
            now: Date()
        )
        HStack(spacing: 4) {
            Image(systemName: presentation.symbolName)
            if let elapsed = presentation.elapsedText {
                Text(elapsed)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
            .task {
                graph.start()
                guard !didPresentInitialWindow else { return }
                didPresentInitialWindow = true
                presentDashboard()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .brainOpenDashboardWindow)
            ) { _ in
                presentDashboard()
            }
    }

    private func presentDashboard() {
        openWindow(id: BrainMenuApp.dashboardWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct BrainRootView: View {
    let graph: BrainAppControllerGraph

    var body: some View {
        Group {
            switch graph.launchDestination {
            case .setup:
                BrainSetupView(store: graph.store)
            case .dashboard:
                DashboardView(store: graph.store, graph: graph)
                    .id(graph.store.runtimeIdentity)
            }
        }
        .background(BrainWindowSizeGuard())
    }
}
