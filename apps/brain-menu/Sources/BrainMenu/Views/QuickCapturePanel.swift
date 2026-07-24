import AppKit
import Foundation
import Observation
import SwiftUI

enum QuickCaptureMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case note
    case link
    case design

    var id: Self { self }

    var title: String {
        switch self {
        case .note: "Note"
        case .link: "Link / Bookmark"
        case .design: "Design"
        }
    }
}

struct QuickCapturePermissionBlock: Equatable, Sendable {
    let checkID: OnboardingCheckID
    let detail: String
    let action: OnboardingAction?
}

@MainActor
protocol QuickCapturePermissionGating: AnyObject {
    func unresolvedPermission(for mode: QuickCaptureMode) -> QuickCapturePermissionBlock?
    func refresh() async
    func perform(_ action: OnboardingAction) async
}

extension QuickCapturePermissionGating {
    func refresh() async {}
}

enum AdaptiveCaptureFailure: Equatable, Sendable {
    case accessibilityDenied
    case sourceUnavailable
    case pickerCancelled
    case captureFailed
    case deliveryBusy
    case deliveryFailed

    var title: String {
        switch self {
        case .accessibilityDenied: "Allow Accessibility"
        case .sourceUnavailable: "Source window unavailable"
        case .pickerCancelled: "Screenshot cancelled"
        case .captureFailed: "Screenshot not captured"
        case .deliveryBusy: "Capture already in progress"
        case .deliveryFailed: "Capture not sent"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .accessibilityDenied:
            "Open Accessibility settings, allow Brain, then press Control–Option–B again."
        case .sourceUnavailable:
            "Return to the window you want to capture, then press Control–Option–B again."
        case .pickerCancelled:
            "Nothing was sent. Press Control–Option–B when you are ready to choose a window."
        case .captureFailed:
            "Choose the window again, or check Screen Recording in System Settings."
        case .deliveryBusy:
            "Wait for the current capture to finish, then try again."
        case .deliveryFailed:
            "Open Brain to check pairing and delivery status, then try again."
        }
    }
}

@MainActor
protocol AdaptiveCaptureResultPresenting: AnyObject {
    func present(_ failure: AdaptiveCaptureFailure)
}

@MainActor
final class SystemAdaptiveCaptureResultPresenter: AdaptiveCaptureResultPresenting {
    func present(_ failure: AdaptiveCaptureFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.recoverySuggestion
        if failure == .accessibilityDenied {
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Not Now")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if failure == .accessibilityDenied,
           response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(OnboardingPermission.accessibility.systemSettingsURL)
        }
    }
}

@MainActor
protocol AdaptiveCapturePerforming: AnyObject {
    func capture(from application: QuickCaptureApplicationIdentity?) async
}

/// Implements the one-key contextual flow without activating Brain first:
/// selected URL wins; otherwise Apple's picker supplies one window image.
@MainActor
@Observable
final class AdaptiveCaptureController: AdaptiveCapturePerforming {
    private(set) var isRunning = false
    private(set) var lastFailure: AdaptiveCaptureFailure?

    let captureController: CaptureController

    @ObservationIgnored private let selectedTextReader: any SelectedTextReading
    @ObservationIgnored private let designCapture: DesignWindowCapture
    @ObservationIgnored private let resultPresenter: any AdaptiveCaptureResultPresenting

    init(
        captureController: CaptureController,
        selectedTextReader: any SelectedTextReading = SystemSelectedTextReader(),
        designCapture: DesignWindowCapture = DesignWindowCapture(),
        resultPresenter: any AdaptiveCaptureResultPresenting = SystemAdaptiveCaptureResultPresenter()
    ) {
        self.captureController = captureController
        self.selectedTextReader = selectedTextReader
        self.designCapture = designCapture
        self.resultPresenter = resultPresenter
    }

