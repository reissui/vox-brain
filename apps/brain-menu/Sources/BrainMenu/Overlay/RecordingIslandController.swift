import AppKit
import Foundation
import Observation
import SwiftUI

enum RecordingIslandAction: String, CaseIterable, Equatable, Sendable {
    case cancel
    case showTranscript
    case pause
    case resume
    case stop
    case keepRecording
}

enum RecordingIslandDictationPhase: String, Equatable, Sendable {
    case listening
    case locked
    case transcribing
    case succeeded
    case error

    var title: String {
        switch self {
        case .listening: "Listening"
        case .locked: "Locked"
        case .transcribing: "Transcribing"
        case .succeeded: "Done"
        case .error: "Dictation error"
        }
    }
}

struct RecordingIslandDictationPresentation: Equatable, Sendable {
    var phase: RecordingIslandDictationPhase
    var startedAt: Date
    var level: Float?
    var errorMessage: String?
    var shortcutDescription: String?
    var isContinuous: Bool

    init(
        phase: RecordingIslandDictationPhase,
        startedAt: Date,
        level: Float? = nil,
        errorMessage: String? = nil,
        shortcutDescription: String? = nil,
        isContinuous: Bool = false
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.level = level.map(Self.normalizedLevel)
        self.errorMessage = errorMessage
        self.shortcutDescription = shortcutDescription
        self.isContinuous = isContinuous
    }

