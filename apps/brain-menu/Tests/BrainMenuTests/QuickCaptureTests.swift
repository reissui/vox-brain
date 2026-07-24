import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct QuickCaptureTests {
    @Test
    func regionShortcutRegistersControlOptionZAndUploadsOnlyTheConfirmedPNG() async throws {
        let api = QuickCaptureAPISpy(statuses: [])
        let capture = CaptureController(api: api, sleep: { _ in })
        let registrar = HotkeyRegistrarSpy()
        let presenter = AdaptiveResultPresenterSpy()
        let service = DesignRegionCaptureSpy(result: .success(CaptureImagePayload(
            data: quickPNG,
            mimeType: "image/png",
            filename: "Region Screenshot.png"
        )))
        let controller = RegionCaptureController(
            captureController: capture,
            regionCapture: service,
            registrar: registrar,
            resultPresenter: presenter
        )

        #expect(controller.start())
        #expect(registrar.registered == [.controlOptionZ])
        await controller.captureRegion()
        await capture.waitForMonitoring()

        let request = try #require(await api.requests.first)
        #expect(request.type == .design)
        #expect(request.text == "Region screenshot captured with Control–Option–Z.")
        #expect(request.source == CaptureController.source)
        #expect(request.image?.hasPrefix("data:image/png;base64,") == true)
        #expect(request.transcript == nil)
        #expect(service.calls == 1)
        #expect(presenter.failures.isEmpty)
    }

    @Test
    func cancelledRegionSelectionSendsNothingAndProductionPathHasNoShellOrClipboard() async throws {
        let api = QuickCaptureAPISpy(statuses: [])
        let presenter = AdaptiveResultPresenterSpy()
        let controller = RegionCaptureController(
            captureController: CaptureController(api: api, sleep: { _ in }),
            regionCapture: DesignRegionCaptureSpy(result: .failure(DesignRegionCaptureError.cancelled)),
            registrar: HotkeyRegistrarSpy(),
            resultPresenter: presenter
        )

        await controller.captureRegion()
        #expect(await api.requests.isEmpty)
        #expect(presenter.failures.isEmpty)
        #expect(controller.errorMessage == nil)

        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("Capture/DesignRegionCapture.swift"),
            encoding: .utf8
        )
        #expect(source.contains("ScreenCaptureKit"))
        #expect(source.contains("Drag to capture a region"))
        #expect(!source.contains("Process()"))
        #expect(!source.contains("NSPasteboard"))
        #expect(!source.contains("CGDisplayCreateImage"))
    }

    @Test
    func failedRegionCaptureRemainsVisibleInSettingsState() async {
        let api = QuickCaptureAPISpy(statuses: [])
        let presenter = AdaptiveResultPresenterSpy()
        let controller = RegionCaptureController(
            captureController: CaptureController(api: api, sleep: { _ in }),
            regionCapture: DesignRegionCaptureSpy(result: .failure(
                DesignRegionCaptureError.screenshotFailed
            )),
            registrar: HotkeyRegistrarSpy(),
            resultPresenter: presenter
        )

        await controller.captureRegion()

        #expect(await api.requests.isEmpty)
        #expect(controller.errorMessage == "The selected region could not be captured.")
        #expect(presenter.failures == [.captureFailed])
    }

    @Test
    func shortcutDefaultsToControlOptionBAndPersistsOnlyValidatedChanges() throws {
        let defaults = try testDefaults()
        let panel = HotkeyPanelSpy()
        let registrar = HotkeyRegistrarSpy()
        let applications = FrontmostApplicationSpy(identity: nil)
        let controller = CaptureHotkeyController(
            panel: panel,
            defaults: defaults,
            registrar: registrar,
            applications: applications
        )

        #expect(controller.hotkey == .controlOptionB)
        #expect(controller.hotkey.keyCode == 11)
        #expect(controller.hotkey.modifiers == [.control, .option])
        #expect(controller.start())
        #expect(registrar.registered == [.controlOptionB])

        #expect(throws: CaptureHotkeyError.invalidShortcut) {
            try controller.record(keyCode: 0, modifiers: [])
        }
        #expect(throws: CaptureHotkeyError.invalidShortcut) {
            try controller.record(keyCode: 0, modifiers: [.shift])
        }
        #expect(throws: CaptureHotkeyError.invalidShortcut) {
            try controller.record(keyCode: 55, modifiers: [.command])
        }
        #expect(throws: CaptureHotkeyError.invalidShortcut) {
            try controller.record(
                keyCode: 0,
                modifiers: CaptureHotkeyModifiers(rawValue: 1 << 10).union(.command)
            )
        }
        #expect(registrar.registered == [.controlOptionB])

        let custom = CaptureHotkey(keyCode: 40, modifiers: [.command, .shift])
        try controller.record(keyCode: custom.keyCode, modifiers: custom.modifiers)
        #expect(controller.hotkey == custom)
        #expect(controller.isRegistered)

        let restoredPanel = HotkeyPanelSpy()
        let restored = CaptureHotkeyController(
            panel: restoredPanel,
            defaults: defaults,
            registrar: HotkeyRegistrarSpy(),
            applications: applications
        )
        #expect(restored.hotkey == custom)

        defaults.set(0, forKey: CaptureHotkeyController.modifiersDefaultsKey)
        let invalidStoredPanel = HotkeyPanelSpy()
        let invalidStored = CaptureHotkeyController(
            panel: invalidStoredPanel,
            defaults: defaults,
            registrar: HotkeyRegistrarSpy(),
            applications: applications
        )
        #expect(invalidStored.hotkey == .controlOptionB)
    }

    @Test
    func shortcutSnapshotsFrontmostApplicationBeforeOpeningPanel() throws {
        let defaults = try testDefaults()
        var events: [String] = []
        let identity = QuickCaptureApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor"
        )
        let applications = FrontmostApplicationSpy(identity: identity) {
            events.append("frontmost")
        }
        let panel = HotkeyPanelSpy {
            events.append("panel")
        }
        let registrar = HotkeyRegistrarSpy()
        let controller = CaptureHotkeyController(
            panel: panel,
            defaults: defaults,
            registrar: registrar,
            applications: applications
        )
        #expect(controller.start())

        registrar.trigger()

        #expect(events == ["frontmost", "panel"])
        #expect(panel.sources == [identity])
    }

    @Test
    func productionShortcutStartsAdaptiveCaptureWithoutOpeningPanel() async throws {
        let defaults = try testDefaults()
        let identity = QuickCaptureApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor"
        )
        let panel = HotkeyPanelSpy()
        let adaptive = AdaptiveCaptureSpy()
        let registrar = HotkeyRegistrarSpy()
        let controller = CaptureHotkeyController(
            panel: panel,
            defaults: defaults,
            registrar: registrar,
            applications: FrontmostApplicationSpy(identity: identity),
            adaptiveCapture: adaptive
        )
        #expect(controller.start())

        registrar.trigger()
        await adaptive.waitForCapture()

        #expect(adaptive.sources == [identity])
        #expect(panel.sources.isEmpty)
    }

    @Test
    func carbonRegistrarRegistersDispatchesRollsBackConflictsAndUnregisters() throws {
        let defaults = try testDefaults()
        let panel = HotkeyPanelSpy()
        let carbon = CarbonHotKeyInstallerSpy()
        let registrar = SystemCaptureHotkeyRegistrar(carbon: carbon)
        let controller = CaptureHotkeyController(
            panel: panel,
            defaults: defaults,
            registrar: registrar,
            applications: FrontmostApplicationSpy(identity: nil)
        )

        #expect(controller.start())
        #expect(carbon.installed == [.controlOptionB])
        carbon.dispatch()
        #expect(panel.sources.count == 1)

        let replacement = CaptureHotkey(keyCode: 40, modifiers: [.command, .shift])
        carbon.nextError = .shortcutUnavailable
        #expect(throws: CaptureHotkeyError.shortcutUnavailable) {
            try controller.record(
                keyCode: replacement.keyCode,
                modifiers: replacement.modifiers
            )
        }

        #expect(controller.hotkey == .controlOptionB)
        #expect(controller.isRegistered)
        #expect(carbon.installed == [.controlOptionB, replacement, .controlOptionB])
        #expect(carbon.cancellationCount == 1)

        carbon.dispatch()
        #expect(panel.sources.count == 2)
        controller.stop()
        #expect(!controller.isRegistered)
        #expect(carbon.cancellationCount == 2)
        carbon.dispatch()
        #expect(panel.sources.count == 2)
    }

    @Test
    func clipboardIsReadOnceOnlyAfterPanelOpensInLinkMode() {
        let clipboard = QuickClipboardSpy(text: " https://example.com/path?q=1 ")
        let controller = makeQuickController(mode: .link, clipboard: clipboard)

        #expect(clipboard.textReads == 0)
        controller.prepareToOpen(sourceApplication: nil)
        #expect(clipboard.textReads == 0)
        #expect(controller.url.isEmpty)

        controller.panelDidOpen()
        #expect(clipboard.textReads == 1)
        #expect(controller.url == "https://example.com/path?q=1")

        controller.panelDidOpen()
        controller.selectMode(.note)
        controller.selectMode(.link)
        #expect(clipboard.textReads == 1)

        let noteClipboard = QuickClipboardSpy(text: "https://brain.example")
        let note = makeQuickController(mode: .note, clipboard: noteClipboard)
        note.prepareToOpen(sourceApplication: nil)
        note.panelDidOpen()
        #expect(noteClipboard.textReads == 0)
        note.selectMode(.design)
        #expect(noteClipboard.textReads == 0)
        note.selectMode(.link)
        #expect(noteClipboard.textReads == 1)
    }

    @Test
    func clipboardPrefillRejectsAnythingExceptExplicitSafeHTTPURLs() {
        let rejected = [
            "example.com/no-scheme",
            "ftp://example.com/file",
            "javascript:alert(1)",
            "https://user:secret@example.com/private",
            "https://example.com\nhttps://attacker.example",
            "not a URL",
            "",
        ]
        for value in rejected {
            #expect(QuickCaptureController.clipboardURL(value) == nil)
        }
        #expect(
            QuickCaptureController.clipboardURL("http://example.com")
                == "http://example.com"
        )
        #expect(
            QuickCaptureController.clipboardURL("https://example.com/design#card")
                == "https://example.com/design#card"
        )

        let clipboard = QuickClipboardSpy(text: "file:///tmp/private-example")
        let controller = makeQuickController(mode: .link, clipboard: clipboard)
        controller.prepareToOpen(sourceApplication: nil)
        controller.panelDidOpen()
        #expect(clipboard.textReads == 1)
        #expect(controller.url.isEmpty)
    }

    @Test
    func adaptiveSelectedURLTakesPrecedenceAndIsQueuedOnceUnchanged() async throws {
        let selectedURL = "HTTPS://Example.COM/path?q=one#section"
        let selectedText = SelectedTextReaderSpy(result: .success(SelectedTextSnapshot(
            selectedText: "  \(selectedURL)\n",
            windowTitle: "Article"
        )))
        let picker = DesignPickerSpy(result: .failure(DesignWindowCaptureError.pickerFailed))
        let api = QuickCaptureAPISpy(statuses: [])
        let capture = CaptureController(api: api, sleep: { _ in })
        let results = AdaptiveResultPresenterSpy()
        let controller = AdaptiveCaptureController(
            captureController: capture,
            selectedTextReader: selectedText,
            designCapture: DesignWindowCapture(
                picker: picker,
                screenshotter: DesignScreenshotSpy(data: quickPNG)
            ),
            resultPresenter: results
        )

        await controller.capture(from: QuickCaptureApplicationIdentity(
            processIdentifier: 7,
            bundleIdentifier: "com.example.browser",
            localizedName: "Browser"
        ))

        #expect(await api.requests == [BrainCaptureRequest(
            url: selectedURL,
            source: CaptureController.source
        )])
        #expect(await picker.calls == 0)
        #expect(results.failures.isEmpty)
        #expect(capture.queuedReceipt != nil)
    }

    @Test
    func adaptiveURLValidationRejectsUnsafeCredentialsAndMultipleSelections() {
        let rejected: [String?] = [
            "javascript:alert(1)",
            "file:///tmp/private-example",
            "data:text/plain,secret",
            "https://user:secret@example.com/private",
            "https://first.example\nhttps://second.example",
            "https://first.example,https://second.example",
            "https://example.com:70000/path",
            "not a URL",
            nil,
        ]
        for selection in rejected {
            #expect(SelectedHTTPURL.parse(selection) == nil)
        }
        #expect(SelectedHTTPURL.parse(" http://localhost:8787/path ") == "http://localhost:8787/path")
        #expect(SelectedHTTPURL.parse("http://[::1]:8787/path") == "http://[::1]:8787/path")
    }

    @Test
    func adaptiveInvalidSelectionFallsBackToOnePNGWithSanitizedSourceContext() async throws {
        let selectedText = SelectedTextReaderSpy(result: .success(SelectedTextSnapshot(
            selectedText: "ordinary selected words",
            windowTitle: "  Roadmap\tWindow\nQ3\u{0000}  "
        )))
        let picker = DesignPickerSpy(result: .success(DesignWindowSelection(
            kind: .window,
            pixelWidth: 800,
            pixelHeight: 600,
            identifier: "chosen-window"
        )))
        let screenshotter = DesignScreenshotSpy(data: quickPNG)
        let api = QuickCaptureAPISpy(statuses: [])
        let capture = CaptureController(api: api, sleep: { _ in })
        let results = AdaptiveResultPresenterSpy()
        let controller = AdaptiveCaptureController(
            captureController: capture,
            selectedTextReader: selectedText,
            designCapture: DesignWindowCapture(
                picker: picker,
                screenshotter: screenshotter
            ),
            resultPresenter: results
        )

        await controller.capture(from: QuickCaptureApplicationIdentity(
            processIdentifier: 8,
            bundleIdentifier: "com.example.private.identifier",
            localizedName: "Browser\nBeta"
        ))

        let request = try #require(await api.requests.first)
        #expect(await api.requests.count == 1)
        #expect(request.type == .design)
        #expect(request.text == "Source application: Browser Beta\nWindow title: Roadmap Window Q3")
        #expect(request.image == "data:image/png;base64,\(quickPNG.base64EncodedString())")
        #expect(request.source == CaptureController.source)
        #expect(!String(describing: request).contains("com.example.private.identifier"))
        #expect(await picker.calls == 1)
        #expect(await screenshotter.identifiers == ["chosen-window"])
        #expect(results.failures.isEmpty)
        #expect(capture.draft.image == nil)
    }

    @Test
    func adaptiveCancellationPermissionDenialAndCaptureFailureQueueNothingSafely() async {
        let source = QuickCaptureApplicationIdentity(
            processIdentifier: 9,
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor"
        )

        let deniedPicker = DesignPickerSpy(result: .failure(DesignWindowCaptureError.pickerFailed))
        let deniedAPI = QuickCaptureAPISpy(statuses: [])
        let deniedResults = AdaptiveResultPresenterSpy()
        let denied = AdaptiveCaptureController(
            captureController: CaptureController(api: deniedAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(
                result: .failure(SelectedTextReaderError.accessibilityDenied)
            ),
            designCapture: DesignWindowCapture(
                picker: deniedPicker,
                screenshotter: DesignScreenshotSpy(data: quickPNG)
            ),
            resultPresenter: deniedResults
        )
        await denied.capture(from: source)
        #expect(await deniedAPI.requests.isEmpty)
        #expect(await deniedPicker.calls == 0)
        #expect(deniedResults.failures == [.accessibilityDenied])

        let missingAPI = QuickCaptureAPISpy(statuses: [])
        let missingResults = AdaptiveResultPresenterSpy()
        let missing = AdaptiveCaptureController(
            captureController: CaptureController(api: missingAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(
                result: .failure(SelectedTextReaderError.sourceUnavailable)
            ),
            resultPresenter: missingResults
        )
        await missing.capture(from: source)
        #expect(await missingAPI.requests.isEmpty)
        #expect(missingResults.failures == [.sourceUnavailable])

        let cancelledAPI = QuickCaptureAPISpy(statuses: [])
        let cancelledResults = AdaptiveResultPresenterSpy()
        let cancelled = AdaptiveCaptureController(
            captureController: CaptureController(api: cancelledAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(result: .success(SelectedTextSnapshot(
                selectedText: nil,
                windowTitle: "Document"
            ))),
            designCapture: DesignWindowCapture(
                picker: DesignPickerSpy(
                    result: .failure(DesignWindowCaptureError.pickerCancelled)
                ),
                screenshotter: DesignScreenshotSpy(data: quickPNG)
            ),
            resultPresenter: cancelledResults
        )
        await cancelled.capture(from: source)
        #expect(await cancelledAPI.requests.isEmpty)
        #expect(cancelledResults.failures == [.pickerCancelled])

        let failedAPI = QuickCaptureAPISpy(statuses: [])
        let failedResults = AdaptiveResultPresenterSpy()
        let failed = AdaptiveCaptureController(
            captureController: CaptureController(api: failedAPI, sleep: { _ in }),
            selectedTextReader: SelectedTextReaderSpy(result: .success(SelectedTextSnapshot(
                selectedText: "not a URL",
                windowTitle: "Document"
            ))),
            designCapture: DesignWindowCapture(
                picker: DesignPickerSpy(result: .success(DesignWindowSelection(
                    kind: .window,
                    pixelWidth: 640,
                    pixelHeight: 480
                ))),
                screenshotter: DesignScreenshotSpy(
                    result: .failure(DesignWindowCaptureError.screenshotFailed)
                )
            ),
            resultPresenter: failedResults
        )
        await failed.capture(from: source)
        #expect(await failedAPI.requests.isEmpty)
        #expect(failedResults.failures == [.captureFailed])
        for failure in deniedResults.failures + missingResults.failures
            + cancelledResults.failures + failedResults.failures {
            #expect(!failure.recoverySuggestion.contains("com.example.editor"))
            #expect(!failure.recoverySuggestion.contains("Document"))
        }
    }

    @Test
    func modesAreExplicitAndEscapeClosesWithoutSubmitting() async {
        #expect(QuickCaptureMode.allCases == [.note, .link, .design])
        #expect(QuickCaptureMode.link.title == "Link / Bookmark")
        let api = QuickCaptureAPISpy(statuses: [])
        let capture = CaptureController(api: api, sleep: { _ in })
        let controller = makeQuickController(captureController: capture)
        let identity = QuickCaptureApplicationIdentity(
            processIdentifier: 7,
            bundleIdentifier: "com.example.browser",
            localizedName: "Browser"
        )
        var dismissals = 0
        controller.setDismissHandler { dismissals += 1 }
        controller.prepareToOpen(sourceApplication: identity)
        controller.panelDidOpen()
        controller.noteText = "must not be sent"

        controller.escape()

        #expect(!controller.isPresented)
        #expect(controller.sourceApplication == identity)
        #expect(dismissals == 1)
        #expect(await api.requests.isEmpty)
    }

    @Test
    func designCaptureUsesOnePickerSelectionAndValidatesWindowAndPNG() async throws {
        let picker = DesignPickerSpy(result: .success(DesignWindowSelection(
            kind: .window,
            pixelWidth: 800,
            pixelHeight: 600,
            identifier: "chosen"
        )))
        let screenshotter = DesignScreenshotSpy(data: quickPNG)
        let capture = DesignWindowCapture(picker: picker, screenshotter: screenshotter)

        let payload = try await capture.captureSelectedWindow()

        #expect(payload.data == quickPNG)
        #expect(payload.mimeType == "image/png")
        #expect(await picker.calls == 1)
        #expect(await screenshotter.identifiers == ["chosen"])

        let wrongPicker = DesignPickerSpy(result: .success(DesignWindowSelection(
            kind: .other,
            pixelWidth: 1920,
            pixelHeight: 1080
        )))
        let unusedScreenshotter = DesignScreenshotSpy(data: quickPNG)
        let wrongCapture = DesignWindowCapture(
            picker: wrongPicker,
            screenshotter: unusedScreenshotter
        )
        await #expect(throws: DesignWindowCaptureError.selectionIsNotAWindow) {
            _ = try await wrongCapture.captureSelectedWindow()
        }
        #expect(await unusedScreenshotter.identifiers.isEmpty)

        let badPNG = DesignWindowCapture(
            picker: DesignPickerSpy(result: .success(DesignWindowSelection(
                kind: .window,
                pixelWidth: 100,
                pixelHeight: 100
            ))),
            screenshotter: DesignScreenshotSpy(data: Data("not png".utf8))
        )
        await #expect(throws: DesignWindowCaptureError.invalidPNG) {
            _ = try await badPNG.captureSelectedWindow()
        }
    }

    @Test
    func designRequiresSearchableContextBeforeOpeningPicker() async {
        let picker = DesignPickerSpy(result: .success(DesignWindowSelection(
            kind: .window,
            pixelWidth: 400,
            pixelHeight: 300
        )))
        let screenshotter = DesignScreenshotSpy(data: quickPNG)
        let controller = makeQuickController(
            mode: .design,
            designCapture: DesignWindowCapture(picker: picker, screenshotter: screenshotter)
        )
        controller.prepareToOpen(sourceApplication: nil)
        controller.panelDidOpen()

        await controller.chooseDesignWindow()
        #expect(await picker.calls == 0)
        #expect(controller.designImage == nil)
        #expect(
            controller.errorMessage
                == QuickCaptureValidationError.missingDesignContext.localizedDescription
        )

        controller.designContext = "Dark editorial dashboard with high-contrast cards"
        await controller.chooseDesignWindow()
        #expect(await picker.calls == 1)
        #expect(controller.designImage?.mimeType == "image/png")
    }

    @Test
    func submitDelegatesExactDraftAndDeliveryStateToExistingCaptureController() async {
        let id = "11111111-2222-4333-8444-555555555555"
        let api = QuickCaptureAPISpy(statuses: [quickStatus(id: id, state: .delivered)])
        let capture = CaptureController(api: api, sleep: { _ in })
        let clipboard = QuickClipboardSpy(text: "https://example.com/article")
        let controller = makeQuickController(
            mode: .link,
            captureController: capture,
            clipboard: clipboard
        )
        controller.prepareToOpen(sourceApplication: nil)
        controller.panelDidOpen()
        controller.comment = "Why this matters"
        controller.selectedText = "Exact selected words"

        await controller.submit()
        await capture.waitForMonitoring()

        #expect(await api.requests == [BrainCaptureRequest(
            url: "https://example.com/article",
            text: "Exact selected words",
            note: "Why this matters",
            source: CaptureController.source
        )])
        #expect(capture.observedSubmissionStates == [
            .sending,
            .queued(id: id),
            .delivered(id: id),
        ])
        #expect(capture.submissionState == .delivered(id: id))
        #expect(controller.captureController === capture)
    }

    @Test
    func retryableDeliveryKeepsStableCapturePayloadUntilExplicitRetry() async {
        let id = "11111111-2222-4333-8444-555555555555"
        let api = QuickCaptureAPISpy(statuses: [quickStatus(
            id: id,
            state: .failed,
            retryable: true,
            error: "Temporary delivery failure"
        )])
        let capture = CaptureController(api: api, sleep: { _ in })
        let controller = makeQuickController(
            mode: .link,
            captureController: capture,
            clipboard: QuickClipboardSpy(text: "https://example.com/original")
        )
        controller.prepareToOpen(sourceApplication: nil)
        controller.panelDidOpen()
        controller.comment = "original comment"

        await controller.submit()
        await capture.waitForMonitoring()
        let stableDraft = capture.draft
        #expect(capture.submissionState == .retryAvailable(id: id))
        #expect(capture.canRetry)

        controller.url = "https://example.com/replacement"
        controller.comment = "must not replace the retry payload"
        await controller.submit()
        await capture.waitForMonitoring()

        #expect(capture.draft == stableDraft)
        #expect(await api.requests.count == 1)
        #expect(
            controller.errorMessage
                == QuickCaptureValidationError.captureDeliveryBusy.localizedDescription
        )
    }

    @Test
    func unresolvedOnboardingPermissionDisablesOnlySelectedActionAndExposesExactAction() async {
        let gate = QuickPermissionGateSpy(blocks: [
            .design: QuickCapturePermissionBlock(
                checkID: .systemAudio,
                detail: "Allow Screen Recording in System Settings.",
                action: .openSystemSettings(.systemAudio)
            ),
        ])
        let picker = DesignPickerSpy(result: .success(DesignWindowSelection(
            kind: .window,
            pixelWidth: 300,
            pixelHeight: 200
        )))
        let controller = makeQuickController(
            mode: .note,
            designCapture: DesignWindowCapture(
                picker: picker,
                screenshotter: DesignScreenshotSpy(data: quickPNG)
            ),
            permissionGate: gate
        )
        controller.prepareToOpen(sourceApplication: nil)
        controller.panelDidOpen()
        #expect(controller.permissionBlock == nil)
        #expect(controller.canSubmit)

        controller.selectMode(.design)
        controller.designContext = "searchable context"
        #expect(controller.permissionBlock?.checkID == .systemAudio)
        #expect(
            controller.permissionBlock?.action == .openSystemSettings(.systemAudio)
        )
        #expect(!controller.canSubmit)
        await controller.chooseDesignWindow()
        #expect(await picker.calls == 0)

        await controller.performPermissionAction()
        #expect(gate.performed == [.openSystemSettings(.systemAudio)])
    }

    @Test
    func productionSourcesKeepPickerOnlyAndAvoidBackgroundClipboardOrBrowserAccess() throws {
        let sources = sourceDirectory
        let hotkey = try String(
            contentsOf: sources.appendingPathComponent("Capture/CaptureHotkeyController.swift"),
            encoding: .utf8
        )
        let design = try String(
            contentsOf: sources.appendingPathComponent("Capture/DesignWindowCapture.swift"),
            encoding: .utf8
        )
        let panel = try String(
            contentsOf: sources.appendingPathComponent("Views/QuickCapturePanel.swift"),
            encoding: .utf8
        )
        let selectedText = try String(
            contentsOf: sources.appendingPathComponent("Capture/SelectedTextReader.swift"),
            encoding: .utf8
        )

        #expect(design.contains("SCContentSharingPicker"))
        #expect(design.contains("configuration.allowedPickerModes = .singleWindow"))
        #expect(!design.contains(".singleDisplay"))
        #expect(!design.contains("CGWindowListCreateImage"))
        #expect(!design.contains("CGDisplayCreateImage"))
        #expect(!hotkey.contains("NSPasteboard"))
        #expect(!hotkey.contains("NSAppleScript"))
        #expect(hotkey.contains("RegisterEventHotKey"))
        #expect(!hotkey.contains("addGlobalMonitorForEvents"))
        #expect(!panel.contains("NSAppleScript"))
        #expect(!panel.contains("ScriptingBridge"))
        #expect(!panel.contains("Process("))
        #expect(panel.components(separatedBy: "clipboard.readText()").count - 1 == 1)
        #expect(!selectedText.contains("NSPasteboard"))
        #expect(!selectedText.contains("AXIsProcessTrustedWithOptions"))
    }

    @Test
    func quickPanelHasKeyboardFocusAndSpokenDeliveryStates() throws {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("Views/QuickCapturePanel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("keyboardShortcut(.cancelAction)"))
        #expect(source.contains("keyboardShortcut(.defaultAction)"))
        #expect(source.contains("accessibilityFocused($accessibilityFocus, equals: .primaryField)"))
        #expect(source.contains("accessibilityFocused($accessibilityFocus, equals: .errorSummary)"))
        #expect(source.contains("brainAccessibleStatus(.queued"))
        #expect(source.contains("Delivered to the Brain inbox and awaiting Librarian processing"))
        #expect(source.contains("Delivered to Brain inbox"))
        #expect(source.contains("Awaiting Librarian processing and site publication."))
        #expect(source.contains(".waiting,"))
        #expect(source.contains("onExitCommand"))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu", isDirectory: true)
    }

    private func testDefaults() throws -> UserDefaults {
        let name = "QuickCaptureTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeQuickController(
        mode: QuickCaptureMode = .note,
        captureController: CaptureController? = nil,
        clipboard: QuickClipboardSpy = QuickClipboardSpy(text: nil),
        designCapture: DesignWindowCapture = DesignWindowCapture(
            picker: DesignPickerSpy(result: .failure(DesignWindowCaptureError.pickerCancelled)),
            screenshotter: DesignScreenshotSpy(data: quickPNG)
        ),
        permissionGate: QuickPermissionGateSpy = QuickPermissionGateSpy()
    ) -> QuickCaptureController {
        QuickCaptureController(
            mode: mode,
            captureController: captureController ?? CaptureController(
                api: QuickCaptureAPISpy(statuses: []),
                sleep: { _ in }
            ),
            clipboard: clipboard,
            designCapture: designCapture,
            permissionGate: permissionGate
        )
    }
}