    func capture(from application: QuickCaptureApplicationIdentity?) async {
        guard !isRunning else {
            show(.deliveryBusy)
            return
        }
        isRunning = true
        lastFailure = nil
        defer { isRunning = false }

        let snapshot: SelectedTextSnapshot
        do {
            snapshot = try selectedTextReader.snapshot(from: application)
        } catch SelectedTextReaderError.accessibilityDenied {
            show(.accessibilityDenied)
            return
        } catch {
            show(.sourceUnavailable)
            return
        }

        guard !captureController.isSubmitting, !captureController.canRetry else {
            show(.deliveryBusy)
            return
        }

        if let url = SelectedHTTPURL.parse(snapshot.selectedText) {
            var draft = CaptureDraft.empty(kind: .link)
            draft.url = url
            await submit(draft)
            return
        }

        guard let context = Self.screenshotContext(
            applicationName: application?.localizedName,
            windowTitle: snapshot.windowTitle
        ) else {
            show(.sourceUnavailable)
            return
        }

        let image: CaptureImagePayload
        do {
            image = try await designCapture.captureSelectedWindow()
        } catch is CancellationError {
            show(.pickerCancelled)
            return
        } catch DesignWindowCaptureError.pickerCancelled {
            show(.pickerCancelled)
            return
        } catch {
            show(.captureFailed)
            return
        }

        var draft = CaptureDraft.empty(kind: .image)
        draft.image = image
        draft.imageContext = context
        await submit(draft)
    }

    static func screenshotContext(
        applicationName: String?,
        windowTitle: String
    ) -> String? {
        guard let applicationName = sanitize(applicationName, maximumLength: 80),
              let windowTitle = sanitize(windowTitle, maximumLength: 240) else {
            return nil
        }
        return "Source application: \(applicationName)\nWindow title: \(windowTitle)"
    }

    private func submit(_ draft: CaptureDraft) async {
        captureController.draft = draft
        guard captureController.canSubmit else {
            show(.deliveryBusy)
            return
        }
        await captureController.submit()
        guard captureController.queuedReceipt != nil else {
            show(.deliveryFailed)
            return
        }
    }

    private func show(_ failure: AdaptiveCaptureFailure) {
        lastFailure = failure
        resultPresenter.present(failure)
    }

    private static func sanitize(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let withoutControls = String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined())
        let collapsed = withoutControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

@MainActor
final class OnboardingQuickCapturePermissionGate: QuickCapturePermissionGating {
    let onboarding: OnboardingController

    init(onboarding: OnboardingController) {
        self.onboarding = onboarding
    }

    func unresolvedPermission(for mode: QuickCaptureMode) -> QuickCapturePermissionBlock? {
        // Carbon owns the global shortcut without a privacy permission. Link
        // context uses Accessibility; the Apple window picker uses Screen &
        // System Audio Recording. Plain notes need neither capability.
        let required: [OnboardingCheckID] = switch mode {
        case .note: []
        case .link: [.accessibility]
        case .design: [.systemAudio]
        }
        guard let check = required
            .map(onboarding.check)
            .first(where: { $0.state != .ready }) else {
            return nil
        }
        return QuickCapturePermissionBlock(
            checkID: check.id,
            detail: check.detail,
            action: check.action
        )
    }

    func refresh() async {
        await onboarding.refresh()
    }

    func perform(_ action: OnboardingAction) async {
        await onboarding.perform(action)
    }
}

enum QuickCaptureValidationError: Error, Equatable, LocalizedError, Sendable {
    case panelIsNotOpen
    case permissionUnresolved
    case missingDesignContext
    case captureDeliveryBusy

    var errorDescription: String? {
        switch self {
        case .panelIsNotOpen:
            "Open Quick Capture before capturing."
        case .permissionUnresolved:
            "Finish the required onboarding permission before using this capture action."
        case .missingDesignContext:
            "Add searchable context before choosing a design window."
        case .captureDeliveryBusy:
            "Finish or retry the current capture before sending another."
        }
    }
}

@MainActor
@Observable
final class QuickCaptureController {
    private(set) var mode: QuickCaptureMode
    private(set) var sourceApplication: QuickCaptureApplicationIdentity?
    private(set) var isPresented = false
    private(set) var isChoosingWindow = false
    private(set) var errorMessage: String?

