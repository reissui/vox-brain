import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct MeetingControllerTests {
    private let zoom = MeetingDetectedApplication(
        processIdentifier: 120,
        bundleIdentifier: "us.zoom.xos",
        displayName: "Zoom"
    )
    private let browser = MeetingDetectedApplication(
        processIdentifier: 121,
        bundleIdentifier: "com.apple.Safari",
        displayName: "Safari"
    )
    private let unknownApp = MeetingDetectedApplication(
        processIdentifier: 122,
        bundleIdentifier: "dev.example.huddle",
        displayName: "Huddle"
    )

    @Test
    func transcriptTitlePrefersMeaningfulMicrophoneContextAndFallsBackToApplication() throws {
        let system = try MeetingUtterance(
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "You've got nerve typing speed. Hello guys.",
            baseSpeakerID: "remote"
        )
        let microphone = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 70,
            endMilliseconds: 2_000,
            text: "Alright, so this is me testing the meeting audio again. Does it work?",
            baseSpeakerID: "you"
        )

        #expect(MeetingContextTitle.make(
            utterances: [system, microphone],
            applicationName: "Safari"
        ) == "Testing the Meeting Audio Again")
        #expect(MeetingContextTitle.make(
            utterances: [],
            applicationName: "Zoom"
        ) == "Meeting in Zoom")
    }

    @Test
    func audioMonitorKeepsBoundedVisualHistoryForEachIndependentSource() {
        let monitor = MeetingAudioMonitor()
        for index in 0..<(MeetingAudioMonitor.maximumHistorySamples + 5) {
            monitor.receive(MeetingAudioLevel(
                source: .microphone,
                timestampMilliseconds: Int64(index),
                rms: Float(index) / 100,
                isClipping: false
            ))
        }
        monitor.receive(MeetingAudioLevel(
            source: .system,
            timestampMilliseconds: 1,
            rms: 0.6,
            isClipping: false
        ))

        #expect(monitor.histories[.microphone]?.count == MeetingAudioMonitor.maximumHistorySamples)
        #expect(monitor.histories[.microphone]?.last == monitor.levels[.microphone])
        #expect(monitor.histories[.system] == [MeetingAudioMonitor.visualLevel(forRMS: 0.6)])
        monitor.reset()
        #expect(monitor.histories.isEmpty)
        #expect(monitor.levels.isEmpty)
        #expect(monitor.signalStates.isEmpty)
    }

    @Test
    func audioMonitorSeparatesQuietFromActiveAndMakesOrdinarySpeechVisible() {
        let monitor = MeetingAudioMonitor()
        monitor.warn(MeetingAudioWarning(source: .microphone, message: "Check microphone"))

        monitor.receive(MeetingAudioLevel(
            source: .microphone,
            timestampMilliseconds: 0,
            rms: 0,
            isClipping: false
        ))
        #expect(monitor.signalStates[.microphone] == .quiet)
        #expect(monitor.levels[.microphone] == 0)
        #expect(monitor.guidance[.microphone] == "Check microphone")
        #expect(monitor.signalStates[.system] == nil)

        monitor.receive(MeetingAudioLevel(
            source: .system,
            timestampMilliseconds: 100,
            rms: 0.01,
            isClipping: false
        ))
        monitor.receive(MeetingAudioLevel(
            source: .microphone,
            timestampMilliseconds: 100,
            rms: 0.06,
            isClipping: false
        ))

        let computerLevel = monitor.levels[.system] ?? 0
        let microphoneLevel = monitor.levels[.microphone] ?? 0
        #expect(monitor.signalStates[.system] == .active)
        #expect(monitor.signalStates[.microphone] == .active)
        #expect(computerLevel > 0.3)
        #expect(microphoneLevel > computerLevel)
        #expect(monitor.guidance[.microphone] == nil)
        #expect(MeetingAudioMonitor.visualLevel(forRMS: 0) == 0)
        #expect(MeetingAudioMonitor.visualLevel(forRMS: 0.06)
            > MeetingAudioMonitor.visualLevel(forRMS: 0.01))
    }

    @Test
    func audioMonitorBoundsHistoryAndCompletesQuietDecay() {
        let monitor = MeetingAudioMonitor()
        monitor.receive(MeetingAudioLevel(
            source: .microphone,
            timestampMilliseconds: 0,
            rms: 0.1,
            isClipping: false
        ))

        for index in 1...MeetingAudioMonitor.maximumDecayUpdates {
            monitor.receive(MeetingAudioLevel(
                source: .microphone,
                timestampMilliseconds: Int64(index * 100),
                rms: 0,
                isClipping: false
            ))
        }
        #expect(monitor.signalStates[.microphone] == .quiet)
        #expect(monitor.levels[.microphone] == 0)
        #expect(monitor.histories[.microphone]?.last == 0)

        for index in 0..<(MeetingAudioMonitor.maximumHistorySamples + 8) {
            monitor.receive(MeetingAudioLevel(
                source: .system,
                timestampMilliseconds: Int64(index * 100),
                rms: index.isMultiple(of: 2) ? 0.01 : 0.06,
                isClipping: false
            ))
        }
        #expect(monitor.histories[.system]?.count == MeetingAudioMonitor.maximumHistorySamples)
        #expect(Set(monitor.histories[.system] ?? []).count > 1)
        #expect(monitor.histories[.microphone] != monitor.histories[.system])

        monitor.reset()
        #expect(monitor.levels.isEmpty)
        #expect(monitor.histories.isEmpty)
        #expect(monitor.signalStates.isEmpty)
    }

    @Test
    func knownAppsPromptImmediatelyAndBrowsersRequireTenContinuousSecondsOfSpeech() throws {
        let detector = MeetingDetector(ownProcessIdentifier: 999)
        let start = Date(timeIntervalSince1970: 1_000)

        let known = try #require(detector.observe(.init(
            microphoneUsers: [zoom],
            isSystemSpeechActive: false
        ), at: start))
        #expect(known == .startCandidate(MeetingStartCandidate(
            application: zoom,
            reason: .knownConferencingApplication,
            suggestedAt: start
        )))

        detector.reset()
        #expect(detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(9.999)) == nil)

        let browserCandidate = try #require(detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(10)))
        #expect(browserCandidate == .startCandidate(MeetingStartCandidate(
            application: browser,
            reason: .sustainedSystemSpeech,
            suggestedAt: start.addingTimeInterval(10)
        )))

        detector.reset()
        _ = detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start)
        _ = detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: false
        ), at: start.addingTimeInterval(6))
        #expect(detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(12)) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [browser],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(22)) != nil)

        let ownProcess = MeetingDetectedApplication(
            processIdentifier: 999,
            bundleIdentifier: "us.zoom.xos",
            displayName: "Brain"
        )
        detector.reset()
        #expect(detector.observe(.init(
            microphoneUsers: [ownProcess],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(100)) == nil)
    }

    @Test
    func startCandidateOffersOnlyExplicitActionsAndDoesNotOpenCapture() async throws {
        let fixture = makeFixture()
        let candidate = MeetingStartCandidate(
            application: zoom,
            reason: .knownConferencingApplication,
            suggestedAt: fixture.clock.now
        )
        fixture.detector.events = [.startCandidate(candidate)]

        await fixture.controller.observe(.empty)

        #expect(fixture.controller.state == .startSuggested)
        #expect(fixture.controller.startSuggestion?.candidate == candidate)
        #expect(MeetingStartSuggestion.actions == [.startRecording, .dismiss])
        #expect(fixture.recorder.actions.isEmpty)

        fixture.controller.dismissStartSuggestion()
        #expect(fixture.controller.state == .idle)
        #expect(fixture.detector.dismissedCandidates == [candidate])
        #expect(fixture.recorder.actions.isEmpty)
    }

    @Test
    func manualStartRecordsAnyApplicationWithoutDetectorRecognition() async throws {
        let fixture = makeFixture()

        await fixture.controller.startRecording(application: unknownApp)

        #expect(fixture.controller.state == .recording)
        #expect(fixture.controller.currentMeeting?.detectedApplication == "Huddle")
        #expect(fixture.controller.currentMeeting?.recordingKind == .meeting)
        #expect(fixture.recorder.actions == [.start(MeetingRecordingRequest(
            meetingID: try #require(fixture.controller.currentMeeting?.id),
            recordingKind: .meeting,
            application: unknownApp,
            startedAt: fixture.clock.now,
            title: "Meeting in Huddle",
            titleSource: .application
        ))])
        #expect(fixture.detector.trackedApplications == [unknownApp])
    }

    @Test
    func longVoiceNoteUsesTheMeetingRecorderAndSurvivesAsItsOwnTitle() async throws {
        let fixture = makeFixture()

        await fixture.controller.startVoiceNote()

        let meeting = try #require(fixture.controller.currentMeeting)
        #expect(fixture.controller.state == .recording)
        #expect(meeting.title == "Voice note")
        #expect(meeting.recordingKind == .voiceNote)
        #expect(meeting.titleSource == .manual)
        #expect(meeting.detectedApplication == nil)
        #expect(fixture.recorder.actions == [.start(MeetingRecordingRequest(
            meetingID: meeting.id,
            recordingKind: .voiceNote,
            application: nil,
            startedAt: fixture.clock.now,
            title: "Voice note",
            titleSource: .manual
        ))])
    }

    @Test
    func everyNormalLifecycleStateIsExplicitAndOnlyStopFinalizes() async throws {
        let fixture = makeFixture()
        let candidate = MeetingStartCandidate(
            application: zoom,
            reason: .knownConferencingApplication,
            suggestedAt: fixture.clock.now
        )
        fixture.detector.events = [.startCandidate(candidate)]
        #expect(fixture.controller.state == .idle)

        await fixture.controller.observe(.empty)
        #expect(fixture.controller.state == .startSuggested)

        fixture.recorder.shouldSuspendStart = true
        let startTask = Task { await fixture.controller.startRecording() }
        await fixture.recorder.waitUntilStartIsSuspended()
        #expect(fixture.controller.state == .starting)
        fixture.recorder.releaseStart()
        await startTask.value
        #expect(fixture.controller.state == .recording)

        fixture.clock.advance(by: 30)
        await fixture.controller.pause()
        #expect(fixture.controller.state == .paused)

        fixture.clock.advance(by: 15)
        await fixture.controller.resume()
        #expect(fixture.controller.state == .recording)
        #expect(fixture.recorder.actions.contains(.resume(.resumedAfterPause(
            pausedAt: fixture.clock.now.addingTimeInterval(-15),
            resumedAt: fixture.clock.now
        ))))

        fixture.detector.events = [.endCandidate(suggestedAt: fixture.clock.now)]
        await fixture.controller.observe(.empty)
        #expect(fixture.controller.state == .stopSuggested)
        #expect(MeetingStopSuggestion.actions == [.stop, .keepRecording])
        #expect(fixture.recorder.stopCount == 0)

        fixture.recorder.shouldSuspendStop = true
        let stopTask = Task { await fixture.controller.stop() }
        await fixture.recorder.waitUntilStopIsSuspended()
        #expect(fixture.controller.state == .finalizing)
        fixture.recorder.releaseStop()
        await stopTask.value
        #expect(fixture.controller.state == .completed)
        #expect(fixture.controller.currentMeeting?.endedAt == fixture.clock.now)

        fixture.controller.resetCompletedMeeting()
        #expect(fixture.controller.state == .idle)
        #expect(fixture.controller.currentMeeting == nil)
    }

    @Test
    func oneStopClickDuringAudioReadinessFinalizesAfterStartupCompletes() async {
        let fixture = makeFixture()
        fixture.recorder.shouldSuspendStart = true

        let startTask = Task {
            await fixture.controller.startRecording(application: nil)
        }
        await fixture.recorder.waitUntilStartIsSuspended()
        #expect(fixture.controller.state == .starting)

        await fixture.controller.stop()
        #expect(fixture.controller.state == .finalizing)

        fixture.recorder.releaseStart()
        await startTask.value

        #expect(fixture.recorder.stopCount == 1)
        #expect(fixture.controller.state == .completed)
    }

    @Test
    func detectedEndNeedsMicSignalToEndAndFifteenSecondsWithoutSpeech() throws {
        let detector = MeetingDetector(ownProcessIdentifier: 999)
        let start = Date(timeIntervalSince1970: 2_000)
        detector.beginTracking(zoom)

        #expect(detector.observe(.init(
            microphoneUsers: [zoom],
            isSystemSpeechActive: false
        ), at: start) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [],
            isSystemSpeechActive: true
        ), at: start.addingTimeInterval(20)) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [],
            isSystemSpeechActive: false
        ), at: start.addingTimeInterval(30)) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [],
            isSystemSpeechActive: false
        ), at: start.addingTimeInterval(44.999)) == nil)
        #expect(detector.observe(.init(
            microphoneUsers: [],
            isSystemSpeechActive: false
        ), at: start.addingTimeInterval(45)) == .endCandidate(
            suggestedAt: start.addingTimeInterval(45)
        ))
    }

    @Test
    func ignoredEndPromptNeverStopsAndKeepSuppressesPromptsForFiveMinutes() async {
        let fixture = makeFixture()
        await fixture.controller.startRecording(application: zoom)
        fixture.detector.events = [.endCandidate(suggestedAt: fixture.clock.now)]
        await fixture.controller.observe(.empty)

        #expect(fixture.controller.state == .stopSuggested)
        fixture.clock.advance(by: 4 * 60)
        await fixture.controller.tick()
        #expect(fixture.controller.state == .stopSuggested)
        #expect(fixture.recorder.stopCount == 0)

        fixture.controller.keepRecording()
        #expect(fixture.controller.state == .recording)
        let suppressionEnd = fixture.clock.now.addingTimeInterval(5 * 60)
        #expect(fixture.controller.endSuggestionsSuppressedUntil == suppressionEnd)
        #expect(fixture.detector.suppressedUntil == [suppressionEnd])

        fixture.clock.advance(by: 5 * 60 - 0.001)
        fixture.detector.events = [.endCandidate(suggestedAt: fixture.clock.now)]
        await fixture.controller.observe(.empty)
        #expect(fixture.controller.state == .recording)

        fixture.clock.advance(by: 0.001)
        fixture.detector.events = [.endCandidate(suggestedAt: fixture.clock.now)]
        await fixture.controller.observe(.empty)
        #expect(fixture.controller.state == .stopSuggested)
        #expect(fixture.recorder.stopCount == 0)
    }

    @Test
    func eightHourLimitFailsToRecoveryWithoutNormalFinalization() async {
        let fixture = makeFixture()
        await fixture.controller.startRecording(application: zoom)
        fixture.detector.events = [.endCandidate(suggestedAt: fixture.clock.now)]
        await fixture.controller.observe(.empty)
        #expect(fixture.controller.state == .stopSuggested)

        fixture.clock.advance(by: 8 * 60 * 60 - 0.001)
        await fixture.controller.tick()
        #expect(fixture.controller.state == .stopSuggested)

        fixture.clock.advance(by: 0.001)
        await fixture.controller.tick()
        #expect(fixture.controller.state == .failed)
        #expect(fixture.controller.failure == .eightHourSafetyLimit)
        #expect(fixture.recorder.actions.last == .preserveForRecovery(
            fixture.clock.now,
            .eightHourSafetyLimit
        ))
        #expect(fixture.recorder.stopCount == 0)
    }

    @Test
    func runtimeMicrophoneFailureCannotLeaveMeetingMarkedRecording() async {
        let fixture = makeFixture()
        await fixture.controller.startRecording(application: zoom)
        #expect(fixture.controller.state == .recording)

        fixture.recorder.reportRuntimeFailure("The selected microphone disconnected.")

        #expect(fixture.controller.state == .failed)
        #expect(fixture.controller.currentMeeting?.lifecycleState == .failed)
        #expect(fixture.controller.currentMeeting?.endedAt == fixture.clock.now)
        #expect(fixture.controller.failure == .startFailed("The selected microphone disconnected."))
    }

    @Test
    func microphonePresentationAndChangesDelegateThroughTheMeetingController() async {
        let fixture = makeFixture()
        let device = MeetingMicrophoneDevice(
            id: "desk-mic",
            name: "Desk Microphone",
            coreAudioID: 42,
            isSystemDefault: true
        )
        fixture.recorder.microphonePresentation = RecordingIslandMicrophonePresentation(
            activeDevice: device,
            availableDevices: [device],
            selectedPreference: .systemDefault
        )
        var presentationChanges = 0
        fixture.controller.setTransitionHandler { presentationChanges += 1 }

        #expect(fixture.controller.microphonePresentation?.activeDeviceName == "Desk Microphone")
        await fixture.controller.selectMicrophone(.device(uid: device.id))

        #expect(fixture.recorder.microphoneSelections == [.device(uid: "desk-mic")])
        fixture.recorder.reportMicrophonePresentationChange()
        #expect(presentationChanges == 1)
    }

    private func makeFixture() -> MeetingControllerFixture {
        MeetingControllerFixture()
    }
}

