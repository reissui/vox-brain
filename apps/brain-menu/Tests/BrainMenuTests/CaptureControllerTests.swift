import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct CaptureControllerTests {
    @Test
    func activityPersistsMetadataOnlyAndTracksDeliveryWithoutClaimingLibrarianCompletion() async throws {
        let id = "10101010-2020-4030-8040-505050505050"
        let suite = "CaptureController.Activity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = StatusCaptureAPISpy(
            captureResults: [.success(BrainCaptureReceipt(id: id, state: "queued"))],
            statusResults: [
                .success(captureStatus(id: id, state: .processing)),
                .success(captureStatus(id: id, state: .delivered)),
            ]
        )
        let controller = CaptureController(api: api, defaults: defaults, sleep: { _ in })
        controller.draft.noteText = "private note body must never enter activity storage"

        await controller.submit()
        await controller.waitForMonitoring()

        let record = try #require(controller.activities.first)
        #expect(record.captureID == id)
        #expect(record.kind == .note)
        #expect(record.label == "Note")
        #expect(record.stage == .delivered)
        #expect(record.error == nil)
        let stored = try #require(defaults.data(forKey: CaptureController.activityDefaultsKey))
        #expect(!String(decoding: stored, as: UTF8.self).contains("private note body"))

        let relaunched = CaptureController(api: api, defaults: defaults, sleep: { _ in })
        #expect(relaunched.activities.map(\.id) == controller.activities.map(\.id))
        #expect(relaunched.activities.first?.captureID == id)
        #expect(relaunched.activities.first?.stage == .delivered)
        relaunched.clearCompletedActivity()
        #expect(relaunched.activities.isEmpty)
    }

    @Test
    func activityRefreshRecoversEveryAcceptedCaptureLeftQueuedAcrossRelaunch() async throws {
        let id = "12121212-3434-4567-8567-898989898989"
        let suite = "CaptureController.ActivityRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode([CaptureActivityRecord(
            id: "local-activity",
            captureID: id,
            kind: .image,
            label: "Region Screenshot.png",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101),
            stage: .queued,
            error: nil
        )]), forKey: CaptureController.activityDefaultsKey)
        let api = StatusCaptureAPISpy(
            captureResults: [],
            statusResults: [.success(captureStatus(id: id, state: .delivered))]
        )

        let controller = CaptureController(api: api, defaults: defaults, sleep: { _ in })
        await controller.waitForMonitoring()

        #expect(await api.calls.isEmpty)
        #expect(await api.statusIDs == [id])
        #expect(controller.activities.first?.stage == .delivered)
    }

    @Test
    func activityRefreshMergesRemoteMCPFilesAndDeliveryStateWithoutPrivateContent() async throws {
        let mcpID = "13131313-3434-4567-8567-898989898989"
        let appID = "14141414-3434-4567-8567-898989898989"
        let created = Date(timeIntervalSince1970: 1_784_112_400)
        let api = StatusCaptureAPISpy(
            captureResults: [],
            statusResults: [],
            listResults: [.success(BrainCaptureListResponse(captures: [
                BrainCaptureStatus(
                    id: mcpID,
                    type: .note,
                    source: "MCP · Codex · Brain planning",
                    state: .processing,
                    retryable: false,
                    error: nil,
                    createdAt: created.addingTimeInterval(10),
                    updatedAt: created.addingTimeInterval(20),
                    deliveredAt: nil,
                    object: BrainCaptureObjectMetadata(
                        sha256: String(repeating: "a", count: 64),
                        contentType: "application/pdf",
                        byteLength: 42,
                        filename: "Planning.pdf",
                        retention: "permanent",
                        href: "/v1/captures/\(mcpID)/object"
                    )
                ),
                BrainCaptureStatus(
                    id: appID,
                    type: .transcript,
                    source: "Brain.app",
                    state: .delivered,
                    retryable: false,
                    error: nil,
                    createdAt: created,
                    updatedAt: created.addingTimeInterval(30),
                    deliveredAt: created.addingTimeInterval(30)
                ),
            ]))]
        )

        let controller = CaptureController(api: api, sleep: { _ in })
        await controller.waitForMonitoring()

        #expect(controller.activities.map(\.captureID) == [mcpID, appID])
        let mcp = try #require(controller.activities.first)
        #expect(mcp.label == "Planning.pdf")
        #expect(mcp.kind == nil)
        #expect(mcp.source == "MCP · Codex · Brain planning")
        #expect(mcp.stage == .delivering)
        #expect(controller.activities[1].label == "Transcript")
        #expect(controller.activities[1].kind == .transcript)
        #expect(controller.activities[1].stage == .delivered)
        #expect(await api.listCallCount == 1)
        #expect(await api.statusIDs.isEmpty)
    }

    @Test
    func clearingDeliveredRemoteActivityKeepsItDismissedOnRefresh() async {
        let id = "16161616-3434-4567-8567-898989898989"
        let status = BrainCaptureStatus(
            id: id,
            type: .note,
            source: "MCP",
            state: .delivered,
            retryable: false,
            error: nil,
            createdAt: Date(timeIntervalSince1970: 1_784_112_400),
            updatedAt: Date(timeIntervalSince1970: 1_784_112_430),
            deliveredAt: Date(timeIntervalSince1970: 1_784_112_430)
        )
        let response = BrainCaptureListResponse(captures: [status])
        let api = StatusCaptureAPISpy(
            captureResults: [],
            statusResults: [],
            listResults: [.success(response), .success(response)]
        )
        let controller = CaptureController(api: api, sleep: { _ in })
        await controller.waitForMonitoring()
        #expect(controller.activities.map(\.captureID) == [id])

        controller.clearCompletedActivity()
        controller.checkAgain()
        await controller.waitForMonitoring()

        #expect(controller.activities.isEmpty)
        #expect(await api.listCallCount == 2)
    }

    @Test
    func sendsEveryCaptureKindAndPreservesVerbatimTextIncludingDictationInsertion() async throws {
        let api = CaptureAPISpy(results: [
            .success(BrainCaptureReceipt(id: "note-1", state: "queued")),
            .success(BrainCaptureReceipt(id: "link-1", state: "queued")),
            .success(BrainCaptureReceipt(id: "image-1", state: "queued")),
            .success(BrainCaptureReceipt(id: "transcript-1", state: "queued")),
        ])
        let keys = UUIDSequence([
            uuid("00000000-0000-4000-8000-000000000001"),
            uuid("00000000-0000-4000-8000-000000000002"),
            uuid("00000000-0000-4000-8000-000000000003"),
            uuid("00000000-0000-4000-8000-000000000004"),
        ])
        let controller = CaptureController(api: api, makeUUID: keys.next, sleep: { _ in })

        let dictatedText = "  Dictated by Parakeet: café — exact words\nsecond line  "
        controller.draft.noteText = dictatedText
        await controller.submit()

        controller.draft.kind = .link
        controller.draft.url = "example.com/bookmark"
        controller.draft.comment = "  why I saved it  "
        controller.draft.selectedText = " Selection\nkept verbatim "
        await controller.submit()

        controller.acceptDroppedImage(
            data: pngData,
            mimeType: "image/png",
            filename: "Design board.png"
        )
        controller.draft.imageContext = "  Warm editorial cards, serif headings  "
        await controller.submit()

        controller.draft.kind = .transcript
        controller.draft.transcriptFilename = "Planning.md"
        controller.draft.transcriptText = " Speaker A: exact words\nSpeaker B: café "
        await controller.submit()

        let calls = await api.calls
        #expect(calls.count == 4)
        #expect(Set(calls.map(\.idempotencyKey)).count == 4)
        #expect(calls[0].request == BrainCaptureRequest(
            type: .note,
            text: dictatedText,
            source: "Brain.app"
        ))
        #expect(calls[1].request == BrainCaptureRequest(
            url: "https://example.com/bookmark",
            text: " Selection\nkept verbatim ",
            note: "  why I saved it  ",
            source: "Brain.app"
        ))
        #expect(calls[2].request.type == .design)
        #expect(calls[2].request.text == "  Warm editorial cards, serif headings  ")
        #expect(calls[2].request.image == "data:image/png;base64,\(pngData.base64EncodedString())")
        #expect(calls[3].request == BrainCaptureRequest(
            type: .transcript,
            source: "Brain.app",
            transcript: " Speaker A: exact words\nSpeaker B: café ",
            title: "Planning.md"
        ))
        #expect(controller.submissionState == .queued(id: "transcript-1"))
    }

    @Test
    func rejectsEmptyAndInvalidDraftsLocallyWithExactErrors() async {
        let api = CaptureAPISpy(results: [])
        let controller = CaptureController(api: api)

        await controller.submit()
        #expect(controller.errorMessage == "Enter note text before sending.")

        controller.draft.kind = .link
        controller.draft.url = "ssh://host/path"
        await controller.submit()
        #expect(controller.errorMessage == "Enter a valid HTTP or HTTPS URL.")

        controller.draft.kind = .image
        controller.draft.image = CaptureImagePayload(
            data: pngData,
            mimeType: "image/gif",
            filename: "motion.gif"
        )
        controller.draft.imageContext = "search context"
        await controller.submit()
        #expect(controller.errorMessage == "Image must be JPEG, PNG, or WebP.")

        controller.draft.image = CaptureImagePayload(
            data: pngData,
            mimeType: "image/png",
            filename: "board.png"
        )
        controller.draft.imageContext = ""
        await controller.submit()
        #expect(controller.errorMessage == "Add searchable context for this design image.")

        var decodedOversize = pngData
        decodedOversize.append(Data(repeating: 0, count: CaptureController.maximumDecodedImageBytes))
        controller.draft.image = CaptureImagePayload(
            data: decodedOversize,
            mimeType: "image/png",
            filename: "large.png"
        )
        controller.draft.imageContext = "search context"
        await controller.submit()
        #expect(controller.errorMessage == "Image must be 4 MiB or smaller.")

        var encodedOversize = pngData
        encodedOversize.append(Data(repeating: 0, count: 5 * 1_024 * 1_024))
        controller.draft.image = CaptureImagePayload(
            data: encodedOversize,
            mimeType: "image/png",
            filename: "huge.png"
        )
        await controller.submit()
        #expect(controller.errorMessage == "Encoded image must be 6 MiB or smaller.")

        controller.draft.kind = .transcript
        controller.draft.transcriptFilename = "meeting.pdf"
        controller.draft.transcriptText = "verbatim"
        await controller.submit()
        #expect(controller.errorMessage == "Transcript must be a .md or .txt file.")

        #expect(await api.calls.isEmpty)
    }

    @Test
    func automaticallyRetriesWithOneStableIdempotencyKey() async {
        let api = CaptureAPISpy(results: [
            .failure(.transport),
            .success(BrainCaptureReceipt(id: "capture-after-retry", state: "queued")),
        ])
        let key = uuid("11111111-2222-4333-8444-555555555555")
        let controller = CaptureController(api: api, makeUUID: { key }, sleep: { _ in })
        controller.draft.noteText = "retry this exact payload"

        await controller.submit()

        let calls = await api.calls
        #expect(calls.count == 2)
        #expect(calls[0].idempotencyKey == key)
        #expect(calls[1].idempotencyKey == key)
        #expect(calls[0].request == calls[1].request)
        #expect(controller.submissionState == .queued(id: "capture-after-retry"))
    }

    @Test
    func queuedSuccessRequiresTheQueuedReceiptReturnedByHTTP202() async {
        let api = CaptureAPISpy(results: [
            .success(BrainCaptureReceipt(id: "not-durable", state: "accepted")),
        ])
        let controller = CaptureController(api: api)
        controller.draft.noteText = "do not show a false success"

        await controller.submit()

        #expect(controller.submissionState == .failed)
        #expect(controller.queuedReceipt == nil)
        #expect(controller.errorMessage == "Brain did not confirm that the capture was queued.")
        #expect(controller.draft.noteText == "do not show a false success")
    }

    @Test
    func pairedTransportRejectsQueuedJSONUnlessTheHTTPStatusIsExactly202() async throws {
        let statuses = CaptureLockedBox([200, 202])
        let requests = CaptureLockedBox<[URLRequest]>([])
        CaptureURLProtocol.install { request in
            requests.withLock { $0.append(request) }
            let status = statuses.withLock { $0.removeFirst() }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"capture-202","state":"queued"}"#.utf8))
        }
        defer { CaptureURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        let metadata = BrainInstanceMetadata(
            baseURL: URL(string: "https://brain.example.test")!,
            instanceID: "brain-owner",
            deviceID: "device-1",
            deviceName: "the owner Mac",
            scopes: [.capture]
        )
        let api = PairedCaptureClient(
            metadata: metadata,
            session: URLSession(configuration: configuration),
            credentialStore: CaptureMemoryCredentials(token: "paired-token")
        )
        let request = BrainCaptureRequest(type: .note, text: "durable only", source: "Brain.app")

        do {
            _ = try await api.capture(
                request,
                idempotencyKey: uuid("12345678-1234-4234-8234-123456789abc")
            )
            Issue.record("HTTP 200 must not be displayed as queued")
        } catch let error as BrainAPIError {
            #expect(error == .http(
                status: 200,
                code: "expected_http_202",
                message: "Brain did not return HTTP 202 Accepted.",
                requestID: nil
            ))
        }

        let receipt = try await api.capture(
            request,
            idempotencyKey: uuid("12345678-1234-4234-8234-123456789abd")
        )

        #expect(receipt == BrainCaptureReceipt(id: "capture-202", state: "queued"))
        #expect(requests.value.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == [
            "12345678-1234-4234-8234-123456789abc",
            "12345678-1234-4234-8234-123456789abd",
        ])
        #expect(requests.value.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer paired-token"
        })
    }

    @Test
    func failureRetainsDraftAndManualRetryWithoutAnyLocalFallback() async {
        let api = CaptureAPISpy(results: [
            .failure(.transport),
            .failure(.timedOut),
            .success(BrainCaptureReceipt(id: "eventually-queued", state: "queued")),
        ])
        let key = uuid("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let controller = CaptureController(api: api, makeUUID: { key })
        let exactDraft = "offline draft\nkept only in memory"
        controller.draft.noteText = exactDraft

        await controller.submit()

        #expect(controller.submissionState == .failed)
        #expect(controller.canRetry == false)
        #expect(controller.draft.noteText == exactDraft)

        await controller.retry()

        let calls = await api.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.idempotencyKey == key })
        #expect(calls.allSatisfy { $0.request.text == exactDraft })
        #expect(controller.submissionState == .failed)
    }

    @Test
    func pollsEveryTypedTransitionWithBoundedBackoffAndNoFalseDeliveredState() async {
        let id = "11111111-2222-4333-8444-555555555555"
        let api = StatusCaptureAPISpy(
            captureResults: [.success(BrainCaptureReceipt(id: id, state: "queued"))],
            statusResults: [
                .success(captureStatus(id: id, state: .queued)),
                .success(captureStatus(id: id, state: .queued)),
                .success(captureStatus(id: id, state: .processing)),
                .success(captureStatus(id: id, state: .processing)),
                .success(captureStatus(id: id, state: .processing)),
                .success(captureStatus(id: id, state: .delivered)),
            ]
        )
        let delays = CaptureLockedBox<[Duration]>([])
        let controller = CaptureController(
            api: api,
            sleep: { delay in delays.withLock { $0.append(delay) } }
        )
        controller.draft.noteText = "keep only in memory while polling"

        await controller.submit()
        await controller.waitForMonitoring()

        #expect(delays.value == [
            .seconds(2), .seconds(4), .seconds(8),
            .seconds(15), .seconds(30), .seconds(30),
        ])
        #expect(await api.statusIDs == Array(repeating: id, count: 6))
        #expect(await api.calls.count == 1)
        #expect(controller.observedSubmissionStates == [
            .sending,
            .queued(id: id),
            .delivering(id: id),
            .delivered(id: id),
        ])
        #expect(controller.submissionState == .delivered(id: id))
        #expect(controller.draft.noteText.isEmpty)
        #expect(controller.canRetry == false)

        await controller.retry()
        await controller.submit()
        #expect(await api.calls.count == 1)
        #expect(controller.submissionState == .delivered(id: id))
    }

    @Test
    func retryableFailureOffersOneStablePayloadAndKeyWhilePermanentFailureDoesNot() async {
        let id = "22222222-2222-4222-8222-222222222222"
        let key = uuid("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let api = StatusCaptureAPISpy(
            captureResults: [
                .success(BrainCaptureReceipt(id: id, state: "queued")),
                .success(BrainCaptureReceipt(id: id, state: "queued")),
            ],
            statusResults: [
                .success(captureStatus(
                    id: id,
                    state: .failed,
                    retryable: true,
                    error: "Temporary ingest failure"
                )),
                .success(captureStatus(id: id, state: .processing)),
                .success(captureStatus(id: id, state: .delivered)),
            ]
        )
        let controller = CaptureController(
            api: api,
            makeUUID: { key },
            sleep: { _ in }
        )
        let original = "exact retry payload"
        controller.draft.noteText = original

        await controller.submit()
        await controller.waitForMonitoring()

        #expect(controller.submissionState == .retryAvailable(id: id))
        #expect(controller.errorMessage == "Temporary ingest failure")
        #expect(controller.canRetry)
        #expect(controller.draft.noteText.isEmpty)

        await controller.retry()
        await controller.waitForMonitoring()

        let calls = await api.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.idempotencyKey == key })
        #expect(calls.allSatisfy { $0.request == calls[0].request })
        #expect(calls.allSatisfy { $0.request.text == original })
        #expect(controller.submissionState == .delivered(id: id))

        let permanentID = "33333333-3333-4333-8333-333333333333"
        let permanent = StatusCaptureAPISpy(
            captureResults: [.success(BrainCaptureReceipt(id: permanentID, state: "queued"))],
            statusResults: [.success(captureStatus(
                id: permanentID,
                state: .failed,
                retryable: false,
                error: "Permanent ingest failure"
            ))]
        )
        let needsAttention = CaptureController(api: permanent, sleep: { _ in })
        needsAttention.draft.noteText = "do not offer retry"
        await needsAttention.submit()
        await needsAttention.waitForMonitoring()

        #expect(needsAttention.submissionState == .needsAttention(id: permanentID))
        #expect(needsAttention.errorMessage == "Permanent ingest failure")
        #expect(needsAttention.canRetry == false)
        await needsAttention.retry()
        #expect(await permanent.calls.count == 1)
    }

    @Test
    func cancellationStopsPollingAndReleasesTheOriginalBody() async {
        let id = "44444444-4444-4444-8444-444444444444"
        let api = StatusCaptureAPISpy(
            captureResults: [.success(BrainCaptureReceipt(id: id, state: "queued"))],
            statusResults: [.success(captureStatus(id: id, state: .delivered))]
        )
        let startedSleeps = CaptureLockedBox<[Duration]>([])
        let controller = CaptureController(api: api, sleep: { delay in
            startedSleeps.withLock { $0.append(delay) }
            try await Task.sleep(for: .seconds(60))
        })
        controller.draft.kind = .transcript
        controller.draft.transcriptFilename = "Private meeting.txt"
        controller.draft.transcriptText = "verbatim private transcript"

        let submission = Task { await controller.submit() }
        for _ in 0..<1_000 where startedSleeps.value.isEmpty {
            await Task.yield()
        }
        #expect(startedSleeps.value == [.seconds(2)])
        submission.cancel()
        await submission.value

        #expect(await api.statusIDs.isEmpty)
        #expect(await api.calls.count == 1)
        #expect(controller.submissionState == .queued(id: id))
        #expect(controller.canRetry == false)
        #expect(controller.canSubmit == false)
    }

    @Test
    func clipboardAndDropAreReadOnlyAfterExplicitUserActionsAndKeepNoHistory() {
        let clipboard = ClipboardSpy(
            text: "clipboard selection",
            image: CaptureImagePayload(data: pngData, mimeType: "image/png", filename: "paste.png")
        )
        let api = CaptureAPISpy(results: [])
        let controller = CaptureController(api: api, clipboard: clipboard)

        #expect(clipboard.textReads == 0)
        #expect(clipboard.imageReads == 0)

        controller.draft.kind = .note
        #expect(controller.pasteFromClipboard())
        #expect(controller.draft.noteText == "clipboard selection")
        #expect(clipboard.textReads == 1)

        controller.draft.kind = .image
        #expect(controller.pasteFromClipboard())
        #expect(controller.draft.image?.filename == "paste.png")
        #expect(clipboard.imageReads == 1)

        controller.acceptDroppedImage(
            data: jpegData,
            mimeType: "image/jpeg",
            filename: "drop.jpg"
        )
        #expect(controller.draft.image?.filename == "drop.jpg")
        #expect(clipboard.textReads == 1)
        #expect(clipboard.imageReads == 1)
    }

    @Test
    func explicitTranscriptFileLoadAcceptsOnlyMarkdownAndText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriptURL = directory.appendingPathComponent("Planning notes.txt")
        let verbatim = "Speaker one: hello\nSpeaker two: café"
        try verbatim.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let controller = CaptureController(api: CaptureAPISpy(results: []))
        controller.loadTranscript(from: transcriptURL)

        #expect(controller.draft.kind == .transcript)
        #expect(controller.draft.transcriptFilename == "Planning notes.txt")
        #expect(controller.draft.transcriptText == verbatim)
    }

    @Test
    func acceptedReceiptIsNonblockingPersistsAndShowsWaitingAfterNinetySeconds() async throws {
        let id = "55555555-5555-4555-8555-555555555555"
        let suite = "CaptureController.Waiting.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = CaptureLockedBox(start)
        let sleeps = CaptureSleepGate()
        let api = StatusCaptureAPISpy(
            captureResults: [.success(BrainCaptureReceipt(id: id, state: "queued"))],
            statusResults: [
                .success(captureStatus(id: id, state: .queued)),
                .success(captureStatus(id: id, state: .delivered)),
            ]
        )
        let controller = CaptureController(
            api: api,
            defaults: defaults,
            now: { clock.value },
            sleep: { duration in await sleeps.sleep(duration) }
        )
        controller.draft.noteText = "clear this once"

        await controller.submit()

        #expect(!controller.isSubmitting)
        #expect(controller.draft.noteText.isEmpty)
        #expect(controller.submissionState == .queued(id: id))
        #expect(controller.activeMonitor?.startedAt == start)
        #expect(defaults.data(forKey: CaptureController.monitorDefaultsKey) != nil)
        #expect(await api.calls.count == 1)
        await sleeps.waitForCount(1)

        clock.withLock { $0 = start.addingTimeInterval(91) }
        sleeps.resumeNext()
        await sleeps.waitForCount(1)
        #expect(controller.submissionState == .waitingForMacMini(
            id: id,
            elapsedSeconds: 91,
            lastState: .queued,
            lastError: nil
        ))
        #expect(await api.calls.count == 1, "polling must never resubmit")

        sleeps.resumeNext()
        await controller.waitForMonitoring()
        #expect(controller.submissionState == .delivered(id: id))
        #expect(controller.activeMonitor == nil)
        #expect(defaults.data(forKey: CaptureController.monitorDefaultsKey) == nil)
    }

    @Test
    func relaunchResumesPersistedMonitorWithoutBodyOrResubmission() async throws {
        let id = "66666666-6666-4666-8666-666666666666"
        let suite = "CaptureController.Relaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(CaptureMonitor(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastState: .processing,
            lastError: "Last network timeout"
        )), forKey: CaptureController.monitorDefaultsKey)
        let api = StatusCaptureAPISpy(
            captureResults: [],
            statusResults: [.success(captureStatus(id: id, state: .delivered))]
        )

        let controller = CaptureController(api: api, defaults: defaults, sleep: { _ in })
        await controller.waitForMonitoring()

        #expect(await api.calls.isEmpty)
        #expect(await api.statusIDs == [id])
        #expect(controller.submissionState == .delivered(id: id))
        #expect(defaults.data(forKey: CaptureController.monitorDefaultsKey) == nil)
    }
}