    var noteText = ""
    var url = ""
    var comment = ""
    var selectedText = ""
    var designContext = ""
    private(set) var designImage: CaptureImagePayload?

    let captureController: CaptureController

    var permissionBlock: QuickCapturePermissionBlock? {
        permissionGate.unresolvedPermission(for: mode)
    }

    var canSubmit: Bool {
        isPresented
            && permissionBlock == nil
            && !isChoosingWindow
            && !captureController.isSubmitting
            && !captureController.canRetry
    }

    @ObservationIgnored private let clipboard: any CaptureClipboardReading
    @ObservationIgnored private let designCapture: DesignWindowCapture
    @ObservationIgnored private let permissionGate: any QuickCapturePermissionGating
    @ObservationIgnored private var panelHasOpened = false
    @ObservationIgnored private var didReadClipboardThisSession = false
    @ObservationIgnored private var dismissHandler: (() -> Void)?

    init(
        mode: QuickCaptureMode = .note,
        captureController: CaptureController = CaptureController(),
        clipboard: any CaptureClipboardReading = SystemCaptureClipboard(),
        designCapture: DesignWindowCapture = DesignWindowCapture(),
        permissionGate: any QuickCapturePermissionGating = OnboardingQuickCapturePermissionGate(
            onboarding: OnboardingController()
        )
    ) {
        self.mode = mode
        self.captureController = captureController
        self.clipboard = clipboard
        self.designCapture = designCapture
        self.permissionGate = permissionGate
    }

    /// Prepares state but intentionally does not touch the pasteboard. The
    /// presenter calls `panelDidOpen` only after the panel is on screen.
    func prepareToOpen(sourceApplication: QuickCaptureApplicationIdentity?) {
        self.sourceApplication = sourceApplication
        isPresented = true
        panelHasOpened = false
        didReadClipboardThisSession = false
        errorMessage = nil
        noteText = ""
        url = ""
        comment = ""
        selectedText = ""
        designContext = ""
        designImage = nil
    }

    func panelDidOpen() {
        guard isPresented else { return }
        panelHasOpened = true
        prefillLinkFromClipboardIfNeeded()
    }

    func selectMode(_ mode: QuickCaptureMode) {
        self.mode = mode
        errorMessage = nil
        prefillLinkFromClipboardIfNeeded()
    }

    func chooseDesignWindow() async {
        guard isPresented else {
            errorMessage = QuickCaptureValidationError.panelIsNotOpen.localizedDescription
            return
        }
        guard mode == .design else { return }
        guard permissionBlock == nil else {
            errorMessage = QuickCaptureValidationError.permissionUnresolved.localizedDescription
            return
        }
        guard !designContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = QuickCaptureValidationError.missingDesignContext.localizedDescription
            return
        }