private extension MeetingDetectorObservation {
    static let empty = MeetingDetectorObservation(
        microphoneUsers: [],
        isSystemSpeechActive: false
    )
}

@MainActor
private final class MeetingControllerFixture {
    let clock = VirtualMeetingClock(now: Date(timeIntervalSince1970: 10_000))
    let detector = VirtualMeetingDetector()
    let recorder = VirtualMeetingRecorder()
    let controller: MeetingController

    init() {
        controller = MeetingController(
            detector: detector,
            recorder: recorder,
            clock: clock,
            speechEngine: "parakeet",
            speechModel: "tdt-v3"
        )
    }
}

@MainActor
private final class VirtualMeetingClock: MeetingControllingClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
private final class VirtualMeetingDetector: MeetingDetecting {
    var events: [MeetingDetectorEvent] = []
    private(set) var trackedApplications: [MeetingDetectedApplication?] = []
    private(set) var dismissedCandidates: [MeetingStartCandidate] = []
    private(set) var suppressedUntil: [Date] = []
    private(set) var resetCount = 0

    func observe(
        _ observation: MeetingDetectorObservation,
        at date: Date
    ) -> MeetingDetectorEvent? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    func beginTracking(_ application: MeetingDetectedApplication?) {
        trackedApplications.append(application)
    }

