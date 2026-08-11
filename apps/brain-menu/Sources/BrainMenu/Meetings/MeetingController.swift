import Foundation
import Observation

enum MeetingStartSuggestionAction: String, CaseIterable, Equatable, Sendable {
    case startRecording
    case dismiss
}

struct MeetingStartSuggestion: Equatable, Sendable {
    static let actions = MeetingStartSuggestionAction.allCases

    let candidate: MeetingStartCandidate
}

enum MeetingStopSuggestionAction: String, CaseIterable, Equatable, Sendable {
    case stop
    case keepRecording
}

struct MeetingStopSuggestion: Equatable, Sendable {
    static let actions = MeetingStopSuggestionAction.allCases

    let suggestedAt: Date
}

struct MeetingRecordingRequest: Equatable, Sendable {
    let meetingID: UUID
    let recordingKind: MeetingRecordingKind
    let application: MeetingDetectedApplication?
    let startedAt: Date
    let title: String
    let titleSource: MeetingTitleSource

    /// Meetings capture both sides of a call. A Voice Note is intentionally a
    /// single-person microphone recording and must not depend on screen or
    /// system-audio availability.
    var capturesSystemAudio: Bool { recordingKind == .meeting }
}

enum MeetingRecordingStartError: Error, Equatable, LocalizedError, Sendable {
    case microphoneSelectionRequired(deviceName: String?)

    var errorDescription: String? {
        switch self {
        case .microphoneSelectionRequired(let deviceName):
            if let deviceName, !deviceName.isEmpty {
                "\(deviceName) could not be used for recording. Choose a different microphone."
            } else {
                "The selected microphone could not be used for recording. Choose a different microphone."
            }
        }
    }
}

enum MeetingRecordingDiscontinuity: Equatable, Sendable {
    case resumedAfterPause(pausedAt: Date, resumedAt: Date)
}

enum MeetingRecoveryReason: String, Equatable, Sendable {
    case eightHourSafetyLimit
}

@MainActor
protocol MeetingRecording: AnyObject {
    /// This is the only method that may open the microphone and, for meetings,
    /// the system-audio stream.
    func start(_ request: MeetingRecordingRequest) async throws
    /// Stops accepting new buffers without finalizing the session.
    func pause(at date: Date) async throws
    /// Resumes writes and records the supplied discontinuity.
    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws
    /// Explicit user Stop is the only normal path that calls this finalizer.
    func stop(at date: Date) async throws -> MeetingRecord?
    /// Quiesces writing while retaining incomplete files for recovery. It must
    /// not finalize or delete the captured data.
    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async
    /// Native recorders report a source failure that occurs after start so the
    /// lifecycle cannot remain falsely marked Recording.
    func setRuntimeFailureHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    )
    /// Delivers the durable post-recording transcript result without keeping
    /// the Stop action blocked on speech processing.
    func setPostProcessingHandler(
        _ handler: @escaping @MainActor @Sendable (MeetingRecord) -> Void
    )
    /// Publishes the exact live controller used by the active recorder. UI
    /// consumers observe it; they never construct a parallel speech runtime.
    var liveTranscriptController: LiveTranscriptController? { get }
    func setLiveTranscriptControllerHandler(
        _ handler: @escaping @MainActor @Sendable (LiveTranscriptController?) -> Void
    )
    func setMeetingNotesFlushHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    )
}

extension MeetingRecording {
    func setRuntimeFailureHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {}

    func setPostProcessingHandler(
        _ handler: @escaping @MainActor @Sendable (MeetingRecord) -> Void
    ) {}

    var liveTranscriptController: LiveTranscriptController? { nil }

    func setLiveTranscriptControllerHandler(
        _ handler: @escaping @MainActor @Sendable (LiveTranscriptController?) -> Void
    ) {}

    func setMeetingNotesFlushHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    ) {}
}

@MainActor
protocol MeetingMicrophoneSwitching: AnyObject {
    var microphonePresentation: RecordingIslandMicrophonePresentation? { get }
    func selectMicrophone(_ selection: MeetingMicrophoneSelection) async
    func setMicrophonePresentationHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    )
}

enum MeetingAudioSignalState: String, Equatable, Sendable {
    case waiting
    case quiet
    case active
}

@MainActor
@Observable
final class MeetingAudioMonitor {
    static let maximumHistorySamples = 24
    static let maximumDecayUpdates = 6
    static let minimumDisplayedDecibels: Float = -60

    private(set) var levels: [MeetingAudioSource: Float] = [:]
    private(set) var histories: [MeetingAudioSource: [Float]] = [:]
    private(set) var signalStates: [MeetingAudioSource: MeetingAudioSignalState] = [:]
    private(set) var guidance: [MeetingAudioSource: String] = [:]

