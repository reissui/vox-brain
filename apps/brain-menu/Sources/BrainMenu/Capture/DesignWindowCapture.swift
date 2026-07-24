import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

enum DesignWindowCaptureError: Error, Equatable, LocalizedError, Sendable {
    case captureInProgress
    case pickerCancelled
    case pickerFailed
    case selectionIsNotAWindow
    case invalidWindowSize
    case screenshotFailed
    case invalidPNG

    var errorDescription: String? {
        switch self {
        case .captureInProgress:
            "A window picker is already open."
        case .pickerCancelled:
            "Window selection was cancelled."
        case .pickerFailed:
            "The system window picker could not be opened."
        case .selectionIsNotAWindow:
            "Choose exactly one window."
        case .invalidWindowSize:
            "The selected window has no visible content to capture."
        case .screenshotFailed:
            "The selected window could not be captured."
        case .invalidPNG:
            "The selected window did not produce a valid PNG image."
        }
    }
}

enum DesignWindowSelectionKind: Equatable, Sendable {
    case window
    case other
}

/// The only production initializer is fed by `SCContentSharingPicker`. The
/// public value fields also keep the picker/capture boundary deterministic in
/// tests without requiring Screen Recording permission.
struct DesignWindowSelection: @unchecked Sendable {
    let kind: DesignWindowSelectionKind
    let pixelWidth: Int
    let pixelHeight: Int
    let identifier: String

    fileprivate let contentFilter: SCContentFilter?

    init(
        kind: DesignWindowSelectionKind,
        pixelWidth: Int,
        pixelHeight: Int,
        identifier: String = "test-window"
    ) {
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.identifier = identifier
        contentFilter = nil
    }

    fileprivate init(contentFilter: SCContentFilter) {
        let scale = max(Double(contentFilter.pointPixelScale), 1)
        kind = contentFilter.style == .window ? .window : .other
        pixelWidth = Int((contentFilter.contentRect.width * scale).rounded(.up))
        pixelHeight = Int((contentFilter.contentRect.height * scale).rounded(.up))
        identifier = "picker-window"
        self.contentFilter = contentFilter
    }
}

protocol DesignWindowPicking: Sendable {
    /// Must present a consent UI restricted to one window and return only the
    /// filter produced by that explicit picker selection.
    func pickSingleWindow() async throws -> DesignWindowSelection
}

protocol DesignWindowScreenshotting: Sendable {
    /// Captures the already-confirmed picker selection. It must not discover or
    /// substitute another window or display.
    func capturePNG(for selection: DesignWindowSelection) async throws -> Data
}

struct DesignWindowCapture: Sendable {
    private let picker: any DesignWindowPicking
    private let screenshotter: any DesignWindowScreenshotting

    init(
        picker: any DesignWindowPicking = ScreenCaptureKitWindowPicker(),
        screenshotter: any DesignWindowScreenshotting = ScreenCaptureKitWindowScreenshotter()
    ) {
        self.picker = picker
        self.screenshotter = screenshotter
    }

    /// There is deliberately no display/window-list capture entry point. Every
    /// image travels through Apple's single-window sharing picker first.
    func captureSelectedWindow() async throws -> CaptureImagePayload {
        let selection = try await picker.pickSingleWindow()
        guard selection.kind == .window else {
            throw DesignWindowCaptureError.selectionIsNotAWindow
        }
        guard selection.pixelWidth > 0, selection.pixelHeight > 0 else {
            throw DesignWindowCaptureError.invalidWindowSize
        }

        let png = try await screenshotter.capturePNG(for: selection)
        guard Self.isPNG(png) else { throw DesignWindowCaptureError.invalidPNG }
        return CaptureImagePayload(
            data: png,
            mimeType: "image/png",
            filename: "Selected Window.png"
        )
    }

    static func isPNG(_ data: Data) -> Bool {
        Array(data.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    }
}

final class ScreenCaptureKitWindowPicker: NSObject, DesignWindowPicking,
    SCContentSharingPickerObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DesignWindowSelection, Error>?

    func pickSingleWindow() async throws -> DesignWindowSelection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock {
                    guard self.continuation == nil else { return false }
                    self.continuation = continuation
                    return true
                }
                guard accepted else {
                    continuation.resume(throwing: DesignWindowCaptureError.captureInProgress)
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.hasPendingSelection else { return }
                    let picker = SCContentSharingPicker.shared
                    var configuration = SCContentSharingPickerConfiguration()
                    configuration.allowedPickerModes = .singleWindow
                    configuration.allowsChangingSelectedContent = false
                    picker.defaultConfiguration = configuration
                    picker.maximumStreamCount = 1
                    picker.add(self)
                    picker.isActive = true
                    picker.present(using: .window)
                }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        finish(.failure(DesignWindowCaptureError.pickerCancelled))
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        finish(.success(DesignWindowSelection(contentFilter: filter)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(.failure(DesignWindowCaptureError.pickerFailed))
    }

    private func finish(_ result: Result<DesignWindowSelection, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        Task { @MainActor in
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
            pending.resume(with: result)
        }
    }

    private var hasPendingSelection: Bool {
        lock.withLock { continuation != nil }
    }
}

struct ScreenCaptureKitWindowScreenshotter: DesignWindowScreenshotting {
    func capturePNG(for selection: DesignWindowSelection) async throws -> Data {
        guard let filter = selection.contentFilter else {
            throw DesignWindowCaptureError.screenshotFailed
        }

        let configuration = SCStreamConfiguration()
        configuration.width = selection.pixelWidth
        configuration.height = selection.pixelHeight
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                guard error == nil, let image else {
                    continuation.resume(throwing: DesignWindowCaptureError.screenshotFailed)
                    return
                }
                guard let png = NSBitmapImageRep(cgImage: image).representation(
                    using: .png,
                    properties: [:]
                ) else {
                    continuation.resume(throwing: DesignWindowCaptureError.invalidPNG)
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }
}
