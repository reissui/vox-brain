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

    var id: UUID { meetingID }
    var message: String { "Added to Meetings. It is now at the top of the list." }
}

extension MeetingController {
    var isCapturingAudio: Bool {
        switch state {
        case .starting, .recording, .paused, .stopSuggested, .finalizing:
            true
        case .idle, .startSuggested, .completed, .failed:
            false
        }
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
    let regionCapture: RegionCaptureController
    let dictationHistory: DictationHistoryStore
    let dictation: DictationController
    let meeting: MeetingController
    let meetingHotkey: MeetingHotkeyController
    let recordingIsland: RecordingIslandController
    let meetings: MeetingsController
    let launchAtLogin: LaunchAtLoginController
    let gmail: GmailConnectionController
    let speechSettings: SpeechSettingsController
    let aiSettings: AISettingsController
    let updates: UpdateController
    let audioRetention: AudioRetentionController

    private(set) var startCount = 0
    private(set) var activityRevision: UInt64 = 0
    private(set) var meetingSavedNotice: MeetingSavedNotice?

    @ObservationIgnored private let meetingAudioOwnership: MeetingAudioOwnership
    @ObservationIgnored private let actionRouter: BrainAppActionRouter
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var automaticMeetingAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private let meetingAnalysisFactory: @MainActor () -> (any MeetingDetailAnalysisControlling)?
    @ObservationIgnored private var lastNotifiedMeetingID: UUID?
    @ObservationIgnored private var dictationStartedAt: Date?
    @ObservationIgnored private var activityClockTask: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> Date

    var launchDestination: BrainAppLaunchDestination {
        store.deploymentMode == nil && !store.isReady ? .setup : .dashboard
    }

    var activity: BrainAppActivity {
        _ = activityRevision
        switch meeting.state {
        case .finalizing:
            return .transcribing("Finalizing meeting")
        case .starting, .recording, .paused, .stopSuggested:
            if let startedAt = meeting.currentMeeting?.startedAt {
                return .meeting(
                    label: meeting.state == .paused ? "Meeting paused" : "Recording meeting",
                    startedAt: startedAt
                )
            }
        case .idle, .startSuggested, .completed, .failed:
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
        dictationHistory: DictationHistoryStore = DictationHistoryStore(),
        dictation: DictationController? = nil,
        recordingIsland: RecordingIslandController? = nil,
        meetings: MeetingsController = MeetingsController(),
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        gmail: GmailConnectionController = GmailConnectionController(),
        captureHotkeyRegistrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(),
        regionHotkeyRegistrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(identifier: 3),
        designRegionCapture: (any DesignRegionCapturing)? = nil,
        frontmostApplications: any FrontmostApplicationProviding = WorkspaceFrontmostApplicationProvider(),
        speechSettings: SpeechSettingsController? = nil,
        aiSettings: AISettingsController = AISettingsController(settings: AISettingsStore()),
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
        self.gmail = gmail
        self.aiSettings = aiSettings
        self.updates = updates
        self.audioRetention = audioRetention
        self.now = now
        self.meetingAnalysisFactory = meetingAnalysisFactory
        self.dictationHistory = dictationHistory
        let router = BrainAppActionRouter()
        actionRouter = router

        let ownership = MeetingAudioOwnership()
        meetingAudioOwnership = ownership
        self.dictation = dictation ?? DictationController(audioCapture: ownership)
        let microphoneSelections = MeetingMicrophoneSelectionStore()
        let microphoneInventory = CoreAudioMeetingMicrophoneInventory()
        let nativeMeeting: MeetingController
        if let meeting {
            nativeMeeting = meeting
        } else {
            nativeMeeting = Self.makeMeetingController(
                audioRetention: audioRetention,
                ownership: ownership,
                microphoneSelections: microphoneSelections,
                microphoneInventory: microphoneInventory
            )
        }
        self.meeting = nativeMeeting
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
        regionCapture = RegionCaptureController(
            captureController: capture,
            regionCapture: designRegionCapture ?? DesignRegionCapture(),
            registrar: regionHotkeyRegistrar
        )

        let island = recordingIsland ?? RecordingIslandController(actionHandler: { action in
            router.perform(action)
        }, microphoneSelectionHandler: { selection in
            router.selectMicrophone(selection)
        })
        self.recordingIsland = island

        self.speechSettings = speechSettings ?? Self.makeSpeechSettings(
            microphoneSelections: microphoneSelections,
            microphoneService: SystemMeetingMicrophoneService(
                inventoryProvider: microphoneInventory
            )
        )
        router.graph = self
        nativeMeeting.setTransitionHandler { [weak self] in
            self?.meetingDidTransition()
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startCount += 1
        store.start()
        _ = meetingHotkey.start()
        updates.start()
        dictationHistory.startMonitoring()
        observeDictation()
        dictation.startMonitoring()
        observeMeetingAudio()
        syncActivityClock()
        Task {
            await onboarding.refresh()
            await speechSettings.refresh()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        store.stop()
        meetingHotkey.stop()
        dictationHistory.stopMonitoring()
        dictation.stopMonitoring()
        activityClockTask?.cancel()
        activityClockTask = nil
        automaticMeetingAnalysisTask?.cancel()
        automaticMeetingAnalysisTask = nil
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
            meetingSavedNotice = nil
            if meeting.state == .completed { meeting.resetCompletedMeeting() }
            await meeting.startRecording(application: nil)
        case .finalizing:
            return
        }
    }

    func dismissMeetingSavedNotice() {
        meetingSavedNotice = nil
    }

    fileprivate func performRecordingIslandAction(_ action: RecordingIslandAction) async {
        switch action {
        case .cancel:
            return
        case .pause:
            await meeting.pause()
        case .resume:
            await meeting.resume()
        case .stop:
            await meeting.stop()
        case .keepRecording:
            meeting.keepRecording()
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
        if meeting.isCapturingAudio {
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
                        title: record.title
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
            title: record.title
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
            let result = await analysisController.analyzeAfterFinalTranscription(
                meeting: runningMeeting,
                utterances: stored.utterances,
                speakerState: SpeakerEditingState()
            )
            guard !Task.isCancelled, let self else { return }
            guard let merged = try? self.meetings.mergeAnalysisResult(result) else { return }
            self.meeting.replaceCompletedMeeting(merged)
            if self.meetingSavedNotice?.meetingID == merged.id {
                self.meetingSavedNotice = MeetingSavedNotice(
                    meetingID: merged.id,
                    title: merged.title
                )
            }
        }
    }

    private static func makeMeetingController(
        audioRetention: AudioRetentionController,
        ownership: MeetingAudioOwnership,
        microphoneSelections: MeetingMicrophoneSelectionStore,
        microphoneInventory: any MeetingMicrophoneInventoryProviding
    ) -> MeetingController {
        let store = MeetingStore()
        let audioMonitor = MeetingAudioMonitor()
        let uploader = MeetingUploadController(meetingStore: store)
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
            speechEngine: SpeechEngineID.parakeet.rawValue,
            speechModel: OnboardingController.defaultMeetingModelID
        )
        return MeetingController(
            detector: MeetingDetector(),
            recorder: recorder,
            speechEngine: SpeechEngineID.parakeet.rawValue,
            speechModel: OnboardingController.defaultMeetingModelID,
            audioMonitor: audioMonitor
        )
    }

    private static func makeSpeechSettings(
        microphoneSelections: MeetingMicrophoneSelectionStore,
        microphoneService: any MeetingMicrophoneSettingsServing
    ) -> SpeechSettingsController {
        guard let client = try? VoxTypeClient.discover() else {
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
            modelActivator: VoxTypeModelActivator(
                configuration: VoxTypeConfigurationEditor(),
                statuses: client
            ),
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
/// Final text is persisted before the optional local-audio retention policy is
/// applied. This object has no remote API and can never upload audio.
private enum BrainNativeMeetingRecorderError: LocalizedError {
    case startupFailure(String)

    var errorDescription: String? {
        switch self {
        case .startupFailure(let message): message
        }
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
    private var transcript: LiveTranscriptController?
    private var systemAudio: (any MeetingAudioSourceCapturing)?
    private var microphone: (any MeetingAudioSourceCapturing)?
    private var eventGate: BrainMeetingEventGate?
    private var runtimeFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private var postProcessingHandler: (@MainActor @Sendable (MeetingRecord) -> Void)?
    private var microphonePresentationHandler: (@MainActor @Sendable () -> Void)?
    private var currentMicrophoneSelection: MeetingMicrophoneSelection?
    private var microphoneRefreshTask: Task<Void, Never>?
    private var microphoneSwitchTask: Task<Void, Never>?
    private var activeMicrophoneSwitchID: UUID?
    private var sessionGeneration: UInt64 = 0
    private var isSwitchingMicrophone = false
    private var sessionIsReady = false
    private(set) var microphonePresentation: RecordingIslandMicrophonePresentation?

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

    func setMicrophonePresentationHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        microphonePresentationHandler = handler
    }

    func start(_ request: MeetingRecordingRequest) async throws {
        guard writer == nil else { return }
        sessionGeneration &+= 1
        let discoveredClient = try? VoxTypeClient.discover()
        let transcriptionClient: any LiveTranscriptionClient = if let discoveredClient {
            FallbackLiveTranscriptionClient(client: discoveredClient)
        } else {
            UnavailableMeetingTranscriptionClient()
        }
        let engine = SpeechEngineID(rawValue: speechEngine) ?? .parakeet
        let transcript = LiveTranscriptController(service: try LiveTranscriptionService(
            client: transcriptionClient,
            engine: engine,
            originHostTimestamp: ProcessInfo.processInfo.systemUptime,
            wavDirectory: store.directoryURL(for: request.meetingID)
                .appendingPathComponent(".transcription", isDirectory: true)
        ))
        let writer = try MeetingAudioWriter(
            meetingDirectory: store.directoryURL(for: request.meetingID),
            origin: request.startedAt
        )
        let systemAudio = ScreenCaptureKitMeetingAudioSource()
        let inventory = try microphoneInventory.snapshot()
        let microphoneSelection = resolvedMicrophoneSelection(
            microphoneSelections.selection,
            inventory: inventory
        )
        if microphoneSelection != microphoneSelections.selection {
            microphoneSelections.select(microphoneSelection)
            audioMonitor.warn(MeetingAudioWarning(
                source: .microphone,
                message: "The previously selected microphone is unavailable. Brain is using the system default microphone."
            ))
        }
        let microphone = AVAudioEngineMeetingAudioSource(
            selection: microphoneSelection,
            inventory: microphoneInventory
        )
        let microphoneReadiness = MeetingMicrophoneReadiness()
        let gate = BrainMeetingEventGate()
        self.request = request
        self.writer = writer
        self.transcript = transcript
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
            try await systemAudio.start(eventHandler: systemHandler)
            do {
                try await microphone.start(eventHandler: microphoneHandler)
            } catch {
                gate.stopAccepting()
                await systemAudio.stop()
                await gate.waitUntilIdle()
                throw error
            }
            let readiness = try await microphoneReadiness.wait(timeout: .seconds(3))
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
            startMicrophoneInventoryRefresh()
        } catch {
            gate.stopAccepting()
            let activeSwitch = beginSessionShutdown()
            await activeSwitch?.value
            await microphone.stop()
            await systemAudio.stop()
            await gate.waitUntilIdle()
            await transcript.cancel()
            clearSession()
            ownership.set(false)
            throw error
        }
    }

    func pause(at date: Date) async throws {
        eventGate?.setPaused(true)
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) async {
        guard microphoneSwitchTask == nil else { return }
        guard sessionIsReady,
              writer != nil,
              let gate = eventGate,
              let priorSelection = currentMicrophoneSelection,
              selection != priorSelection else {
            if writer == nil {
                microphoneSelections.select(selection)
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
            _ = try? writer?.recordDiscontinuity(
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
    }

    func stop(at date: Date) async throws -> MeetingRecord? {
        guard let writer, let request, let transcript else { return nil }
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
        let summary = try writer.finalize()
        let completed = MeetingRecord(
            id: request.meetingID,
            title: request.application.map { "Meeting in \($0.displayName)" } ?? "Meeting",
            titleSource: .application,
            detectedApplication: request.application?.displayName,
            startedAt: request.startedAt,
            endedAt: date,
            lifecycleState: .completed,
            speechEngine: speechEngine,
            speechModel: speechModel
        )
        let processing = try transcription.stage(meeting: completed, capture: summary)
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
        eventGate?.stopAccepting()
        let activeSwitch = beginSessionShutdown()
        await activeSwitch?.value
        await microphone?.stop()
        await systemAudio?.stop()
        await eventGate?.waitUntilIdle()
        await transcript?.cancel()
        // Releasing the writer closes its private tracks without creating the
        // normal final manifest or deleting partial recovery data.
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

    private func resolvedMicrophoneSelection(
        _ selection: MeetingMicrophoneSelection,
        inventory: MeetingMicrophoneInventorySnapshot
    ) -> MeetingMicrophoneSelection {
        switch selection {
        case .systemDefault:
            return .systemDefault
        case .device(let uid):
            return inventory.devices.contains(where: { $0.id == uid })
                ? selection
                : .systemDefault
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
            guard gate.beginEvent() else { return }
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
        guard let writer else { return }
        switch event {
        case .samples(let buffer):
            guard buffer.source == source else {
                _ = try? writer.recordFailure(
                    source: source,
                    reason: .sourceFailed,
                    hostTimestamp: buffer.hostTimestamp,
                    message: "The source emitted audio with the wrong source identifier."
                )
                return
            }
            do {
                let result = try writer.append(buffer)
                if let level = result.level { audioMonitor.receive(level) }
                await transcript?.append(buffer)
            } catch {
                eventGate?.recordStartupFailure(
                    "Meeting audio could not be written: \(error.localizedDescription)"
                )
                _ = try? writer.recordFailure(
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
            _ = try? writer.recordDiscontinuity(
                source: source,
                reason: value.reason,
                sourceTimestamp: value.sourceTimestamp,
                hostTimestamp: value.hostTimestamp,
                detail: value.detail
            )

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
            _ = try? writer.recordDiscontinuity(
                source: source,
                reason: value.reason == .permissionRevoked ? .permissionRevoked : .sourceFailure,
                hostTimestamp: value.hostTimestamp,
                detail: value.message
            )
            _ = try? writer.recordFailure(
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
        guard writer != nil else { return }
        eventGate?.stopAccepting()
        let activeSwitch = beginSessionShutdown()
        await activeSwitch?.value
        await microphone?.stop()
        await systemAudio?.stop()
        await eventGate?.waitUntilIdle()
        await transcript?.cancel()
        clearSession()
        ownership.set(false)
        runtimeFailureHandler?(message)
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
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = nil
        microphoneSwitchTask?.cancel()
        microphoneSwitchTask = nil
        activeMicrophoneSwitchID = nil
        request = nil
        writer = nil
        transcript = nil
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

    func beginEvent() -> Bool {
        lock.withLock {
            guard accepting, !paused else { return false }
            pendingEvents += 1
            return true
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