    @ObservationIgnored private var quietUpdateCounts: [MeetingAudioSource: Int] = [:]

    func receive(_ level: MeetingAudioLevel) {
        let rms = level.rms.isFinite ? max(level.rms, 0) : 0
        let isActive = rms > MeetingMicrophoneReadiness.audibleRMS
        signalStates[level.source] = isActive ? .active : .quiet

        let target = Self.visualLevel(forRMS: rms)
        let previous = levels[level.source] ?? 0
        let visualLevel: Float
        if isActive {
            quietUpdateCounts[level.source] = 0
            // Attack immediately so speech is visible, then release more gently
            // so the shape reads as a waveform instead of flickering bars.
            visualLevel = target >= previous ? target : max(target, previous * 0.72)
            guidance[level.source] = nil
        } else {
            let quietUpdates = quietUpdateCounts[level.source, default: 0] + 1
            quietUpdateCounts[level.source] = quietUpdates
            visualLevel = quietUpdates >= Self.maximumDecayUpdates
                ? 0
                : previous * 0.55
        }
        levels[level.source] = min(max(visualLevel, 0), 1)

        var history = histories[level.source, default: []]
        history.append(levels[level.source] ?? 0)
        if history.count > Self.maximumHistorySamples {
            history.removeFirst(history.count - Self.maximumHistorySamples)
        }
        histories[level.source] = history
    }

    func warn(_ warning: MeetingAudioWarning) {
        guidance[warning.source] = warning.message
    }

    func reset() {
        levels.removeAll()
        histories.removeAll()
        signalStates.removeAll()
        guidance.removeAll()
        quietUpdateCounts.removeAll()
    }

    static func visualLevel(forRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = Float(20 * log10(Double(rms)))
        return min(max(
            (decibels - minimumDisplayedDecibels) / -minimumDisplayedDecibels,
            0
        ), 1)
    }
}

@MainActor
protocol MeetingControllingClock: AnyObject {
    var now: Date { get }
}

@MainActor
final class SystemMeetingClock: MeetingControllingClock {
    var now: Date { Date() }
}

enum MeetingControllerFailure: Error, Equatable, Sendable {
    case startFailed(String)
    case microphoneSelectionRequired(String)
    case pauseFailed(String)
    case resumeFailed(String)
    case stopFailed(String)
    case eightHourSafetyLimit
}

@MainActor
final class MeetingController {
    static let endSuggestionCooldown: TimeInterval = 5 * 60
    static let maximumMeetingDuration: TimeInterval = 8 * 60 * 60

    private let detector: any MeetingDetecting
    private let recorder: any MeetingRecording
    private let clock: any MeetingControllingClock
    private let speechEngine: String
    private let speechModel: String
    let audioMonitor: MeetingAudioMonitor

    private(set) var state: MeetingLifecycleState = .idle
    private(set) var currentMeeting: MeetingRecord?
    private(set) var startSuggestion: MeetingStartSuggestion?
    private(set) var stopSuggestion: MeetingStopSuggestion?
    private(set) var failure: MeetingControllerFailure?
    private(set) var endSuggestionsSuppressedUntil: Date?
    private var pausedAt: Date?
    private var stopRequestedWhileStarting = false
    private var transitionHandler: (@MainActor @Sendable () -> Void)?

    init(
        detector: any MeetingDetecting,
        recorder: any MeetingRecording,
        clock: any MeetingControllingClock = SystemMeetingClock(),
        speechEngine: String,
        speechModel: String,
        audioMonitor: MeetingAudioMonitor = MeetingAudioMonitor()
    ) {
        self.detector = detector
        self.recorder = recorder
        self.clock = clock
        self.speechEngine = speechEngine
        self.speechModel = speechModel
        self.audioMonitor = audioMonitor
    }

    var audioLevels: [MeetingAudioSource: Float] { audioMonitor.levels }
    var audioHistories: [MeetingAudioSource: [Float]] { audioMonitor.histories }
    var audioSignalStates: [MeetingAudioSource: MeetingAudioSignalState] {
        audioMonitor.signalStates
    }
    var audioGuidance: [MeetingAudioSource: String] { audioMonitor.guidance }
    var microphonePresentation: RecordingIslandMicrophonePresentation? {
        (recorder as? any MeetingMicrophoneSwitching)?.microphonePresentation
    }
    var liveTranscriptController: LiveTranscriptController? {
        recorder.liveTranscriptController
    }

