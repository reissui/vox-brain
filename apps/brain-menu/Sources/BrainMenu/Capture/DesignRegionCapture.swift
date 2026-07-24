import AppKit
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit

enum DesignRegionCaptureError: Error, Equatable, LocalizedError, Sendable {
    case captureInProgress
    case cancelled
    case invalidSelection
    case displayUnavailable
    case screenshotFailed
    case invalidPNG

    var errorDescription: String? {
        switch self {
        case .captureInProgress: "A region selector is already open."
        case .cancelled: "Region selection was cancelled."
        case .invalidSelection: "Drag a larger region to capture."
        case .displayUnavailable: "The selected display is no longer available."
        case .screenshotFailed: "The selected region could not be captured."
        case .invalidPNG: "The selected region did not produce a valid PNG image."
        }
    }
}

struct DesignRegionSelection: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let scale: CGFloat
}

@MainActor
protocol DesignRegionSelecting: AnyObject {
    func selectRegion() async throws -> DesignRegionSelection
}

protocol DesignRegionScreenshotting: Sendable {
    func capturePNG(selection: DesignRegionSelection) async throws -> Data
}

@MainActor
protocol DesignRegionCapturing: AnyObject {
    func captureSelectedRegion() async throws -> CaptureImagePayload
}

@MainActor
final class DesignRegionCapture: DesignRegionCapturing {
    private let selector: any DesignRegionSelecting
    private let screenshotter: any DesignRegionScreenshotting

    init(
        selector: any DesignRegionSelecting = ScreenRegionSelector(),
        screenshotter: any DesignRegionScreenshotting = ScreenCaptureKitRegionScreenshotter()
    ) {
        self.selector = selector
        self.screenshotter = screenshotter
    }

    func captureSelectedRegion() async throws -> CaptureImagePayload {
        let selection = try await selector.selectRegion()
        guard selection.sourceRect.width >= 2, selection.sourceRect.height >= 2 else {
            throw DesignRegionCaptureError.invalidSelection
        }
        // Remove the selection windows before asking ScreenCaptureKit for the image.
        try await Task.sleep(for: .milliseconds(120))
        let png = try await screenshotter.capturePNG(selection: selection)
        guard DesignWindowCapture.isPNG(png) else { throw DesignRegionCaptureError.invalidPNG }
        return CaptureImagePayload(
            data: png,
            mimeType: "image/png",
            filename: "Region Screenshot.png"
        )
    }
}

@MainActor
final class ScreenRegionSelector: DesignRegionSelecting {
    private var panels: [RegionSelectionPanel] = []
    private var continuation: CheckedContinuation<DesignRegionSelection, Error>?

