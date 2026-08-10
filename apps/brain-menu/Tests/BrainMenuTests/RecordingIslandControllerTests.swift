import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct RecordingIslandControllerTests {
    private let mainDisplay = RecordingIslandDisplay(
        id: "main",
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )
    private let externalDisplay = RecordingIslandDisplay(
        id: "external",
        visibleFrame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)
    )

    @Test
    func dictationIslandUsesTheCompactPanelSize() throws {
        let controller = makeController(defaults: try testDefaults())
        #expect(RecordingIslandController.panelSize.width <= 480)
        #expect(RecordingIslandController.panelSize.height <= 142)

        controller.showDictation(.listening)
        #expect(controller.panel.frame.size == RecordingIslandController.panelSize)
        guard case .dictation(let presentation) = controller.presentation else {
            Issue.record("Expected dictation presentation")
            return
        }
        #expect(presentation.phase == .listening)
        #expect(controller.controls == [.cancel])
        #expect(!controller.panel.canBecomeKey)
        controller.hideImmediately()
    }

    @Test
    func panelIsNonactivatingBorderlessAndPreservesThePasteTargetFocus() throws {
        let defaults = try testDefaults()
        var focusResults: [Bool] = []
        let controller = makeController(
            defaults: defaults,
            frontmostProcessProvider: { 42 },
            focusPreservationHandler: { focusResults.append($0) }
        )

        #expect(controller.panel.styleMask.contains(.borderless))
        #expect(controller.panel.styleMask.contains(.nonactivatingPanel))
        #expect(controller.panel.level == .floating)
        #expect(controller.panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(controller.panel.collectionBehavior.contains(.ignoresCycle))
        #expect(controller.panel.isMovableByWindowBackground)
        #expect(controller.panel.isExcludedFromWindowsMenu)
        #expect(!controller.panel.canBecomeKey)
        #expect(!controller.panel.canBecomeMain)

        controller.showDictation(.listening, now: Date(timeIntervalSince1970: 100))

        #expect(focusResults == [true])
        #expect(!controller.panel.isKeyWindow)
        #expect(!controller.panel.isMainWindow)
        controller.hideImmediately()
    }

    @Test
    func dictationAndMeetingStatesExposeOnlyValidControls() throws {
        let controller = makeController(defaults: try testDefaults())
        let start = Date(timeIntervalSince1970: 1_000)

        controller.showDictation(.listening, startedAt: start, level: 0.5)
        #expect(controller.controls == [.cancel])
        controller.showDictation(.locked, startedAt: start)
        #expect(controller.controls == [.cancel])
        controller.showDictation(.locked, startedAt: start, isContinuous: true)
        #expect(controller.controls == [.stop])
        controller.showDictation(.transcribing, startedAt: start)
        #expect(controller.controls.isEmpty)
        controller.showDictation(.error, startedAt: start, errorMessage: "Try again")
        #expect(controller.controls.isEmpty)

        controller.present(.meeting(meeting(.recording, startedAt: start)))
        #expect(controller.controls == [.pause, .stop])
        controller.present(.meeting(meeting(.paused, startedAt: start)))
        #expect(controller.controls == [.resume, .stop])
        controller.present(.meeting(meeting(.finalizing, startedAt: start)))
        #expect(controller.controls.isEmpty)

        controller.updateMeeting(.completed, meeting: nil)
        #expect(controller.presentation == .hidden)
        #expect(!controller.isVisible)
    }

    @Test
    func meetingWaveformsTrackIndependentActivityAndDoNotRetainClearedGuidance() throws {
        let controller = makeController(defaults: try testDefaults())
        let record = MeetingRecord(
            title: "Audio check",
            startedAt: Date(timeIntervalSince1970: 1_000),
            lifecycleState: .recording,
            speechEngine: "parakeet",
            speechModel: "model"
        )

        controller.updateMeeting(
            .recording,
            meeting: record,
            levels: [.microphone: 0, .system: 0.55],
            histories: [.microphone: [0, 0], .system: [0.2, 0.55]],
            signalStates: [.microphone: .quiet, .system: .active],
            guidance: [.microphone: "Check microphone"]
        )
        guard case .meeting(let active) = controller.presentation else {
            Issue.record("Expected meeting presentation")
            return
        }
        #expect(active.microphoneSignalState == .quiet)
        #expect(active.systemSignalState == .active)
        #expect(active.microphoneHistory == [0, 0])
        #expect(active.systemHistory == [0.2, 0.55])
        #expect(active.isReceivingAudio)
        #expect(active.audioStatusText == "Receiving computer audio…")
        #expect(controller.panel.frame.size == RecordingIslandController.meetingPanelSize)
        #expect(controller.waveformIsAnimated)
        #expect(active.guidance == "Check microphone")

        controller.updateMeeting(
            .recording,
            meeting: record,
            levels: [.microphone: 0, .system: 0],
            histories: [.microphone: [0], .system: [0]],
            signalStates: [.microphone: .quiet, .system: .quiet],
            guidance: [:]
        )
        guard case .meeting(let quiet) = controller.presentation else {
            Issue.record("Expected quiet meeting presentation")
            return
        }
        #expect(!quiet.isReceivingAudio)
        #expect(quiet.audioStatusText == "Connected — waiting for sound…")
        #expect(quiet.guidance == nil)
        #expect(!controller.waveformIsAnimated)

        controller.updateMeeting(.recording, meeting: record)
        guard case .meeting(let cleared) = controller.presentation else {
            Issue.record("Expected cleared meeting presentation")
            return
        }
        #expect(cleared.microphoneLevel == nil)
        #expect(cleared.systemLevel == nil)
        #expect(cleared.microphoneHistory.isEmpty)
        #expect(cleared.systemHistory.isEmpty)
        #expect(cleared.microphoneSignalState == .waiting)
        #expect(cleared.systemSignalState == .waiting)
        #expect(cleared.guidance == nil)
        #expect(cleared.audioStatusText == "Waiting for audio…")

        controller.hideImmediately()
        controller.showDictation(.listening)
        #expect(controller.panel.frame.size == RecordingIslandController.panelSize)
    }

    @Test
    func meetingMicrophonePresentationIdentifiesActiveDefaultAndSwitchStatus() {
        let builtIn = microphoneDevice(
            uid: "built-in",
            name: "MacBook Pro Microphone",
            coreAudioID: 7,
            isSystemDefault: true
        )
        let desk = microphoneDevice(
            uid: "desk",
            name: "Desk Microphone",
            coreAudioID: 11
        )
        var presentation = RecordingIslandMicrophonePresentation(
            activeDevice: builtIn,
            availableDevices: [builtIn, desk],
            selectedPreference: .systemDefault
        )

        #expect(presentation.activeDeviceName == "MacBook Pro Microphone")
        #expect(presentation.defaultDevice == builtIn)
        #expect(presentation.deviceName(for: .systemDefault) == "MacBook Pro Microphone")
        #expect(presentation.deviceName(for: .device(uid: "desk")) == "Desk Microphone")
        #expect(presentation.contains(.device(uid: "missing")) == false)
        #expect(presentation.accessibilityValue == "MacBook Pro Microphone")

        presentation.switchState = .switching(to: .device(uid: "desk"))
        #expect(presentation.switchState.isSwitching)
        #expect(presentation.accessibilityValue.contains("Switching to Desk Microphone"))

        presentation.switchState = .failed(message: "Desk Microphone stopped responding.")
        #expect(!presentation.switchState.isSwitching)
        #expect(presentation.switchErrorMessage == "Desk Microphone stopped responding.")
        #expect(presentation.accessibilityValue.contains("Microphone change failed"))
    }

    @Test
    func microphonePickerDispatchesOnlyAvailableChangesInMutableMeetingPhases() throws {
        var selections: [MeetingMicrophoneSelection] = []
        let controller = makeController(
            defaults: try testDefaults(),
            microphoneSelectionHandler: { selections.append($0) }
        )
        let builtIn = microphoneDevice(
            uid: "built-in",
            name: "MacBook Pro Microphone",
            coreAudioID: 7,
            isSystemDefault: true
        )
        let desk = microphoneDevice(
            uid: "desk",
            name: "Desk Microphone",
            coreAudioID: 11
        )
        let ready = RecordingIslandMicrophonePresentation(
            activeDevice: builtIn,
            availableDevices: [builtIn, desk],
            selectedPreference: .systemDefault
        )

        controller.updateMeeting(
            .recording,
            meeting: nil,
            microphone: ready
        )
        controller.selectMicrophone(.systemDefault)
        controller.selectMicrophone(.device(uid: "missing"))
        controller.selectMicrophone(.device(uid: "desk"))
        #expect(selections == [.device(uid: "desk")])

        var switching = ready
        switching.switchState = .switching(to: .device(uid: "desk"))
        controller.updateMeeting(
            .recording,
            meeting: nil,
            microphone: switching
        )
        controller.selectMicrophone(.device(uid: "desk"))
        #expect(selections == [.device(uid: "desk")])

        var retryable = ready
        retryable.switchState = .failed(message: "Try another microphone.")
        controller.updateMeeting(
            .paused,
            meeting: nil,
            microphone: retryable
        )
        controller.selectMicrophone(.device(uid: "desk"))
        #expect(selections == [.device(uid: "desk"), .device(uid: "desk")])

        controller.updateMeeting(
            .finalizing,
            meeting: nil,
            microphone: ready
        )
        controller.selectMicrophone(.device(uid: "desk"))
        #expect(selections == [.device(uid: "desk"), .device(uid: "desk")])

        var unavailable = ready
        unavailable.activeDevice = nil
        unavailable.selectedPreference = .device(uid: "disconnected")
        unavailable.switchState = .failed(message: "Choose a different microphone.")
        let voiceNote = MeetingRecord(
            title: "Voice note",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(),
            lifecycleState: .sourceSelectionRequired,
            speechEngine: "whisper",
            speechModel: "model"
        )
        controller.updateMeeting(
            .sourceSelectionRequired,
            meeting: voiceNote,
            guidance: [.microphone: "Choose a different microphone, then start again."],
            microphone: unavailable
        )
        guard case .meeting(let prompt) = controller.presentation else {
            Issue.record("Expected the microphone selection prompt to remain visible")
            return
        }
        #expect(prompt.phase == .chooseMicrophone)
        #expect(prompt.audioStatusText == "Choose another microphone, then start again.")
        #expect(prompt.guidance == "Choose a different microphone, then start again.")
        #expect(controller.isVisible)

        try renderEvidence(
            RecordingIslandView(controller: controller),
            named: "missing-microphone-recovery.png"
        )

        controller.selectMicrophone(.device(uid: "desk"))
        #expect(selections == [
            .device(uid: "desk"),
            .device(uid: "desk"),
            .device(uid: "desk"),
        ])
    }

    @Test
    func audioUpdatesPreserveTheLatestMicrophonePresentationWhenItIsOmitted() throws {
        let controller = makeController(defaults: try testDefaults())
        let builtIn = microphoneDevice(
            uid: "built-in",
            name: "MacBook Pro Microphone",
            coreAudioID: 7,
            isSystemDefault: true
        )
        let microphone = RecordingIslandMicrophonePresentation(
            activeDevice: builtIn,
            availableDevices: [builtIn],
            selectedPreference: .systemDefault
        )

        controller.updateMeeting(
            .recording,
            meeting: nil,
            levels: [.microphone: 0.2],
            microphone: microphone
        )
        controller.updateMeeting(
            .recording,
            meeting: nil,
            levels: [.microphone: 0.8]
        )

        guard case .meeting(let updated) = controller.presentation else {
            Issue.record("Expected meeting presentation")
            return
        }
        #expect(updated.microphone == microphone)
        #expect(updated.microphoneLevel == 0.8)
    }

    @Test
    func stopSuggestionNeverStopsUnlessStopIsExplicitlyChosen() throws {
        var actions: [RecordingIslandAction] = []
        let controller = makeController(
            defaults: try testDefaults(),
            actionHandler: { actions.append($0) }
        )
        let suggestion = RecordingIslandPresentation.meeting(meeting(
            .stopSuggested,
            startedAt: Date(timeIntervalSince1970: 1_000)
        ))

        controller.present(suggestion)
        #expect(controller.controls == [.stop, .keepRecording])
        #expect(actions.isEmpty)

        // Time passing and repeated detector updates have no implicit action.
        controller.present(suggestion)
        #expect(actions.isEmpty)

        controller.dismissStopSuggestion()
        #expect(actions == [.keepRecording])
        #expect(!actions.contains(.stop))
        #expect(controller.controls == [.pause, .stop])

        controller.present(suggestion)
        controller.perform(.stop)
        #expect(actions == [.keepRecording, .stop])
    }

    @Test
    func meetingAudioFramesReplaceTheWaitingMessageBeforeTranscriptPreview() throws {
        let controller = makeController(defaults: try testDefaults())

        controller.updateMeeting(
            .recording,
            meeting: nil,
            levels: [.microphone: 0.4],
            signalStates: [.microphone: .active]
        )

        guard case .meeting(let meeting) = controller.presentation else {
            Issue.record("Expected an active meeting presentation")
            return
        }
        #expect(meeting.latestTranscriptLine == nil)
        #expect(meeting.audioStatusText == "Receiving microphone audio…")
    }

    @Test
    func idleHidesImmediatelyAndSuccessHidesAfterExactlyTwoSeconds() async throws {
        var slept: [Duration] = []
        let controller = makeController(
            defaults: try testDefaults(),
            sleep: { duration in slept.append(duration) }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        controller.showDictation(.listening, startedAt: start)
        controller.updateDictation(.idle)
        #expect(controller.presentation == .hidden)

        controller.showDictation(.listening, startedAt: start)
        controller.dictationSucceeded()
        #expect(controller.isVisible)
        await Task.yield()
        await Task.yield()

        #expect(slept == [RecordingIslandController.autoHideDelay])
        #expect(RecordingIslandController.autoHideDelay == .seconds(2))
        #expect(controller.presentation == .hidden)
    }

    @Test
    func savedMeetingAnnouncesTopOfListAndAutoHidesAfterFiveSeconds() async throws {
        var slept: [Duration] = []
        var announcements: [String] = []
        let controller = makeController(
            defaults: try testDefaults(),
            announcementHandler: { announcements.append($0) },
            sleep: { duration in slept.append(duration) }
        )
        let record = MeetingRecord(
            title: "Audio capture reliability",
            titleSource: .analysis,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_100),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "model"
        )

        controller.meetingSaved(record)
        guard case .meeting(let saved) = controller.presentation else {
            Issue.record("Expected a visible meeting-saved notification")
            return
        }
        #expect(saved.phase == .saved)
        #expect(saved.audioStatusText.contains("top of the list"))
        #expect(controller.panel.frame.size == RecordingIslandController.meetingPanelSize)
        #expect(announcements == [
            "Meeting added. Audio capture reliability. It is now at the top of Meetings.",
        ])
        await Task.yield()
        await Task.yield()
        #expect(slept == [RecordingIslandController.meetingSavedAutoHideDelay])
        #expect(controller.presentation == .hidden)
    }

    @Test
    func savedVoiceNotePointsToTheVoiceNotesLibrary() throws {
        var announcements: [String] = []
        let controller = makeController(
            defaults: try testDefaults(),
            announcementHandler: { announcements.append($0) },
            sleep: { _ in }
        )
        let record = MeetingRecord(
            title: "Field note",
            recordingKind: .voiceNote,
            titleSource: .manual,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_100),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "model"
        )

        controller.meetingSaved(record)

        guard case .meeting(let saved) = controller.presentation else {
            Issue.record("Expected a visible voice-note-saved notification")
            return
        }
        #expect(saved.isVoiceNote)
        #expect(saved.phaseTitle == "Voice note added")
        #expect(saved.audioStatusText.contains("Voice Notes"))
        #expect(announcements == [
            "Voice note added. Field note. It is now at the top of Voice Notes.",
        ])
    }

    @Test
    func activeVoiceNoteReportsOnlyItsMicrophoneState() {
        let voiceNote = RecordingIslandMeetingPresentation(
            phase: .recording,
            title: "Voice note",
            recordingKind: .voiceNote,
            startedAt: Date(timeIntervalSince1970: 1_000),
            microphoneSignalState: .waiting,
            systemSignalState: .active
        )

        #expect(!voiceNote.isReceivingAudio)
        #expect(voiceNote.audioStatusText == "Waiting for microphone audio…")
    }

    @Test
    func positionsPersistPerDisplayClampAndRecoverAfterDisplayRemoval() throws {
        let defaults = try testDefaults()
        let environment = RecordingIslandTestEnvironment(
            displays: [mainDisplay, externalDisplay],
            mainDisplayID: "main"
        )
        let controller = makeController(
            defaults: defaults,
            displaysProvider: { environment.displays },
            mainDisplayIDProvider: { environment.mainDisplayID }
        )
        controller.showDictation(.listening)

        let expectedDefault = RecordingIslandController.defaultOrigin(
            panelSize: RecordingIslandController.panelSize,
            visibleFrame: mainDisplay.visibleFrame
        )
        #expect(controller.currentDisplayID == "main")
        #expect(controller.panel.frame.origin == expectedDefault)
        #expect(controller.panel.frame.maxY <= mainDisplay.visibleFrame.maxY)

        let savedMain = CGPoint(x: 120, y: 400)
        controller.move(to: savedMain, on: "main")
        #expect(controller.panel.frame.origin == savedMain)

        controller.move(to: CGPoint(x: 99_999, y: -99_999), on: "external")
        let savedExternal = RecordingIslandController.clampedOrigin(
            CGPoint(x: 99_999, y: -99_999),
            panelSize: RecordingIslandController.panelSize,
            visibleFrame: externalDisplay.visibleFrame
        )
        #expect(controller.panel.frame.origin == savedExternal)

        environment.mainDisplayID = "external"
        let restoredExternal = makeController(
            defaults: defaults,
            displaysProvider: { environment.displays },
            mainDisplayIDProvider: { environment.mainDisplayID }
        )
        restoredExternal.showDictation(.listening)
        #expect(restoredExternal.panel.frame.origin == savedExternal)

        // Removing the active display picks the main display and restores its
        // own position rather than retaining off-screen coordinates.
        environment.displays = [mainDisplay]
        environment.mainDisplayID = "main"
        restoredExternal.reconcileDisplays()
        #expect(restoredExternal.currentDisplayID == "main")
        #expect(restoredExternal.panel.frame.origin == savedMain)

        // A resolution change re-clamps the saved position into the new frame.
        let smallerMain = RecordingIslandDisplay(
            id: "main",
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500)
        )
        environment.displays = [smallerMain]
        restoredExternal.move(to: CGPoint(x: 700, y: 450), on: "main")
        #expect(restoredExternal.panel.frame.maxX <= smallerMain.visibleFrame.maxX)
        #expect(restoredExternal.panel.frame.maxY <= smallerMain.visibleFrame.maxY)
        #expect(restoredExternal.panel.frame.minX >= smallerMain.visibleFrame.minX)
        #expect(restoredExternal.panel.frame.minY >= smallerMain.visibleFrame.minY)
    }

    @Test
    func preShowWindowMoveCannotOverrideDefaultOrigin() throws {
        let defaults = try testDefaults()
        let appKitAdjustedOrigin = CGPoint(x: 490, y: 561)
        let controllerReference = RecordingIslandControllerReference()
        let controller = makeController(
            defaults: defaults,
            displaysProvider: { [mainDisplay] },
            mainDisplayIDProvider: { "main" },
            panelPresentationHandler: { panel in
                // Simulate AppKit adjusting the frame during presentation
                // without coupling this unit test to the runner's physical
                // display geometry.
                panel.setFrameOrigin(appKitAdjustedOrigin)
                controllerReference.value?.windowDidMove(Notification(
                    name: NSWindow.didMoveNotification,
                    object: panel
                ))
            }
        )
        controllerReference.value = controller

        controller.windowDidMove(Notification(
            name: NSWindow.didMoveNotification,
            object: controller.panel
        ))

        #expect(controller.currentDisplayID == nil)
        #expect(defaults.dictionary(
            forKey: RecordingIslandController.persistedPositionsDefaultsKey
        ) == nil)

        controller.showDictation(.listening)

        let expectedDefault = RecordingIslandController.defaultOrigin(
            panelSize: RecordingIslandController.panelSize,
            visibleFrame: mainDisplay.visibleFrame
        )
        #expect(controller.currentDisplayID == "main")
        #expect(controller.panel.frame.origin == expectedDefault)
        controller.hideImmediately()
    }

    @Test
    func announcementsAreDeduplicatedAndReduceMotionDisablesWaveforms() throws {
        var announcements: [String] = []
        let environment = RecordingIslandTestEnvironment(
            displays: [mainDisplay, externalDisplay],
            mainDisplayID: "main"
        )
        let controller = makeController(
            defaults: try testDefaults(),
            announcementHandler: { announcements.append($0) },
            reduceMotionProvider: { environment.reduceMotion }
        )
        let start = Date(timeIntervalSince1970: 1_000)

        controller.showDictation(.listening, startedAt: start, level: 0.2)
        controller.showDictation(.listening, startedAt: start, level: 0.8)
        #expect(announcements == ["Dictation listening."])
        #expect(controller.waveformIsAnimated)

        controller.showDictation(.locked, startedAt: start, level: 0.8)
        #expect(announcements == ["Dictation listening.", "Dictation locked."])

        let recording = RecordingIslandPresentation.meeting(meeting(
            .recording,
            startedAt: start,
            microphoneLevel: 0.4,
            systemLevel: 0.7,
            transcript: "One"
        ))
        controller.present(recording)
        controller.present(.meeting(meeting(
            .recording,
            startedAt: start,
            microphoneLevel: 0.8,
            systemLevel: 0.3,
            transcript: "Two"
        )))
        #expect(announcements.last == "Meeting recording.")
        #expect(announcements.filter { $0 == "Meeting recording." }.count == 1)

        environment.reduceMotion = true
        controller.refreshReduceMotion()
        #expect(controller.reduceMotionEnabled)
        #expect(!controller.waveformIsAnimated)
        #expect(controller.panel.animationBehavior == .none)
    }

    @Test
    func dictationShowsReadOnlyVoxTypeShortcutWithoutReplacingAnActiveMeeting() throws {
        var actions: [RecordingIslandAction] = []
        let controller = makeController(
            defaults: try testDefaults(),
            actionHandler: { actions.append($0) }
        )

        controller.updateDictation(
            .listening,
            shortcutDescription: "Control+Fn (push-to-talk)"
        )
        guard case .dictation(let dictation) = controller.presentation else {
            Issue.record("Expected dictation presentation")
            return
        }
        #expect(dictation.shortcutDescription == "Control+Fn (push-to-talk)")
        controller.perform(.cancel)
        #expect(actions == [.cancel])
        guard case .dictation(let unchanged) = controller.presentation else {
            Issue.record("Shortcut action unexpectedly replaced dictation")
            return
        }
        #expect(unchanged.shortcutDescription == "Control+Fn (push-to-talk)")

        controller.present(.meeting(meeting(
            .recording,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )))
        controller.updateDictation(
            .transcribing,
            shortcutDescription: "Fn (toggle)"
        )
        guard case .meeting(let activeMeeting) = controller.presentation else {
            Issue.record("Dictation replaced an active meeting")
            return
        }
        #expect(activeMeeting.phase == .recording)

        controller.updateMeeting(.completed, meeting: nil)
        controller.updateDictation(
            .listening,
            shortcutDescription: "Fn (toggle)"
        )
        guard case .dictation(let afterMeeting) = controller.presentation else {
            Issue.record("Later dictation did not resume after the meeting")
            return
        }
        #expect(afterMeeting.shortcutDescription == "Fn (toggle)")
    }

    private func meeting(
        _ phase: RecordingIslandMeetingPhase,
        startedAt: Date,
        microphoneLevel: Float? = nil,
        systemLevel: Float? = nil,
        transcript: String? = nil
    ) -> RecordingIslandMeetingPresentation {
        RecordingIslandMeetingPresentation(
            phase: phase,
            title: "Weekly planning",
            applicationName: "Zoom",
            startedAt: startedAt,
            microphoneLevel: microphoneLevel,
            systemLevel: systemLevel,
            latestTranscriptLine: transcript
        )
    }

    private func makeController(
        defaults: UserDefaults,
        displaysProvider: @escaping @MainActor () -> [RecordingIslandDisplay]? = { nil },
        mainDisplayIDProvider: @escaping @MainActor () -> String? = { nil },
        frontmostProcessProvider: @escaping @MainActor () -> pid_t? = { 42 },
        focusPreservationHandler: @escaping @MainActor (Bool) -> Void = { _ in },
        actionHandler: @escaping @MainActor (RecordingIslandAction) -> Void = { _ in },
        microphoneSelectionHandler: @escaping @MainActor (MeetingMicrophoneSelection) -> Void = {
            _ in
        },
        announcementHandler: (@MainActor (String) -> Void)? = { _ in },
        reduceMotionProvider: @escaping @MainActor () -> Bool = { false },
        sleep: @escaping @MainActor (Duration) async -> Void = { _ in },
        // Tests use synthetic display frames, so ordering a real AppKit panel
        // would make the runner constrain it to unrelated physical screens.
        panelPresentationHandler: @escaping @MainActor (RecordingIslandPanel) -> Void = { _ in }
    ) -> RecordingIslandController {
        let fallbackDisplays = [mainDisplay, externalDisplay]
        return RecordingIslandController(
            defaults: defaults,
            displaysProvider: { displaysProvider() ?? fallbackDisplays },
            mainDisplayIDProvider: { mainDisplayIDProvider() ?? "main" },
            frontmostProcessProvider: frontmostProcessProvider,
            focusPreservationHandler: focusPreservationHandler,
            actionHandler: actionHandler,
            microphoneSelectionHandler: microphoneSelectionHandler,
            announcementHandler: announcementHandler,
            reduceMotionProvider: reduceMotionProvider,
            sleep: sleep,
            panelPresentationHandler: panelPresentationHandler
        )
    }

    private func renderEvidence<V: View>(_ view: V, named filename: String) throws {
        let size = RecordingIslandController.meetingPanelSize
        let hostingView = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Note microphone recovery"
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

    private func microphoneDevice(
        uid: String,
        name: String,
        coreAudioID: UInt32,
        isSystemDefault: Bool = false
    ) -> MeetingMicrophoneDevice {
        MeetingMicrophoneDevice(
            id: uid,
            name: name,
            coreAudioID: coreAudioID,
            isSystemDefault: isSystemDefault
        )
    }

    private func testDefaults() throws -> UserDefaults {
        let suite = "RecordingIslandControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class RecordingIslandTestEnvironment {
    var displays: [RecordingIslandDisplay]
    var mainDisplayID: String
    var reduceMotion = false

    init(displays: [RecordingIslandDisplay], mainDisplayID: String) {
        self.displays = displays
        self.mainDisplayID = mainDisplayID
    }
}

@MainActor
private final class RecordingIslandControllerReference {
    weak var value: RecordingIslandController?
}
