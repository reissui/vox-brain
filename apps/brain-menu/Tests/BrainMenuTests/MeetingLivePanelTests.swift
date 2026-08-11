import AppKit
import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct MeetingLivePanelTests {
    @Test
    func normalMeetingAutoShowsWithoutApplicationActivation() throws {
        var presentationCount = 0
        let fixture = try makeFixture { _ in presentationCount += 1 }

        fixture.panel.beginSession(
            transcriptController: fixture.firstTranscript,
            recordingKind: .meeting
        )

        #expect(presentationCount == 1)
        #expect(fixture.panel.isPresented)
        #expect(fixture.dashboard.transcriptController === fixture.firstTranscript)

        let source = try String(contentsOf: panelSourceURL, encoding: .utf8)
        #expect(!source.contains("NSApp.activate"))
        #expect(!source.contains("NSApplication.shared.activate"))
        fixture.panel.hide()
    }

    @Test
    func closeHidesWithoutStoppingOrDetachingTheSession() throws {
        let fixture = try makeFixture()
        fixture.panel.beginSession(
            transcriptController: fixture.firstTranscript,
            recordingKind: .meeting
        )

        let shouldClose = fixture.panel.windowShouldClose(fixture.panel.panel)

        #expect(!shouldClose)
        #expect(!fixture.panel.isPresented)
        #expect(fixture.dashboard.transcriptController === fixture.firstTranscript)
        #expect(fixture.recorder.stopCount == 0)
        #expect(fixture.recorder.cancelCount == 0)
    }

    @Test
    func panelHasPersistentFloatingKeyCapableWindowContract() throws {
        let fixture = try makeFixture()
        let panel = fixture.panel.panel!

        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.level == .floating)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.minSize == CGSize(width: 560, height: 480))
        #expect(panel.frameAutosaveName == "BrainMeetingLivePanel")
        #expect(panel.delegate === fixture.panel)
    }

    @Test
    func aNewSessionReplacesTheDashboardTranscriptInTheSamePanel() throws {
        let fixture = try makeFixture()
        let originalPanel = fixture.panel.panel
        let replacement = try makeTranscript("replacement")

        fixture.panel.beginSession(
            transcriptController: fixture.firstTranscript,
            recordingKind: .meeting
        )
        fixture.panel.beginSession(
            transcriptController: replacement,
            recordingKind: .meeting
        )

        #expect(fixture.panel.panel === originalPanel)
        #expect(fixture.dashboard.transcriptController === replacement)
        #expect(fixture.panel.isPresented)
        fixture.panel.hide()
    }

    @Test
    func voiceNotesNeverAttachOrAutoShowTheDashboard() throws {
        var presentationCount = 0
        let fixture = try makeFixture { _ in presentationCount += 1 }

        fixture.panel.beginSession(
            transcriptController: fixture.firstTranscript,
            recordingKind: .voiceNote
        )

        #expect(presentationCount == 0)
        #expect(!fixture.panel.isPresented)
        #expect(fixture.dashboard.transcriptController == nil)
    }

    @Test
    func islandExplicitlyReopensTheSameSessionWithoutStopping() throws {
        var presentationCount = 0
        let fixture = try makeFixture { _ in presentationCount += 1 }
        fixture.panel.beginSession(
            transcriptController: fixture.firstTranscript,
            recordingKind: .meeting
        )
        fixture.panel.hide()
        let island = RecordingIslandController(
            defaults: try testDefaults(),
            displaysProvider: { [] },
            mainDisplayIDProvider: { nil },
            actionHandler: { action in
                if action == .showTranscript { fixture.panel.showTranscript() }
            },
            announcementHandler: { _ in },
            reduceMotionProvider: { true },
            panelPresentationHandler: { _ in }
        )
        island.present(.meeting(RecordingIslandMeetingPresentation(
            phase: .recording,
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_000)
        )))

        #expect(island.controls.contains(.showTranscript))
        island.perform(.showTranscript)

        #expect(fixture.panel.isPresented)
        #expect(presentationCount == 2)
        #expect(fixture.dashboard.transcriptController === fixture.firstTranscript)
        #expect(fixture.recorder.stopCount == 0)
        fixture.panel.hide()
        island.hideImmediately()
    }

    private var panelSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/BrainMenu/Overlay/MeetingLivePanelController.swift"
            )
    }

    private func makeFixture(
        presentation: @escaping @MainActor (MeetingLivePanel) -> Void = { _ in }
    ) throws -> PanelFixture {
        let recorder = PanelMeetingRecorder()
        let meeting = MeetingController(
            detector: PanelMeetingDetector(),
            recorder: recorder,
            speechEngine: "whisper",
            speechModel: "model"
        )
        let dashboard = MeetingLiveDashboardController(meetingController: meeting)
        let panel = MeetingLivePanelController(
            dashboardController: dashboard,
            panelPresentationHandler: presentation
        )
        return PanelFixture(
            recorder: recorder,
            dashboard: dashboard,
            panel: panel,
            firstTranscript: try makeTranscript("first")
        )
    }

    private func makeTranscript(_ label: String) throws -> LiveTranscriptController {
        LiveTranscriptController(service: try LiveTranscriptionService(
            client: PanelLiveTranscriptionClient(),
            engine: .whisper,
            originHostTimestamp: 1,
            wavDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingLivePanelTests-\(label)-\(UUID().uuidString)")
        ))
    }

    private func testDefaults() throws -> UserDefaults {
        let name = "MeetingLivePanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

@MainActor
private struct PanelFixture {
    let recorder: PanelMeetingRecorder
    let dashboard: MeetingLiveDashboardController
    let panel: MeetingLivePanelController
    let firstTranscript: LiveTranscriptController
}

private struct PanelLiveTranscriptionClient: LiveTranscriptionClient {
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }
}

@MainActor
private final class PanelMeetingRecorder: MeetingRecording {
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    func start(_ request: MeetingRecordingRequest) async throws {}
    func pause(at date: Date) async throws {}
    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {}
    func stop(at date: Date) async throws -> MeetingRecord? {
        stopCount += 1
        return nil
    }
    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {
        cancelCount += 1
    }
}

@MainActor
private final class PanelMeetingDetector: MeetingDetecting {
    func observe(_ observation: MeetingDetectorObservation, at date: Date) -> MeetingDetectorEvent? {
        nil
    }
    func beginTracking(_ application: MeetingDetectedApplication?) {}
    func dismiss(_ candidate: MeetingStartCandidate) {}
    func suppressEndSuggestions(until date: Date) {}
    func reset() {}
}
