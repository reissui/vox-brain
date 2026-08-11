import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct QuickCaptureTests {
    @Test
    func adaptiveSelectedHTTPURLQueuesALinkWithoutAnyScreenshotService() async throws {
        let api = QuickCaptureAPISpy()
        let capture = CaptureController(api: api, sleep: { _ in })
        let results = AdaptiveResultPresenterSpy()
        let controller = AdaptiveCaptureController(
            captureController: capture,
            selectedTextReader: SelectedTextReaderSpy(snapshot: .init(
                selectedText: "  HTTPS://Example.COM/path?q=one#section\n",
                windowTitle: "Article"
            )),
            resultPresenter: results
        )

        await controller.capture(from: nil)

        #expect(await api.requests == [BrainCaptureRequest(
            url: "HTTPS://Example.COM/path?q=one#section",
            source: CaptureController.source
        )])
        #expect(results.failures.isEmpty)
    }

    @Test
    func adaptiveSelectedTextQueuesAVerbatimNoteWithoutScreenshotFallback() async throws {
        let api = QuickCaptureAPISpy()
        let capture = CaptureController(api: api, sleep: { _ in })
        let controller = AdaptiveCaptureController(
            captureController: capture,
            selectedTextReader: SelectedTextReaderSpy(snapshot: .init(
                selectedText: "Exact selected words\nwith a second line",
                windowTitle: "Document"
            )),
            resultPresenter: AdaptiveResultPresenterSpy()
        )

        await controller.capture(from: nil)

        #expect(await api.requests == [BrainCaptureRequest(
            type: .note,
            text: "Exact selected words\nwith a second line",
            source: CaptureController.source
        )])
    }

    @Test
    func adaptiveBlankOrUnavailableSelectionReportsSourceUnavailableAndQueuesNothing() async {
        let blankAPI = QuickCaptureAPISpy()
        let blankResults = AdaptiveResultPresenterSpy()
        let blank = AdaptiveCaptureController(
            captureController: CaptureController(api: blankAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(snapshot: .init(selectedText: " \n\t ", windowTitle: "")),
            resultPresenter: blankResults
        )
        await blank.capture(from: nil)
        #expect(await blankAPI.requests.isEmpty)
        #expect(blankResults.failures == [.sourceUnavailable])

        let unavailableAPI = QuickCaptureAPISpy()
        let unavailableResults = AdaptiveResultPresenterSpy()
        let unavailable = AdaptiveCaptureController(
            captureController: CaptureController(api: unavailableAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(error: SelectedTextReaderError.sourceUnavailable),
            resultPresenter: unavailableResults
        )
        await unavailable.capture(from: nil)
        #expect(await unavailableAPI.requests.isEmpty)
        #expect(unavailableResults.failures == [.sourceUnavailable])
    }

    @Test
    func quickCaptureHasOnlyNoteAndLinkModesAndNoDesignUIOrPermissionGate() throws {
        #expect(QuickCaptureMode.allCases == [.note, .link])
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("Views/QuickCapturePanel.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("Choose Window"))
        #expect(!source.contains("designContext"))
        #expect(!source.contains("DesignWindowCapture"))
        #expect(!source.contains(".systemAudio"))
    }

    @Test
    func genericImageAndTranscriptImportsRemainAvailable() throws {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("Views/CaptureView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Choose Image…"))
        #expect(source.contains("Choose Transcript…"))
        #expect(source.contains("UTType.jpeg"))
        #expect(source.contains(".md or .txt"))
    }

    @Test
    func manualLinkClipboardPrefillAndNoteSubmissionRemainAvailable() async throws {
        let clipboard = QuickClipboardSpy(text: " https://example.com/path ")
        let api = QuickCaptureAPISpy()
        let capture = CaptureController(api: api, sleep: { _ in })
        let controller = QuickCaptureController(
            mode: .link,
            captureController: capture,
            clipboard: clipboard,
            permissionGate: QuickPermissionGateSpy()
        )
        controller.prepareToOpen(sourceApplication: nil)
        #expect(clipboard.textReads == 0)
        controller.panelDidOpen()
        #expect(controller.url == "https://example.com/path")
        await controller.submit()
        #expect(await api.requests.first?.url == "https://example.com/path")
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrainMenu", isDirectory: true)
    }
}

@MainActor private final class SelectedTextReaderSpy: SelectedTextReading {
    private let result: Result<SelectedTextSnapshot, Error>
    init(snapshot: SelectedTextSnapshot) { result = .success(snapshot) }
    init(error: Error) { result = .failure(error) }
    func snapshot(from application: QuickCaptureApplicationIdentity?) throws -> SelectedTextSnapshot { try result.get() }
}

@MainActor private final class AdaptiveResultPresenterSpy: AdaptiveCaptureResultPresenting {
    private(set) var failures: [AdaptiveCaptureFailure] = []
    func present(_ failure: AdaptiveCaptureFailure) { failures.append(failure) }
}

@MainActor private final class QuickClipboardSpy: CaptureClipboardReading {
    let text: String?
    private(set) var textReads = 0
    init(text: String?) { self.text = text }
    func readText() -> String? { textReads += 1; return text }
    func readImage() -> CaptureImagePayload? { nil }
}

@MainActor private final class QuickPermissionGateSpy: QuickCapturePermissionGating {
    func unresolvedPermission(for mode: QuickCaptureMode) -> QuickCapturePermissionBlock? { nil }
    func perform(_ action: OnboardingAction) async {}
}

private actor QuickCaptureAPISpy: BrainCaptureAPI {
    let receiptID = "11111111-2222-4333-8444-555555555555"
    private(set) var requests: [BrainCaptureRequest] = []
    func capture(_ capture: BrainCaptureRequest, idempotencyKey: UUID) async throws -> BrainCaptureReceipt {
        requests.append(capture)
        return BrainCaptureReceipt(id: receiptID, state: "queued")
    }
    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        .init(id: id, state: .delivered, retryable: false, error: nil, createdAt: .now, updatedAt: .now, deliveredAt: .now)
    }
}