        isChoosingWindow = true
        errorMessage = nil
        defer { isChoosingWindow = false }
        do {
            designImage = try await designCapture.captureSelectedWindow()
        } catch is CancellationError {
            // Cancellation is equivalent to dismissing Apple's picker. Keep
            // the Quick Capture draft and do not invent an image.
        } catch DesignWindowCaptureError.pickerCancelled {
            // Same as above for the picker's explicit Cancel button.
        } catch {
            designImage = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Copies the explicit panel draft into the existing delivery controller;
    /// all validation, idempotency, retry, polling, and delivery state remains
    /// owned by `CaptureController`.
    func submit() async {
        guard isPresented else {
            errorMessage = QuickCaptureValidationError.panelIsNotOpen.localizedDescription
            return
        }
        guard permissionBlock == nil else {
            errorMessage = QuickCaptureValidationError.permissionUnresolved.localizedDescription
            return
        }
        // A delivered/compatibility-queued draft becomes idle when replaced,
        // as it does in CaptureView. A retryable draft is sacred: never replace
        // the stable payload and idempotency key while Retry is available.
        guard !captureController.isSubmitting, !captureController.canRetry else {
            errorMessage = QuickCaptureValidationError.captureDeliveryBusy.localizedDescription
            return
        }

        var draft: CaptureDraft
        switch mode {
        case .note:
            draft = .empty(kind: .note)
            draft.noteText = noteText
        case .link:
            draft = .empty(kind: .link)
            draft.url = url
            draft.comment = comment
            draft.selectedText = selectedText
        case .design:
            draft = .empty(kind: .image)
            draft.image = designImage
            draft.imageContext = designContext
        }
        captureController.draft = draft
        guard captureController.canSubmit else {
            errorMessage = QuickCaptureValidationError.captureDeliveryBusy.localizedDescription
            return
        }
        errorMessage = nil
        await captureController.submit()
    }

    func retry() async {
        await captureController.retry()
    }

    func performPermissionAction() async {
        guard let action = permissionBlock?.action else { return }
        await permissionGate.perform(action)
    }

    func refreshPermissions() async {
        await permissionGate.refresh()
    }

    func escape() {
        guard isPresented else { return }
        isPresented = false
        panelHasOpened = false
        didReadClipboardThisSession = false
        dismissHandler?()
    }

    func setDismissHandler(_ handler: @escaping () -> Void) {
        dismissHandler = handler
    }

    private func prefillLinkFromClipboardIfNeeded() {
        guard isPresented, panelHasOpened, mode == .link,
              !didReadClipboardThisSession else { return }
        didReadClipboardThisSession = true
        guard let text = clipboard.readText(), let valid = Self.clipboardURL(text) else { return }
        url = valid
    }

    /// Clipboard prefill is intentionally stricter than manual entry: it never
    /// guesses a scheme and accepts only an explicit HTTP(S) URL.
    static func clipboardURL(_ text: String) -> String? {
        SelectedHTTPURL.parse(text)
    }
}

@MainActor
final class QuickCapturePanelPresenter: NSObject, QuickCaptureOpening, NSWindowDelegate {
    let controller: QuickCaptureController
    private var panel: NSPanel?