    func selectRegion() async throws -> DesignRegionSelection {
        guard continuation == nil else { throw DesignRegionCaptureError.captureInProgress }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                presentOverlays()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        }
    }

    private func presentOverlays() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(.failure(DesignRegionCaptureError.displayUnavailable))
            return
        }

        panels = screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            let panel = RegionSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onCancel = { [weak self] in
                self?.finish(.failure(DesignRegionCaptureError.cancelled))
            }
            view.onSelection = { [weak self] localRect in
                let sourceRect = CGRect(
                    x: localRect.minX,
                    y: screen.frame.height - localRect.maxY,
                    width: localRect.width,
                    height: localRect.height
                )
                self?.finish(.success(DesignRegionSelection(
                    displayID: CGDirectDisplayID(number.uint32Value),
                    sourceRect: sourceRect,
                    scale: screen.backingScaleFactor
                )))
            }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            return panel
        }
        guard !panels.isEmpty else {
            finish(.failure(DesignRegionCaptureError.displayUnavailable))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKey()
    }

    private func finish(_ result: Result<DesignRegionSelection, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.close() }
        panels.removeAll()
        continuation.resume(with: result)
    }
}

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        selectionRect = Self.normalizedRect(
            from: startPoint,
            to: convert(event.locationInWindow, from: nil)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint else { return }
        let rect = Self.normalizedRect(
            from: startPoint,
            to: convert(event.locationInWindow, from: nil)
        ).intersection(bounds)
        self.startPoint = nil
        guard rect.width >= 2, rect.height >= 2 else {
            selectionRect = nil
            needsDisplay = true
            return
        }
        onSelection?(rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let selectionRect { shade.appendRect(selectionRect) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        shade.fill()

        if let selectionRect {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.stroke()
        } else {
            drawInstructions()
        }
    }

    private func drawInstructions() {
        let text = "Drag to capture a region  ·  Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let textRect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let background = NSBezierPath(
            roundedRect: textRect.insetBy(dx: -14, dy: -10),
            xRadius: 8,
            yRadius: 8
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        background.fill()
        text.draw(in: textRect, withAttributes: attributes)
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

struct ScreenCaptureKitRegionScreenshotter: DesignRegionScreenshotting {
    func capturePNG(selection: DesignRegionSelection) async throws -> Data {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw DesignRegionCaptureError.screenshotFailed
        }
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw DesignRegionCaptureError.displayUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = selection.sourceRect
        configuration.width = Int((selection.sourceRect.width * selection.scale).rounded(.up))
        configuration.height = Int((selection.sourceRect.height * selection.scale).rounded(.up))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        let filter = SCContentFilter(display: display, excludingWindows: [])

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                guard error == nil, let image else {
                    continuation.resume(throwing: DesignRegionCaptureError.screenshotFailed)
                    return
                }
                guard let png = NSBitmapImageRep(cgImage: image).representation(
                    using: .png,
                    properties: [:]
                ) else {
                    continuation.resume(throwing: DesignRegionCaptureError.invalidPNG)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }
}

@MainActor
@Observable
final class RegionCaptureController {
    static let hotkey = CaptureHotkey.controlOptionZ

    private(set) var isRegistered = false
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let captureController: CaptureController
    @ObservationIgnored private let regionCapture: any DesignRegionCapturing
    @ObservationIgnored private let registrar: any CaptureHotkeyRegistering
    @ObservationIgnored private let resultPresenter: any AdaptiveCaptureResultPresenting

    init(
        captureController: CaptureController,
        regionCapture: any DesignRegionCapturing = DesignRegionCapture(),
        registrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(identifier: 3),
        resultPresenter: any AdaptiveCaptureResultPresenting = SystemAdaptiveCaptureResultPresenter()
    ) {
        self.captureController = captureController
        self.regionCapture = regionCapture
        self.registrar = registrar
        self.resultPresenter = resultPresenter
    }

    @discardableResult
    func start() -> Bool {
        do {
            try registrar.register(Self.hotkey) { [weak self] in
                Task { @MainActor [weak self] in await self?.captureRegion() }
            }
            isRegistered = true
            errorMessage = nil
            return true
        } catch {
            isRegistered = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stop() {
        registrar.unregister()
        isRegistered = false
    }

    func captureRegion() async {
        guard !isRunning, !captureController.isSubmitting, !captureController.canRetry else {
            errorMessage = "Wait for the current capture to finish, then try again."
            resultPresenter.present(.deliveryBusy)
            return
        }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        let image: CaptureImagePayload
        do {
            image = try await regionCapture.captureSelectedRegion()
        } catch is CancellationError {
            return
        } catch DesignRegionCaptureError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
            resultPresenter.present(.captureFailed)
            return
        }

        var draft = CaptureDraft.empty(kind: .image)
        draft.image = image
        draft.imageContext = "Region screenshot captured with Control–Option–Z."
        captureController.draft = draft
        guard captureController.canSubmit else {
            errorMessage = "Wait for the current capture to finish, then try again."
            resultPresenter.present(.deliveryBusy)
            return
        }
        await captureController.submit()
        if captureController.queuedReceipt == nil {
            errorMessage = captureController.errorMessage ?? "The screenshot was not delivered."
            resultPresenter.present(.deliveryFailed)
        } else {
            errorMessage = nil
        }
    }
}