private struct CaptureCall: Equatable, Sendable {
    let request: BrainCaptureRequest
    let idempotencyKey: UUID
}

private actor CaptureAPISpy: BrainCaptureAPI {
    private var results: [Result<BrainCaptureReceipt, BrainAPIError>]
    private(set) var calls: [CaptureCall] = []

    init(results: [Result<BrainCaptureReceipt, BrainAPIError>]) {
        self.results = results
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        calls.append(CaptureCall(request: capture, idempotencyKey: idempotencyKey))
        guard !results.isEmpty else { throw BrainAPIError.transport }
        return try results.removeFirst().get()
    }
}

private actor StatusCaptureAPISpy: BrainCaptureAPI {
    private var captureResults: [Result<BrainCaptureReceipt, BrainAPIError>]
    private var statusResults: [Result<BrainCaptureStatus, BrainAPIError>]
    private var listResults: [Result<BrainCaptureListResponse, BrainAPIError>]
    private(set) var calls: [CaptureCall] = []
    private(set) var statusIDs: [String] = []
    private(set) var listCallCount = 0

    init(
        captureResults: [Result<BrainCaptureReceipt, BrainAPIError>],
        statusResults: [Result<BrainCaptureStatus, BrainAPIError>],
        listResults: [Result<BrainCaptureListResponse, BrainAPIError>] = []
    ) {
        self.captureResults = captureResults
        self.statusResults = statusResults
        self.listResults = listResults
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        calls.append(CaptureCall(request: capture, idempotencyKey: idempotencyKey))
        guard !captureResults.isEmpty else { throw BrainAPIError.transport }
        return try captureResults.removeFirst().get()
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        statusIDs.append(id)
        guard !statusResults.isEmpty else { throw BrainAPIError.invalidResponse }
        return try statusResults.removeFirst().get()
    }

    func captureList() async throws -> BrainCaptureListResponse {
        listCallCount += 1
        guard !listResults.isEmpty else { throw BrainAPIError.invalidResponse }
        return try listResults.removeFirst().get()
    }
}