    private static func normalizedLevel(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

enum RecordingIslandMeetingPhase: String, Equatable, Sendable {
    case starting
    case chooseMicrophone
    case recording
    case paused
    case stopSuggested
    case finalizing
    case saved

    var title: String {
        switch self {
        case .starting: "Starting recording"
        case .chooseMicrophone: "Choose microphone"
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopSuggested: "Has the meeting ended?"
        case .finalizing: "Finalizing"
        case .saved: "Meeting added"
        }
    }
}

enum RecordingIslandMicrophoneSwitchState: Equatable, Sendable {
    case ready
    case switching(to: MeetingMicrophoneSelection)
    case failed(message: String)

    var isSwitching: Bool {
        if case .switching = self { return true }
        return false
    }
}

struct RecordingIslandMicrophonePresentation: Equatable, Sendable {
    var activeDevice: MeetingMicrophoneDevice?
    var availableDevices: [MeetingMicrophoneDevice]
    var selectedPreference: MeetingMicrophoneSelection
    var switchState: RecordingIslandMicrophoneSwitchState

    init(
        activeDevice: MeetingMicrophoneDevice?,
        availableDevices: [MeetingMicrophoneDevice],
        selectedPreference: MeetingMicrophoneSelection,
        switchState: RecordingIslandMicrophoneSwitchState = .ready
    ) {
        self.activeDevice = activeDevice
        self.availableDevices = availableDevices
        self.selectedPreference = selectedPreference
        self.switchState = switchState
    }

    var activeDeviceName: String {
        activeDevice?.name ?? "Microphone unavailable"
    }

    var defaultDevice: MeetingMicrophoneDevice? {
        availableDevices.first(where: \.isSystemDefault)
    }

    var switchErrorMessage: String? {
        guard case .failed(let message) = switchState else { return nil }
        return message
    }

    func deviceName(for selection: MeetingMicrophoneSelection) -> String? {
        switch selection {
        case .systemDefault:
            defaultDevice?.name
        case .device(let uid):
            availableDevices.first(where: { $0.id == uid })?.name
        }
    }

    func contains(_ selection: MeetingMicrophoneSelection) -> Bool {
        deviceName(for: selection) != nil
    }

    var accessibilityValue: String {
        switch switchState {
        case .ready:
            return activeDeviceName
        case .switching(let selection):
            let target = deviceName(for: selection) ?? "selected microphone"
            return "\(activeDeviceName). Switching to \(target)."
        case .failed(let message):
            return "\(activeDeviceName). Microphone change failed: \(message)"
        }
    }
}

struct RecordingIslandMeetingPresentation: Equatable, Sendable {
    var phase: RecordingIslandMeetingPhase
    var title: String
    var recordingKind: MeetingRecordingKind
    var applicationName: String?
    var startedAt: Date
    var microphone: RecordingIslandMicrophonePresentation?
    var microphoneLevel: Float?
    var systemLevel: Float?
    var microphoneHistory: [Float]
    var systemHistory: [Float]
    var microphoneSignalState: MeetingAudioSignalState
    var systemSignalState: MeetingAudioSignalState
    var latestTranscriptLine: String?
    var guidance: String?

    var isVoiceNote: Bool { recordingKind == .voiceNote }

    var phaseTitle: String {
        guard isVoiceNote else { return phase.title }
        return switch phase {
        case .stopSuggested: "Finish this voice note?"
        case .saved: "Voice note added"
        default: phase.title
        }
    }

    var libraryName: String { isVoiceNote ? "Voice Notes" : "Meetings" }

    var isReceivingAudio: Bool {
        guard phase == .starting || phase == .recording || phase == .stopSuggested else {
            return false
        }
        return microphoneSignalState == .active
            || (!isVoiceNote && systemSignalState == .active)
    }

    var audioStatusText: String {
        switch phase {
        case .chooseMicrophone:
            return "Choose another microphone, then start again."
        case .paused:
            return "Audio capture paused."
        case .finalizing:
            return "Processing captured audio…"
        case .saved:
            return "Added to \(libraryName). It is now at the top of the list."
        case .starting, .recording, .stopSuggested:
            if isVoiceNote {
                return switch microphoneSignalState {
                case .active: "Receiving microphone audio…"
                case .quiet: "Connected — waiting for sound…"
                case .waiting: "Waiting for microphone audio…"
                }
            }
            switch (microphoneSignalState == .active, systemSignalState == .active) {
            case (true, true):
                return "Receiving microphone and computer audio…"
            case (true, false):
                return "Receiving microphone audio…"
            case (false, true):
                return "Receiving computer audio…"
            case (false, false):
                let hasQuietSource = microphoneSignalState == .quiet || systemSignalState == .quiet
                return hasQuietSource ? "Connected — waiting for sound…" : "Waiting for audio…"
            }
        }
    }

    init(
        phase: RecordingIslandMeetingPhase,
        title: String,
        recordingKind: MeetingRecordingKind = .meeting,
        applicationName: String? = nil,
        startedAt: Date,
        microphone: RecordingIslandMicrophonePresentation? = nil,
        microphoneLevel: Float? = nil,
        systemLevel: Float? = nil,
        microphoneHistory: [Float] = [],
        systemHistory: [Float] = [],
        microphoneSignalState: MeetingAudioSignalState? = nil,
        systemSignalState: MeetingAudioSignalState? = nil,
        latestTranscriptLine: String? = nil,
        guidance: String? = nil
    ) {
        self.phase = phase
        self.title = title
        self.recordingKind = recordingKind
        self.applicationName = applicationName
        self.startedAt = startedAt
        self.microphone = microphone
        self.microphoneLevel = microphoneLevel.map(Self.normalizedLevel)
        self.systemLevel = systemLevel.map(Self.normalizedLevel)
        self.microphoneHistory = microphoneHistory.map(Self.normalizedLevel)
        self.systemHistory = systemHistory.map(Self.normalizedLevel)
        self.microphoneSignalState = microphoneSignalState
            ?? Self.inferredSignalState(level: microphoneLevel)
        self.systemSignalState = systemSignalState
            ?? Self.inferredSignalState(level: systemLevel)
        self.latestTranscriptLine = latestTranscriptLine
        self.guidance = guidance
    }

    private static func normalizedLevel(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func inferredSignalState(level: Float?) -> MeetingAudioSignalState {
        guard let level else { return .waiting }
        return level > 0 ? .active : .quiet
    }
}

enum RecordingIslandPresentation: Equatable, Sendable {
    case hidden
    case dictation(RecordingIslandDictationPresentation)
    case meeting(RecordingIslandMeetingPresentation)

    var controls: [RecordingIslandAction] {
        switch self {
        case .hidden:
            []
        case .dictation(let presentation):
            switch presentation.phase {
            case .listening:
                presentation.isContinuous ? [.stop] : [.cancel]
            case .locked:
                presentation.isContinuous ? [.stop] : [.cancel]
            case .transcribing, .succeeded, .error:
                []
            }
        case .meeting(let presentation):
            switch presentation.phase {
            case .chooseMicrophone, .saved:
                []
            case .starting, .finalizing:
                presentation.isVoiceNote ? [] : [.showTranscript]
            case .recording:
                presentation.isVoiceNote
                    ? [.pause, .stop]
                    : [.showTranscript, .pause, .stop]
            case .paused:
                presentation.isVoiceNote
                    ? [.resume, .stop]
                    : [.showTranscript, .resume, .stop]
            case .stopSuggested:
                // A suggestion has no implicit default. Stop can happen only
                // when its explicit button dispatches `.stop`.
                presentation.isVoiceNote
                    ? [.stop, .keepRecording]
                    : [.showTranscript, .stop, .keepRecording]
            }
        }
    }

    fileprivate var announcementIdentity: String? {
        switch self {
        case .hidden:
            return nil
        case .dictation(let presentation):
            if presentation.phase == .error {
                return "dictation.error.\(presentation.errorMessage ?? "")"
            }
            return "dictation.\(presentation.phase.rawValue)"
        case .meeting(let presentation):
            return "meeting.\(presentation.phase.rawValue)"
        }
    }

    fileprivate var announcement: String? {
        switch self {
        case .hidden:
            return nil
        case .dictation(let presentation):
            if presentation.phase == .error, let error = presentation.errorMessage {
                return "Dictation error. \(error)"
            }
            return "Dictation \(presentation.phase.title.lowercased())."
        case .meeting(let presentation):
            if presentation.phase == .saved {
                let item = presentation.isVoiceNote ? "Voice note" : "Meeting"
                return "\(item) added. \(presentation.title). It is now at the top of \(presentation.libraryName)."
            }
            let item = presentation.isVoiceNote ? "Voice note" : "Meeting"
            if presentation.phase == .stopSuggested {
                return presentation.isVoiceNote
                    ? "Voice note may be ready to finish."
                    : "Meeting may have ended."
            }
            if presentation.phase == .chooseMicrophone {
                return "\(item) needs another microphone. Choose an available input, then start again."
            }
            return "\(item) \(presentation.phaseTitle.lowercased())."
        }
    }
}

struct RecordingIslandDisplay: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

/// A panel whose controls accept pointer input without taking the keyboard
/// focus away from dictation's paste destination.
final class RecordingIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class RecordingIslandController: NSObject, NSWindowDelegate {
    static let autoHideDelay: Duration = .seconds(2)
    static let meetingSavedAutoHideDelay: Duration = .seconds(5)
    static let panelSize = CGSize(width: 480, height: 142)
    static let meetingPanelSize = CGSize(width: 480, height: 220)
    static let screenMargin: CGFloat = 12
    static let persistedPositionsDefaultsKey = "recordingIsland.positionsByDisplay"

    private(set) var presentation: RecordingIslandPresentation = .hidden
    private(set) var reduceMotionEnabled: Bool
    private(set) var currentDisplayID: String?
    private(set) var panel: RecordingIslandPanel!

    var controls: [RecordingIslandAction] { presentation.controls }
    var isVisible: Bool { presentation != .hidden }
    var presentationSize: CGSize {
        if case .meeting = presentation { return Self.meetingPanelSize }
        return Self.panelSize
    }
    var waveformIsAnimated: Bool {
        guard !reduceMotionEnabled else { return false }
        switch presentation {
        case .dictation(let value): return value.level != nil
        case .meeting(let value): return value.isReceivingAudio
        case .hidden: return false
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let displaysProvider: @MainActor () -> [RecordingIslandDisplay]
    @ObservationIgnored private let mainDisplayIDProvider: @MainActor () -> String?
    @ObservationIgnored private let frontmostProcessProvider: @MainActor () -> pid_t?
    @ObservationIgnored private let focusPreservationHandler: @MainActor (Bool) -> Void
    @ObservationIgnored private let actionHandler: @MainActor (RecordingIslandAction) -> Void
    @ObservationIgnored private let microphoneSelectionHandler:
        @MainActor (MeetingMicrophoneSelection) -> Void
    @ObservationIgnored private let announcementHandler: (@MainActor (String) -> Void)?
    @ObservationIgnored private let reduceMotionProvider: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let panelPresentationHandler: @MainActor (RecordingIslandPanel) -> Void
    @ObservationIgnored private var autoHideTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var dictationStartedAt: Date?
    @ObservationIgnored private var lastAnnouncementIdentity: String?
    @ObservationIgnored private var isPositioningPanel = false

    init(
        defaults: UserDefaults = .standard,
        displaysProvider: @escaping @MainActor () -> [RecordingIslandDisplay] = {
            NSScreen.screens.compactMap(RecordingIslandController.display(for:))
        },
        mainDisplayIDProvider: @escaping @MainActor () -> String? = {
            NSScreen.main.flatMap(RecordingIslandController.display(for:))?.id
        },
        frontmostProcessProvider: @escaping @MainActor () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        focusPreservationHandler: @escaping @MainActor (Bool) -> Void = { _ in },
        actionHandler: @escaping @MainActor (RecordingIslandAction) -> Void = { _ in },
        microphoneSelectionHandler: @escaping @MainActor (MeetingMicrophoneSelection) -> Void = {
            _ in
        },
        announcementHandler: (@MainActor (String) -> Void)? = nil,
        reduceMotionProvider: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        panelPresentationHandler: @escaping @MainActor (RecordingIslandPanel) -> Void = { panel in
            panel.orderFrontRegardless()
        }
    ) {
        self.defaults = defaults
        self.displaysProvider = displaysProvider
        self.mainDisplayIDProvider = mainDisplayIDProvider
        self.frontmostProcessProvider = frontmostProcessProvider
        self.focusPreservationHandler = focusPreservationHandler
        self.actionHandler = actionHandler
        self.microphoneSelectionHandler = microphoneSelectionHandler
        self.announcementHandler = announcementHandler
        self.reduceMotionProvider = reduceMotionProvider
        self.sleep = sleep
        self.panelPresentationHandler = panelPresentationHandler
        self.reduceMotionEnabled = reduceMotionProvider()
        super.init()

        panel = makePanel()
        installObservers()
    }

    deinit {
        autoHideTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func updateDictation(
        _ state: DictationState,
        startedAt: Date? = nil,
        level: Float? = nil,
        shortcutDescription: String? = nil,
        isContinuous: Bool = false,
        now: Date = Date()
    ) {
        if case .meeting(let meeting) = presentation, meeting.phase != .saved { return }
        updateDictationPresentation(
            state,
            startedAt: startedAt,
            level: level,
            shortcutDescription: shortcutDescription,
            isContinuous: isContinuous,
            now: now
        )
    }

    private func updateDictationPresentation(
        _ state: DictationState,
        startedAt: Date?,
        level: Float?,
        shortcutDescription: String?,
        isContinuous: Bool,
        now: Date
    ) {
        switch state {
        case .idle:
            hideImmediately()
        case .listening:
            showDictation(
                .listening,
                startedAt: startedAt,
                level: level,
                shortcutDescription: shortcutDescription,
                isContinuous: isContinuous,
                now: now
            )
        case .locked:
            showDictation(
                .locked,
                startedAt: startedAt,
                level: level,
                shortcutDescription: shortcutDescription,
                isContinuous: isContinuous,
                now: now
            )
        case .transcribing:
            showDictation(
                .transcribing,
                startedAt: startedAt,
                level: level,
                shortcutDescription: shortcutDescription,
                isContinuous: isContinuous,
                now: now
            )
        case .unavailable(let reason):
            showDictation(
                .error,
                startedAt: startedAt,
                level: level,
                errorMessage: reason.title,
                shortcutDescription: shortcutDescription,
                isContinuous: isContinuous,
                now: now
            )
        case .failed(let failure):
            showDictation(
                .error,
                startedAt: startedAt,
                level: level,
                errorMessage: failure.title,
                shortcutDescription: shortcutDescription,
                isContinuous: isContinuous,
                now: now
            )
        }
    }

    func showDictation(
        _ phase: RecordingIslandDictationPhase,
        startedAt: Date? = nil,
        level: Float? = nil,
        errorMessage: String? = nil,
        shortcutDescription: String? = nil,
        isContinuous: Bool = false,
        now: Date = Date()
    ) {
        let start = startedAt ?? dictationStartedAt ?? now
        dictationStartedAt = start
        present(.dictation(RecordingIslandDictationPresentation(
            phase: phase,
            startedAt: start,
            level: level,
            errorMessage: errorMessage,
            shortcutDescription: shortcutDescription,
            isContinuous: isContinuous
        )))
    }

    /// VoxType reports success by becoming idle, so the adapter calls this
    /// first to retain a short, reassuring completion state.
    func dictationSucceeded(now: Date = Date()) {
        showDictation(.succeeded, startedAt: dictationStartedAt ?? now, now: now)
    }

    func updateMeeting(
        _ state: MeetingLifecycleState,
        meeting: MeetingRecord?,
        levels: [MeetingAudioSource: Float] = [:],
        histories: [MeetingAudioSource: [Float]] = [:],
        signalStates: [MeetingAudioSource: MeetingAudioSignalState] = [:],
        guidance: [MeetingAudioSource: String] = [:],
        latestTranscriptLine: String? = nil,
        microphone: RecordingIslandMicrophonePresentation? = nil,
        now: Date = Date()
    ) {
        guard let phase = RecordingIslandMeetingPhase(state) else {
            hideImmediately()
            return
        }
        let previous: RecordingIslandMeetingPresentation? = if case .meeting(let value) = presentation {
            value
        } else {
            nil
        }
        let record = meeting
        present(.meeting(RecordingIslandMeetingPresentation(
            phase: phase,
            title: record?.title ?? previous?.title ?? "Meeting",
            recordingKind: record?.recordingKind ?? previous?.recordingKind ?? .meeting,
            applicationName: record?.detectedApplication ?? previous?.applicationName,
            startedAt: record?.startedAt ?? previous?.startedAt ?? now,
            microphone: microphone ?? previous?.microphone,
            microphoneLevel: levels[.microphone],
            systemLevel: levels[.system],
            microphoneHistory: histories[.microphone] ?? [],
            systemHistory: histories[.system] ?? [],
            microphoneSignalState: signalStates[.microphone],
            systemSignalState: signalStates[.system],
            latestTranscriptLine: latestTranscriptLine ?? previous?.latestTranscriptLine,
            guidance: guidance[.microphone] ?? guidance[.system]
        )))
    }

    func meetingSaved(_ meeting: MeetingRecord) {
        present(.meeting(RecordingIslandMeetingPresentation(
            phase: .saved,
            title: meeting.title,
            recordingKind: meeting.recordingKind,
            applicationName: meeting.detectedApplication,
            startedAt: meeting.startedAt
        )))
    }

    func present(_ next: RecordingIslandPresentation) {
        autoHideTask?.cancel()
        autoHideTask = nil
        presentation = next

        if case .hidden = next {
            dictationStartedAt = nil
            lastAnnouncementIdentity = nil
            panel.orderOut(nil)
            return
        }

        resizePanel(to: presentationSize)
        positionForCurrentDisplays()
        let focusedProcess = frontmostProcessProvider()
        isPositioningPanel = true
        panelPresentationHandler(panel)
        isPositioningPanel = false
        // AppKit may constrain a hidden panel to the runner's physical screen
        // when it first becomes visible. Reapply the injected/persisted display
        // position after ordering so that transient AppKit geometry cannot
        // become the user's saved position.
        positionForCurrentDisplays()
        focusPreservationHandler(focusedProcess == frontmostProcessProvider())
        announceTransitionIfNeeded(next)

        if case .dictation(let value) = next, value.phase == .succeeded {
            let expected = next
            autoHideTask = Task { @MainActor [weak self, sleep] in
                await sleep(Self.autoHideDelay)
                guard !Task.isCancelled, self?.presentation == expected else { return }
                self?.hideImmediately()
            }
        } else if case .meeting(let value) = next, value.phase == .saved {
            let expected = next
            autoHideTask = Task { @MainActor [weak self, sleep] in
                await sleep(Self.meetingSavedAutoHideDelay)
                guard !Task.isCancelled, self?.presentation == expected else { return }
                self?.hideImmediately()
            }
        }
    }

    func hideImmediately() {
        present(.hidden)
    }

    func perform(_ action: RecordingIslandAction) {
        guard controls.contains(action) else { return }
        actionHandler(action)
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) {
        guard case .meeting(let value) = presentation,
              let microphone = value.microphone,
              [.chooseMicrophone, .recording, .paused, .stopSuggested].contains(value.phase),
              !microphone.switchState.isSwitching,
              selection != microphone.selectedPreference,
              microphone.contains(selection) else { return }
        microphoneSelectionHandler(selection)
    }

    /// Ignoring a suggestion is deliberately equivalent only to keeping the
    /// recording. It can never dispatch Stop.
    func dismissStopSuggestion() {
        guard case .meeting(var value) = presentation,
              value.phase == .stopSuggested else { return }
        value.phase = .recording
        present(.meeting(value))
        actionHandler(.keepRecording)
    }

    func refreshReduceMotion() {
        reduceMotionEnabled = reduceMotionProvider()
        panel.animationBehavior = reduceMotionEnabled ? .none : .utilityWindow
    }

    func move(to origin: CGPoint, on displayID: String) {
        guard let display = displaysProvider().first(where: { $0.id == displayID }) else { return }
        setPanelOrigin(Self.clampedOrigin(
            origin,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        ))
        currentDisplayID = display.id
        persist(panel.frame.origin, for: display.id)
    }

    func reconcileDisplays() {
        let displays = displaysProvider()
        guard !displays.isEmpty else {
            panel.orderOut(nil)
            currentDisplayID = nil
            return
        }

        let display = currentDisplayID.flatMap { id in
            displays.first(where: { $0.id == id })
        } ?? preferredDisplay(from: displays)
        currentDisplayID = display.id

        let requested = persistedOrigin(for: display.id) ?? panel.frame.origin
        let origin = Self.clampedOrigin(
            requested,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        )
        setPanelOrigin(origin)
        persist(origin, for: display.id)
    }

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, !isPositioningPanel else { return }
        let displays = displaysProvider()
        guard let display = displayContainingPanelCenter(from: displays) else { return }
        currentDisplayID = display.id
        let origin = Self.clampedOrigin(
            panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        )
        if origin != panel.frame.origin { setPanelOrigin(origin) }
        persist(origin, for: display.id)
    }

    static func clampedOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = screenMargin
    ) -> CGPoint {
        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - margin)
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - margin)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    static func defaultOrigin(
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = screenMargin
    ) -> CGPoint {
        clampedOrigin(
            CGPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - margin
            ),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            margin: margin
        )
    }

    private func makePanel() -> RecordingIslandPanel {
        let panel = RecordingIslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.animationBehavior = reduceMotionEnabled ? .none : .utilityWindow
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RecordingIslandView(controller: self))
        return panel
    }

    private func resizePanel(to size: CGSize) {
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = size
        frame.origin.y = topEdge - size.height
        panel.setFrame(frame, display: false)
    }

    private func installObservers() {
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileDisplays() }
        }
        notificationObservers.append(screenObserver)