@MainActor
private final class HotkeyRegistrarSpy: CaptureHotkeyRegistering {
    private(set) var registered: [CaptureHotkey] = []
    private(set) var unregisterCalls = 0
    private var action: (@MainActor () -> Void)?

    func register(_ hotkey: CaptureHotkey, action: @escaping @MainActor () -> Void) throws {
        registered.append(hotkey)
        self.action = action
    }

    func unregister() {
        unregisterCalls += 1
        action = nil
    }

    func trigger() {
        action?()
    }
}

@MainActor
private final class CarbonHotKeyInstallerSpy: CarbonHotKeyInstalling {
    private(set) var installed: [CaptureHotkey] = []
    private(set) var cancellationCount = 0
    var nextError: CaptureHotkeyError?
    private var action: (@MainActor () -> Void)?
    private var generation = 0

    func install(
        _ hotkey: CaptureHotkey,
        identifier: UInt32,
        action: @escaping @MainActor () -> Void
    ) throws -> CarbonHotKeyRegistration {
        installed.append(hotkey)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        generation += 1
        let registrationGeneration = generation
        self.action = action
        return CarbonHotKeyRegistration { [weak self] in
            guard let self else { return }
            self.cancellationCount += 1
            if self.generation == registrationGeneration {
                self.action = nil
            }
        }
    }

