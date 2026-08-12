import AppKit
import Observation
import SwiftUI

/// Unlike the recording island, this panel is allowed to become key after the
/// user clicks it so transcript selection and keyboard controls work normally.
final class MeetingLivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class MeetingLivePanelController: NSObject, NSWindowDelegate {
    static let minimumSize = CGSize(width: 560, height: 480)
    static let initialSize = CGSize(width: 680, height: 620)
    static let frameAutosaveName = "BrainMeetingLivePanel"

    let dashboardController: MeetingLiveDashboardController
    private(set) var panel: MeetingLivePanel!
    private(set) var isPresented = false
    private(set) var recordingKind: MeetingRecordingKind?

    @ObservationIgnored private let panelPresentationHandler:
        @MainActor (MeetingLivePanel) -> Void

    init(
        dashboardController: MeetingLiveDashboardController,
        panelPresentationHandler: @escaping @MainActor (MeetingLivePanel) -> Void = {
            $0.orderFrontRegardless()
        }
    ) {
        self.dashboardController = dashboardController
        self.panelPresentationHandler = panelPresentationHandler
        super.init()
        panel = makePanel()
    }

    /// Attaches the recorder's own controller and opens without activating Brain.
    func beginSession(
        transcriptController: LiveTranscriptController,
        recordingKind: MeetingRecordingKind,
        meetingID: UUID? = nil
    ) {
        self.recordingKind = recordingKind
        if let meetingID {
            dashboardController.attachSession(
                transcriptController: transcriptController,
                meetingID: meetingID
            )
        } else {
            dashboardController.attachTranscript(transcriptController)
        }
        showTranscript()
    }

    func endSession() {
        recordingKind = nil
        dashboardController.attachTranscript(nil)
        hide()
    }

    /// Reuses the same application-lifetime panel and dashboard. `orderFront`
    /// does not activate the application or steal focus from the current app.
    func showTranscript() {
        guard dashboardController.transcriptController != nil else { return }
        isPresented = true
        panelPresentationHandler(panel)
    }

    func hide() {
        isPresented = false
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func makePanel() -> MeetingLivePanel {
        let panel = MeetingLivePanel(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Transcript"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = Self.minimumSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MeetingLiveView(
            controller: dashboardController
        ))
        panel.center()
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        return panel
    }
}