private struct CaptureMemoryCredentials: DeviceCredentialStoring {
    let token: String?

    func save(_ token: String, for account: String) throws {}
    func load(for account: String) throws -> String? { token }
    func delete(for account: String) throws {}
}

private final class CaptureLockedBox<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withLock<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&storage)
    }
}

private final class CaptureSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func waitForCount(_ count: Int) async {
        while true {
            let ready = lock.withLock { continuations.count >= count }
            if ready { return }
            await Task.yield()
        }
    }

    func resumeNext() {
        lock.lock()
        let continuation = continuations.removeFirst()
        lock.unlock()
        continuation.resume()
    }
}

private final class CaptureURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handler = CaptureLockedBox<Handler?>(nil)

    static func install(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    static func reset() {
        handler.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class ClipboardSpy: CaptureClipboardReading {
    let text: String?
    let image: CaptureImagePayload?
    private(set) var textReads = 0
    private(set) var imageReads = 0

    init(text: String?, image: CaptureImagePayload?) {
        self.text = text
        self.image = image
    }

    func readText() -> String? {
        textReads += 1
        return text
    }

    func readImage() -> CaptureImagePayload? {
        imageReads += 1
        return image
    }
}

@MainActor
private final class UUIDSequence {
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        values.removeFirst()
    }
}

private let pngData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
private let jpegData = Data([0xff, 0xd8, 0xff, 0xe0])

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}

private func captureStatus(
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
        createdAt: Date(timeIntervalSince1970: 1_784_112_400),
        updatedAt: Date(timeIntervalSince1970: 1_784_112_430),
        deliveredAt: state == .delivered ? Date(timeIntervalSince1970: 1_784_112_430) : nil
    )
}