    func dismiss(_ candidate: MeetingStartCandidate) {
        dismissedCandidates.append(candidate)
    }

    func suppressEndSuggestions(until date: Date) {
        suppressedUntil.append(date)
    }

    func reset() {
        resetCount += 1
    }
}

private enum VirtualMeetingRecorderAction: Equatable {
    case start(MeetingRecordingRequest)
    case pause(Date)
    case resume(MeetingRecordingDiscontinuity)
    case stop(Date)
    case preserveForRecovery(Date, MeetingRecoveryReason)

}

@MainActor
private final class VirtualMeetingRecorder: MeetingRecording, MeetingMicrophoneSwitching {
    private(set) var actions: [VirtualMeetingRecorderAction] = []
    private(set) var stopCount = 0
    var shouldSuspendStart = false
    var shouldSuspendStop = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var runtimeFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private var microphonePresentationHandler: (@MainActor @Sendable () -> Void)?
    private(set) var microphoneSelections: [MeetingMicrophoneSelection] = []
    var microphonePresentation: RecordingIslandMicrophonePresentation?

    func start(_ request: MeetingRecordingRequest) async throws {
        actions.append(.start(request))
        if shouldSuspendStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
    }

    func pause(at date: Date) async throws {
        actions.append(.pause(date))
    }

    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {
        actions.append(.resume(discontinuity))
    }

    func stop(at date: Date) async throws -> MeetingRecord? {
        stopCount += 1
        actions.append(.stop(date))
        if shouldSuspendStop {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        return nil
    }

    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {
        actions.append(.preserveForRecovery(date, reason))
    }

    func setRuntimeFailureHandler(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        runtimeFailureHandler = handler
    }

    func reportRuntimeFailure(_ message: String) {
        runtimeFailureHandler?(message)
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) async {
        microphoneSelections.append(selection)
    }

    func setMicrophonePresentationHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        microphonePresentationHandler = handler
    }

    func reportMicrophonePresentationChange() {
        microphonePresentationHandler?()
    }

    func waitUntilStartIsSuspended() async {
        while startContinuation == nil { await Task.yield() }
    }

    func releaseStart() {
        shouldSuspendStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStopIsSuspended() async {
        while stopContinuation == nil { await Task.yield() }
    }

    func releaseStop() {
        shouldSuspendStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}