    init(controller: QuickCaptureController) {
        self.controller = controller
        super.init()
        controller.setDismissHandler { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func open(sourceApplication: QuickCaptureApplicationIdentity?) {
        controller.prepareToOpen(sourceApplication: sourceApplication)
        let panel = panel ?? makePanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        // The one permitted automatic pasteboard read can happen only now,
        // after the visible panel has opened.
        controller.panelDidOpen()
        Task { await controller.refreshPermissions() }
    }

    func windowWillClose(_ notification: Notification) {
        controller.escape()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Capture"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickCapturePanel(controller: controller))
        self.panel = panel
        return panel
    }
}

@MainActor
struct QuickCapturePanel: View {
    @Bindable var controller: QuickCaptureController
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case primaryField
        case errorSummary
    }

    private var modeSelection: Binding<QuickCaptureMode> {
        Binding(
            get: { controller.mode },
            set: { controller.selectMode($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quick Capture")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                if let source = controller.sourceApplication?.localizedName {
                    Text("Opened from \(source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Capture type", selection: modeSelection) {
                ForEach(QuickCaptureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch controller.mode {
                case .note:
                    noteFields
                case .link:
                    linkFields
                case .design:
                    designFields
                }
            }
            .disabled(controller.captureController.isSubmitting)

            if let block = controller.permissionBlock {
                VStack(alignment: .leading, spacing: 8) {
                    Label(block.detail, systemImage: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .brainAccessibleStatus(.failed, detail: block.detail)
                    if let action = block.action {
                        Button(action.label) {
                            Task { await controller.performPermissionAction() }
                        }
                        .accessibilityLabel("Capture permission: \(action.label)")
                        .accessibilityHint("Opens the permission required by this capture type.")
                    }
                }
            }

            status

            HStack {
                Button("Cancel") { controller.escape() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes Quick Capture without sending")
                Spacer()
                if controller.captureController.canRetry {
                    Button("Retry") { Task { await controller.retry() } }
                        .accessibilityLabel("Retry sending capture")
                }
                Button("Send to Brain") { Task { await controller.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canSubmit)
                    .accessibilityValue(controller.canSubmit ? "Enabled" : "Disabled")
            }

            Text("Control–Option–B reads the focused selection through Accessibility and otherwise opens Apple's window picker. This manual Link form reads clipboard text at most once, only after the panel opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 480)
        .onExitCommand { controller.escape() }
        .onAppear { accessibilityFocus = .primaryField }
        .onChange(of: controller.errorMessage) { _, error in
            if error != nil { accessibilityFocus = .errorSummary }
        }
    }

    private var noteFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Note").font(.headline)
            TextEditor(text: $controller.noteText)
                .frame(minHeight: 230)
                .quickCaptureBorder()
                .accessibilityLabel("Quick Capture note")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 11) {
            TextField("https://example.com", text: $controller.url)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark URL")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)
            Text("Comment (optional)").font(.headline)
            TextEditor(text: $controller.comment)
                .frame(minHeight: 75)
                .quickCaptureBorder()
                .accessibilityLabel("Bookmark comment")
            Text("Selected text (optional)").font(.headline)
            TextEditor(text: $controller.selectedText)
                .frame(minHeight: 90)
                .quickCaptureBorder()
                .accessibilityLabel("Bookmark selected text")
        }
    }

    private var designFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Searchable context").font(.headline)
            TextEditor(text: $controller.designContext)
                .frame(minHeight: 145)
                .quickCaptureBorder()
                .accessibilityLabel("Design searchable context")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)
            Text("Required before Apple's picker opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await controller.chooseDesignWindow() }
                } label: {
                    if controller.isChoosingWindow {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Choose Window…", systemImage: "macwindow.badge.plus")
                    }
                }
                .disabled(controller.isChoosingWindow || controller.permissionBlock != nil)
                .accessibilityValue(
                    controller.isChoosingWindow || controller.permissionBlock != nil
                        ? "Disabled"
                        : "Enabled"
                )
                .accessibilityHint("Opens Apple's window picker without capturing the whole screen.")
                Text(controller.designImage?.filename ?? "No window captured")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if case .waitingForMacMini(let id, let elapsedSeconds, let lastState, let lastError) =
            controller.captureController.submissionState {
            VStack(alignment: .leading, spacing: 7) {
                Label("Waiting for remote runner (\(id))", systemImage: "macmini.and.arrow.forward")
                    .foregroundStyle(.orange)
                    .brainAccessibleStatus(
                        .waiting,
                        detail: "Capture \(id), \(elapsedSeconds) seconds elapsed"
                    )
                Text("\(elapsedSeconds)s elapsed · \(lastState.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastError { Text(lastError).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Check again") { controller.captureController.checkAgain() }
                        .accessibilityHint("Checks this capture without sending it again")
                    Button("Open remote runner") { controller.captureController.openMacMini() }
                        .accessibilityHint("Opens remote runner health and recovery")
                }
            }
        } else if let error = controller.errorMessage ?? controller.captureController.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .brainAccessibleStatus(.failed, detail: error)
                .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
        } else {
            switch controller.captureController.submissionState {
            case .idle:
                EmptyView()
            case .sending:
                Label("Sending capture", systemImage: "paperplane")
            case .retrying:
                Label("Retrying capture", systemImage: "arrow.clockwise")
            case .queued(let id):
                Label("Queued in Brain (\(id))", systemImage: "clock")
                    .brainAccessibleStatus(.queued, detail: "Capture \(id)")
            case .delivering(let id):
                Label("Delivering to Brain (\(id))", systemImage: "arrow.up.circle")
            case .waitingForMacMini:
                EmptyView()
            case .delivered(let id):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Delivered to Brain inbox (\(id))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Awaiting Librarian processing and site publication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .brainAccessibleStatus(
                    .delivered,
                    detail: "Capture \(id). Delivered to the Brain inbox and awaiting Librarian processing"
                )
            case .retryAvailable(let id):
                Label("Retry available for \(id)", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.orange)
            case .needsAttention(let id):
                Label("Needs attention for \(id)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .failed:
                Label("Capture failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .brainAccessibleStatus(.failed, detail: "Capture could not be sent")
                    .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
            }
        }
    }
}

private extension View {
    func quickCaptureBorder() -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        }
    }
}