    func dispatch() {
        action?()
    }
}

@MainActor
private final class HotkeyPanelSpy: QuickCaptureOpening {
    private(set) var sources: [QuickCaptureApplicationIdentity?] = []
    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void = {}) {
        self.onOpen = onOpen
    }

    func open(sourceApplication: QuickCaptureApplicationIdentity?) {
        onOpen()
        sources.append(sourceApplication)
    }
}

@MainActor
private final class FrontmostApplicationSpy: FrontmostApplicationProviding {
    let identity: QuickCaptureApplicationIdentity?
    private let onRead: () -> Void

    init(
        identity: QuickCaptureApplicationIdentity?,
        onRead: @escaping () -> Void = {}
    ) {
        self.identity = identity
        self.onRead = onRead
    }

    var frontmostApplication: QuickCaptureApplicationIdentity? {
        onRead()
        return identity
    }
}

@MainActor
private final class AdaptiveCaptureSpy: AdaptiveCapturePerforming {
    private(set) var sources: [QuickCaptureApplicationIdentity?] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func capture(from application: QuickCaptureApplicationIdentity?) async {
        sources.append(application)
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForCapture() async {
        guard sources.isEmpty else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private final class SelectedTextReaderSpy: SelectedTextReading {
    let result: Result<SelectedTextSnapshot, Error>
    private(set) var applications: [QuickCaptureApplicationIdentity?] = []

    init(result: Result<SelectedTextSnapshot, Error>) {
        self.result = result
    }

    func snapshot(
        from application: QuickCaptureApplicationIdentity?
    ) throws -> SelectedTextSnapshot {
        applications.append(application)
        return try result.get()
    }
}

@MainActor
private final class AdaptiveResultPresenterSpy: AdaptiveCaptureResultPresenting {
    private(set) var failures: [AdaptiveCaptureFailure] = []

    func present(_ failure: AdaptiveCaptureFailure) {
        failures.append(failure)
    }
}

@MainActor
private final class DesignRegionCaptureSpy: DesignRegionCapturing {
    let result: Result<CaptureImagePayload, Error>
    private(set) var calls = 0

    init(result: Result<CaptureImagePayload, Error>) {
        self.result = result
    }

    func captureSelectedRegion() async throws -> CaptureImagePayload {
        calls += 1
        return try result.get()
    }
}

@MainActor
private final class QuickClipboardSpy: CaptureClipboardReading {
    let text: String?
    private(set) var textReads = 0
    private(set) var imageReads = 0

    init(text: String?) {
        self.text = text
    }

    func readText() -> String? {
        textReads += 1
        return text
    }

    func readImage() -> CaptureImagePayload? {
        imageReads += 1
        return nil
    }
}

private actor DesignPickerSpy: DesignWindowPicking {
    let result: Result<DesignWindowSelection, Error>
    private(set) var calls = 0

    init(result: Result<DesignWindowSelection, Error>) {
        self.result = result
    }

    func pickSingleWindow() async throws -> DesignWindowSelection {
        calls += 1
        return try result.get()
    }
}

private actor DesignScreenshotSpy: DesignWindowScreenshotting {
    let result: Result<Data, Error>
    private(set) var identifiers: [String] = []

    init(data: Data) {
        result = .success(data)
    }

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func capturePNG(for selection: DesignWindowSelection) async throws -> Data {
        identifiers.append(selection.identifier)
        return try result.get()
    }
}

@MainActor
private final class QuickPermissionGateSpy: QuickCapturePermissionGating {
    var blocks: [QuickCaptureMode: QuickCapturePermissionBlock]
    private(set) var performed: [OnboardingAction] = []

    init(blocks: [QuickCaptureMode: QuickCapturePermissionBlock] = [:]) {
        self.blocks = blocks
    }

    func unresolvedPermission(for mode: QuickCaptureMode) -> QuickCapturePermissionBlock? {
        blocks[mode]
    }

    func perform(_ action: OnboardingAction) async {
        performed.append(action)
    }
}

private actor QuickCaptureAPISpy: BrainCaptureAPI {
    let receiptID = "11111111-2222-4333-8444-555555555555"
    private var statuses: [BrainCaptureStatus]
    private(set) var requests: [BrainCaptureRequest] = []

    init(statuses: [BrainCaptureStatus]) {
        self.statuses = statuses
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        requests.append(capture)
        return BrainCaptureReceipt(id: receiptID, state: "queued")
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        if statuses.isEmpty {
            return quickStatus(id: id, state: .delivered)
        }
        return statuses.removeFirst()
    }
}

private func quickStatus(
    id: String,
    state: BrainCaptureState,
    retryable: Bool = false,
    error: String? = nil
) -> BrainCaptureStatus {
    BrainCaptureStatus(
        id: id,
        state: state,
        retryable: retryable,
        error: error,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        deliveredAt: state == .delivered ? Date(timeIntervalSince1970: 2) : nil
    )
}

private let quickPNG = Data([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
])