    func setTransitionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        transitionHandler = handler
        (recorder as? any MeetingMicrophoneSwitching)?
            .setMicrophonePresentationHandler(handler)
    }

    func setLiveTranscriptControllerHandler(
        _ handler: @escaping @MainActor @Sendable (LiveTranscriptController?) -> Void
    ) {
        recorder.setLiveTranscriptControllerHandler(handler)
    }

    func setMeetingNotesFlushHandler(
        _ handler: @escaping @MainActor @Sendable () async -> Void
    ) {
        recorder.setMeetingNotesFlushHandler(handler)
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) async {
        await (recorder as? any MeetingMicrophoneSwitching)?.selectMicrophone(selection)
        guard state == .sourceSelectionRequired else { return }
        resetSourceSelectionRequest()
    }

    /// Consumes detector evidence and checks the safety deadline. No recording
    /// resource is touched while idle or while a start suggestion is visible.
    func observe(_ observation: MeetingDetectorObservation) async {
        guard await enforceSafetyLimitIfNeeded() else { return }
        guard let event = detector.observe(observation, at: clock.now) else { return }

        switch event {
        case .startCandidate(let candidate):
            guard state == .idle else { return }
            startSuggestion = MeetingStartSuggestion(candidate: candidate)
            transition(to: .startSuggested)

        case .endCandidate(let suggestedAt):
            guard state == .recording else { return }
            if let suppressedUntil = endSuggestionsSuppressedUntil,
               clock.now < suppressedUntil {
                detector.suppressEndSuggestions(until: suppressedUntil)
                return
            }
            stopSuggestion = MeetingStopSuggestion(suggestedAt: suggestedAt)
            transition(to: .stopSuggested)
        }
    }

    /// Starts from the visible suggestion. Capture begins only inside this
    /// explicit action, never when the candidate is detected.
    func startRecording() async {
        guard state == .startSuggested, let candidate = startSuggestion?.candidate else { return }
        await startRecording(application: candidate.application)
    }

    /// Manual Start is accepted from idle for any application (or no detected
    /// application at all); recognition is deliberately not a prerequisite.
    func startRecording(application: MeetingDetectedApplication?) async {
        await startRecording(
            application: application,
            title: Self.defaultTitle(application: application),
            recordingKind: .meeting,
            titleSource: .application
        )
    }

    /// Long-form solo speech uses the same durable recording pipeline with a
    /// microphone-only source configuration.
    func startVoiceNote() async {
        await startRecording(
            application: nil,
            title: "Voice note",
            recordingKind: .voiceNote,
            titleSource: .manual
        )
    }

    private func startRecording(
        application: MeetingDetectedApplication?,
        title: String,
        recordingKind: MeetingRecordingKind,
        titleSource: MeetingTitleSource
    ) async {
        guard state == .idle || state == .startSuggested else { return }

        let date = clock.now
        let meeting = MeetingRecord(
            title: title,
            recordingKind: recordingKind,
            titleSource: titleSource,
            detectedApplication: application?.displayName,
            startedAt: date,
            lifecycleState: .starting,
            speechEngine: speechEngine,
            speechModel: speechModel
        )
        currentMeeting = meeting
        audioMonitor.reset()
        startSuggestion = nil
        stopSuggestion = nil
        failure = nil
        stopRequestedWhileStarting = false
        transition(to: .starting)

        do {
            recorder.setRuntimeFailureHandler { [weak self] message in
                self?.recordingFailed(message)
            }
            recorder.setPostProcessingHandler { [weak self] meeting in
                self?.postProcessingFinished(meeting)
            }
            try await recorder.start(MeetingRecordingRequest(
                meetingID: meeting.id,
                recordingKind: recordingKind,
                application: application,
                startedAt: date,
                title: title,
                titleSource: titleSource
            ))
            detector.beginTracking(application)
            if stopRequestedWhileStarting {
                stopRequestedWhileStarting = false
                await finalizeStop(at: clock.now)
            } else {
                transition(to: .recording)
            }
        } catch let error as MeetingRecordingStartError {
            stopRequestedWhileStarting = false
            failure = .microphoneSelectionRequired(error.localizedDescription)
            transition(to: .sourceSelectionRequired)
        } catch {
            stopRequestedWhileStarting = false
            failure = .startFailed(error.localizedDescription)
            transition(to: .failed)
        }
    }

    func dismissStartSuggestion() {
        guard state == .startSuggested, let candidate = startSuggestion?.candidate else { return }
        detector.dismiss(candidate)
        startSuggestion = nil
        transition(to: .idle)
    }

    func pause() async {
        guard state == .recording || state == .stopSuggested else { return }
        let date = clock.now
        do {
            try await recorder.pause(at: date)
            pausedAt = date
            stopSuggestion = nil
            transition(to: .paused)
        } catch {
            failure = .pauseFailed(error.localizedDescription)
            transition(to: .failed)
        }
    }

    func resume() async {
        guard state == .paused, let pausedAt else { return }
        let date = clock.now
        do {
            try await recorder.resume(with: .resumedAfterPause(
                pausedAt: pausedAt,
                resumedAt: date
            ))
            self.pausedAt = nil
            transition(to: .recording)
        } catch {
            failure = .resumeFailed(error.localizedDescription)
            transition(to: .failed)
        }
    }

    /// Choosing Keep is explicit acknowledgement, not a stop. The existing
    /// recorder keeps running and another end suggestion is suppressed for five minutes.
    func keepRecording() {
        guard state == .stopSuggested else { return }
        let suppressionEnd = clock.now.addingTimeInterval(Self.endSuggestionCooldown)
        endSuggestionsSuppressedUntil = suppressionEnd
        detector.suppressEndSuggestions(until: suppressionEnd)
        stopSuggestion = nil
        transition(to: .recording)
    }

    /// Explicit user Stop is the only normal transition into finalizing.
    func stop() async {
        if state == .starting {
            stopRequestedWhileStarting = true
            stopSuggestion = nil
            transition(to: .finalizing)
            return
        }
        guard state == .recording || state == .paused || state == .stopSuggested else { return }
        await finalizeStop(at: clock.now)
    }

    private func finalizeStop(at date: Date) async {
        stopSuggestion = nil
        transition(to: .finalizing)
        do {
            if let completed = try await recorder.stop(at: date) {
                currentMeeting = completed
            } else if currentMeeting != nil {
                currentMeeting?.endedAt = date
            }
            detector.reset()
            transition(to: .completed)
        } catch {
            failure = .stopFailed(error.localizedDescription)
            transition(to: .failed)
        }
    }

    /// Allows a virtual or production scheduler to enforce the only automatic
    /// terminal condition. This fails safely and preserves partial data; it
    /// does not call the normal finalizer.
    func tick() async {
        _ = await enforceSafetyLimitIfNeeded()
    }

    /// Releases a finished controller for the next meeting. A failed meeting
    /// remains available until the caller has dealt with its recovery data.
    func resetCompletedMeeting() {
        guard state == .completed else { return }
        currentMeeting = nil
        startSuggestion = nil
        stopSuggestion = nil
        failure = nil
        endSuggestionsSuppressedUntil = nil
        pausedAt = nil
        stopRequestedWhileStarting = false
        detector.reset()
        state = .idle
        transitionHandler?()
    }

    /// A failed in-memory session must not block the next recording. Its durable
    /// record remains in Meetings for recovery and explicit transcript retry.
    func resetFailedMeeting() {
        guard state == .failed else { return }
        clearFailedMeeting()
    }

    private func resetSourceSelectionRequest() {
        guard state == .sourceSelectionRequired else { return }
        clearFailedMeeting()
    }

    private func clearFailedMeeting() {
        currentMeeting = nil
        startSuggestion = nil
        stopSuggestion = nil
        failure = nil
        endSuggestionsSuppressedUntil = nil
        pausedAt = nil
        stopRequestedWhileStarting = false
        detector.reset()
        state = .idle
        transitionHandler?()
    }

    func replaceCompletedMeeting(_ meeting: MeetingRecord) {
        guard state == .completed, currentMeeting?.id == meeting.id else { return }
        currentMeeting = meeting
        transitionHandler?()
    }

    private func enforceSafetyLimitIfNeeded() async -> Bool {
        guard [.starting, .recording, .paused, .stopSuggested].contains(state),
              let startedAt = currentMeeting?.startedAt,
              clock.now.timeIntervalSince(startedAt) >= Self.maximumMeetingDuration else {
            return true
        }

        let date = clock.now
        await recorder.preserveForRecovery(at: date, reason: .eightHourSafetyLimit)
        stopSuggestion = nil
        stopRequestedWhileStarting = false
        failure = .eightHourSafetyLimit
        currentMeeting?.endedAt = date
        detector.reset()
        transition(to: .failed)
        return false
    }

    private func transition(to newState: MeetingLifecycleState) {
        state = newState
        currentMeeting?.lifecycleState = newState
        transitionHandler?()
    }

    private func recordingFailed(_ message: String) {
        guard [.starting, .recording, .paused, .stopSuggested].contains(state) else { return }
        failure = .startFailed(message)
        currentMeeting?.endedAt = clock.now
        stopSuggestion = nil
        stopRequestedWhileStarting = false
        detector.reset()
        transition(to: .failed)
    }

    private func postProcessingFinished(_ meeting: MeetingRecord) {
        guard state == .completed, currentMeeting?.id == meeting.id else { return }
        currentMeeting = meeting
        transitionHandler?()
    }

    private static func defaultTitle(application: MeetingDetectedApplication?) -> String {
        guard let application else { return "Meeting" }
        return "Meeting in \(application.displayName)"
    }
}