        let accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReduceMotion() }
        }
        notificationObservers.append(accessibilityObserver)
    }

    private func positionForCurrentDisplays() {
        let displays = displaysProvider()
        guard !displays.isEmpty else { return }

        let display = currentDisplayID.flatMap { id in
            displays.first(where: { $0.id == id })
        } ?? preferredDisplay(from: displays)
        currentDisplayID = display.id
        let origin = persistedOrigin(for: display.id) ?? Self.defaultOrigin(
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        )
        let clamped = Self.clampedOrigin(
            origin,
            panelSize: panel.frame.size,
            visibleFrame: display.visibleFrame
        )
        setPanelOrigin(clamped)
        persist(clamped, for: display.id)
    }

    private func preferredDisplay(from displays: [RecordingIslandDisplay]) -> RecordingIslandDisplay {
        if let mainID = mainDisplayIDProvider(),
           let main = displays.first(where: { $0.id == mainID }) {
            return main
        }
        return displays[0]
    }

    private func displayContainingPanelCenter(
        from displays: [RecordingIslandDisplay]
    ) -> RecordingIslandDisplay? {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return displays.first(where: { $0.visibleFrame.contains(center) })
            ?? currentDisplayID.flatMap { id in displays.first(where: { $0.id == id }) }
            ?? displays.first
    }

    private func setPanelOrigin(_ origin: CGPoint) {
        isPositioningPanel = true
        panel.setFrameOrigin(origin)
        isPositioningPanel = false
    }

    private func persistedOrigin(for displayID: String) -> CGPoint? {
        guard let values = defaults.dictionary(forKey: Self.persistedPositionsDefaultsKey)?[displayID]
            as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private func persist(_ origin: CGPoint, for displayID: String) {
        var positions = defaults.dictionary(forKey: Self.persistedPositionsDefaultsKey) ?? [:]
        positions[displayID] = [Double(origin.x), Double(origin.y)]
        defaults.set(positions, forKey: Self.persistedPositionsDefaultsKey)
    }

    private func announceTransitionIfNeeded(_ next: RecordingIslandPresentation) {
        guard let identity = next.announcementIdentity,
              identity != lastAnnouncementIdentity,
              let announcement = next.announcement else { return }
        lastAnnouncementIdentity = identity

        if let announcementHandler {
            announcementHandler(announcement)
            return
        }
        NSAccessibility.post(
            element: panel as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private static func display(for screen: NSScreen) -> RecordingIslandDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber else { return nil }
        return RecordingIslandDisplay(
            id: number.stringValue,
            visibleFrame: screen.visibleFrame
        )
    }
}

private extension RecordingIslandMeetingPhase {
    init?(_ lifecycle: MeetingLifecycleState) {
        switch lifecycle {
        case .starting: self = .starting
        case .sourceSelectionRequired: self = .chooseMicrophone
        case .recording: self = .recording
        case .paused: self = .paused
        case .stopSuggested: self = .stopSuggested
        case .finalizing: self = .finalizing
        case .idle, .startSuggested, .completed, .failed: return nil
        }
    }
}
