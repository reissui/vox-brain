import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct MeetingUploadControllerTests {
    @Test
    func processingTranscriptCannotRenderOrUpload() async throws {
        let fixture = try UploadFixture()
        var meeting = completedMeeting(title: "Still transcribing")
        meeting.transcriptionState = .processing
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let api = MeetingUploadAPISpy(captureResults: [], statusResults: [])
        let controller = fixture.controller(api: api)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(controller.errorMessage == "The meeting transcript is not final.")
        #expect(controller.uploadState == .failed)
        #expect(await api.captureCalls.isEmpty)
    }

    @Test
    func rendersFullAnalysisAndRawTranscriptWithExactTimestamps() throws {
        let meeting = completedMeeting(title: "Product sync")
        let utterances = try sampleUtterances()
        var editor = SpeakerEditor(utterances: utterances)
        let renamed = editor.renameSpeaker(SpeakerEditor.remoteSpeakerID, to: "Alice")
        #expect(renamed)
        let analysis = sampleAnalysis(quoteID: utterances[0].id)
        let renderer = MeetingMarkdownRenderer()

        let full = renderer.render(
            meeting: meeting,
            utterances: utterances,
            analysis: analysis,
            speakerState: editor.state
        )

        #expect(full.hasPrefix("# Product sync\n\n"))
        #expect(full.contains("- Date: 2026-07-16T13:20:00.000Z"))
        #expect(full.contains("- Duration: 00:30:00.000"))
        #expect(full.contains("- Engine: parakeet / large-v3"))
        #expect(full.contains("## Participants\n\n- You\n- Alice"))
        #expect(full.contains("## Summary\n\nA concise summary."))
        #expect(full.contains("## Topics\n\n- Launch"))
        #expect(full.contains("## Decisions\n\n- Ship Friday"))
        #expect(full.contains("## Action items\n\n- [ ] Prepare notes — Owner: Alice — Due: Friday"))
        #expect(full.contains("## Risks\n\n- Capacity"))
        #expect(full.contains("## Follow-up\n\n**Subject:** Next steps"))
        #expect(full.contains("### [00:00:01.250–00:00:02.500] You\n\nHello exactly."))
        #expect(full.contains("### [00:01:05.000–00:01:07.125] Alice\n\nReply café."))

        let raw = renderer.render(meeting: meeting, utterances: utterances)
        #expect(raw.contains("## Participants"))
        #expect(raw.contains("## Transcript"))
        #expect(raw.contains("Hello exactly."))
        #expect(!raw.contains("## Summary"))
        #expect(!raw.contains("## Topics"))
        #expect(!raw.contains("## Follow-up"))
    }

    @Test
    func nonblankNotesRenderVerbatimBeforeTranscriptAndBlankNotesChangeNoBytes() throws {
        let meeting = completedMeeting(title: "Notes rendering")
        let utterances = try sampleUtterances()
        let renderer = MeetingMarkdownRenderer()
        let original = renderer.render(meeting: meeting, utterances: utterances)

        #expect(renderer.render(
            meeting: meeting,
            utterances: utterances,
            notes: " \n\t"
        ) == original)

        let exact = "Decide: ship Friday\n\n## User heading\n- keep verbatim"
        let withNotes = renderer.render(
            meeting: meeting,
            utterances: utterances,
            notes: exact
        )
        let notesRange = try #require(withNotes.range(of: "## Notes\n\n\(exact)"))
        let transcriptRange = try #require(withNotes.range(of: "## Transcript"))
        #expect(notesRange.lowerBound < transcriptRange.lowerBound)
        #expect(withNotes[notesRange].hasSuffix(exact))
    }

    @Test
    func finalCaptureReloadsCurrentNotesFromDisk() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Fresh notes")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        try fixture.notesStore.save("stale", meetingID: meeting.id)
        let api = MeetingUploadAPISpy(
            captureResults: [.value(BrainCaptureReceipt(id: "fresh-notes", state: "queued"))],
            statusResults: [.value(BrainCaptureStatus(
                id: "fresh-notes",
                state: .delivered,
                retryable: false,
                error: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                deliveredAt: Date(timeIntervalSince1970: 2)
            ))]
        )
        let controller = fixture.controller(api: api)
        try fixture.notesStore.save("fresh from disk", meetingID: meeting.id)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        let request = try #require(await api.captureCalls.first?.request)
        #expect(request.transcript?.contains("## Notes\n\nfresh from disk") == true)
        #expect(request.transcript?.contains("## Notes\n\nstale") == false)
    }

    @Test
    func escapesOnlyWouldBeHeadingsAndMakesCaptureTitleFilenameSafe() throws {
        var meeting = completedMeeting(title: "../Roadmap\n# forged/title:")
        meeting.analysisState = .completed
        let utterance = try MeetingUtterance(
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "verbatim first line\n## not a document heading\nlast line",
            baseSpeakerID: "remote"
        )
        var editor = SpeakerEditor(utterances: [utterance])
        let renamed = editor.renameSpeaker("remote", to: "Alice\n# forged speaker")
        #expect(renamed)
        let analysis = MeetingAnalysis(
            title: "Analysis\n## forged analysis heading",
            summary: "Keep this\n# summary text",
            topics: [],
            decisions: [],
            actionItems: [],
            risks: [],
            quotes: [],
            speakerSuggestions: [],
            followUp: MeetingFollowUpDraft(subject: "Subject #1", body: "Body\n---")
        )

        let markdown = MeetingMarkdownRenderer().render(
            meeting: meeting,
            utterances: [utterance],
            analysis: analysis,
            speakerState: editor.state
        )

        #expect(markdown.contains("# ../Roadmap<br>\\# forged/title:"))
        #expect(markdown.contains("### [00:00:00.000–00:00:01.000] Alice<br>\\# forged speaker"))
        #expect(markdown.contains("verbatim first line\n\\## not a document heading\nlast line"))
        #expect(markdown.contains("Keep this\n\\# summary text"))
        #expect(markdown.contains("Body\n\\---"))
        let filename = MeetingMarkdownRenderer.filenameSafeTitle(meeting.title)
        #expect(filename == "Roadmap-# forged-title.md")
        #expect(!filename.contains("/"))
        #expect(!filename.contains("\n"))
    }

    @Test
    func stableDigestAndKeyBuildOneTranscriptRequestWithNoImageOrAudio() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Planning / Review")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let captureID = uuid("11111111-2222-4333-8444-555555555555")
        let api = MeetingUploadAPISpy(
            captureResults: [.value(BrainCaptureReceipt(id: captureID.uuidString.lowercased(), state: "queued"))],
            statusResults: [.value(status(captureID, state: .delivered))]
        )
        let controller = fixture.controller(api: api)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        let call = try #require(await api.captureCalls.first)
        #expect(call.request.type == .transcript)
        #expect(call.request.source == "Brain.app meeting")
        #expect(call.request.title == "Planning - Review.md")
        #expect(call.request.image == nil)
        #expect(call.request.url == nil)
        #expect(call.request.text == nil)
        #expect(call.request.note == nil)
        let markdown = try #require(call.request.transcript)
        let digest = MeetingMarkdownRenderer.transcriptDigest(markdown)
        #expect(digest == MeetingMarkdownRenderer.transcriptDigest(markdown))
        #expect(call.idempotencyKey == MeetingMarkdownRenderer.stableIdempotencyKey(
            meetingID: meeting.id,
            transcriptDigest: digest
        ))
        #expect(controller.uploadState == .delivered)

        let changedDigest = MeetingMarkdownRenderer.transcriptDigest(markdown + "changed")
        #expect(changedDigest != digest)
        #expect(MeetingMarkdownRenderer.stableIdempotencyKey(
            meetingID: meeting.id,
            transcriptDigest: changedDigest
        ) != call.idempotencyKey)
        let versionIndex = call.idempotencyKey.uuidString.index(
            call.idempotencyKey.uuidString.startIndex,
            offsetBy: 14
        )
        #expect(call.idempotencyKey.uuidString[versionIndex] == "5")
    }

    @Test
    func offlineFailureSurvivesRelaunchAndRetryUsesExactBodyAndKey() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Offline sync")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let offline = MeetingUploadAPISpy(
            captureResults: [.failure(.transport)],
            statusResults: []
        )
        let first = fixture.controller(api: offline)

        await first.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(first.uploadState == .failed)
        #expect(first.canRetry)
        let originalCall = try #require(await offline.captureCalls.first)
        let loadedPersisted = try first.persistedRevision(meetingID: meeting.id)
        let persisted = try #require(loadedPersisted)
        #expect(persisted.request == originalCall.request)
        #expect(persisted.idempotencyKey == originalCall.idempotencyKey)
        #expect(persisted.retryMode == .post)

        let captureID = uuid("22222222-2222-4222-8222-222222222222")
        let online = MeetingUploadAPISpy(
            captureResults: [.value(BrainCaptureReceipt(id: captureID.uuidString.lowercased(), state: "queued"))],
            statusResults: [.value(status(captureID, state: .delivered))]
        )
        let relaunched = fixture.controller(api: online)
        await relaunched.retry(meetingID: meeting.id)

        let retriedCall = try #require(await online.captureCalls.first)
        #expect(retriedCall.request == originalCall.request)
        #expect(retriedCall.idempotencyKey == originalCall.idempotencyKey)
        #expect(relaunched.uploadState == .delivered)
        #expect(try fixture.meetingStore.load(meeting.id).meeting.uploadState == .delivered)
    }

    @Test
    func retryableServerFailureRepostsThePersistedBodyAndIdempotencyKey() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Retryable delivery")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let captureID = uuid("77777777-7777-4777-8777-777777777777")
        let receipt = BrainCaptureReceipt(id: captureID.uuidString.lowercased(), state: "queued")
        let api = MeetingUploadAPISpy(
            captureResults: [.value(receipt), .value(receipt)],
            statusResults: [
                .value(status(
                    captureID,
                    state: .failed,
                    retryable: true,
                    error: "Temporary ingest failure"
                )),
                .value(status(captureID, state: .delivered)),
            ]
        )
        let controller = fixture.controller(api: api)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)
        #expect(controller.uploadState == .failed)
        #expect(controller.canRetry)
        #expect(controller.errorMessage == "Temporary ingest failure")

        await controller.retry(meetingID: meeting.id)

        let calls = await api.captureCalls
        #expect(calls.count == 2)
        #expect(calls[0].request == calls[1].request)
        #expect(calls[0].idempotencyKey == calls[1].idempotencyKey)
        #expect(controller.uploadState == .delivered)
    }

    @Test
    func relaunchPollsAcceptedCaptureWithoutDuplicatePost() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Polling sync")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let captureID = uuid("33333333-3333-4333-8333-333333333333")
        let firstAPI = MeetingUploadAPISpy(
            captureResults: [.value(BrainCaptureReceipt(id: captureID.uuidString.lowercased(), state: "queued"))],
            statusResults: []
        )
        let first = fixture.controller(api: firstAPI, sleep: { _ in throw CancellationError() })

        await first.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(await firstAPI.captureCalls.count == 1)
        #expect(await firstAPI.statusIDs.isEmpty)
        #expect(first.uploadState == .queued)
        #expect(first.currentRevision?.captureID == captureID.uuidString.lowercased())

        let relaunchedAPI = MeetingUploadAPISpy(
            captureResults: [],
            statusResults: [
                .value(status(captureID, state: .processing)),
                .value(status(captureID, state: .delivered)),
            ]
        )
        let relaunched = fixture.controller(api: relaunchedAPI)
        await relaunched.resume(meetingID: meeting.id)

        #expect(await relaunchedAPI.captureCalls.isEmpty)
        #expect(await relaunchedAPI.statusIDs == [
            captureID.uuidString.lowercased(),
            captureID.uuidString.lowercased(),
        ])
        #expect(relaunched.uploadState == .delivered)

        await relaunched.resume(meetingID: meeting.id)
        #expect(await relaunchedAPI.captureCalls.isEmpty)
        #expect(await relaunchedAPI.statusIDs.count == 2)
    }

    @Test
    func staleQueuedCaptureIsRepostedOnceThenBecomesExplicitlyRetryable() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Lost Queue delivery")
        try fixture.meetingStore.save(meeting, utterances: sampleUtterances())
        let captureID = uuid("34343434-3434-4434-8434-343434343434")
        let receipt = BrainCaptureReceipt(
            id: captureID.uuidString.lowercased(),
            state: "queued"
        )
        let api = MeetingUploadAPISpy(
            captureResults: [.value(receipt), .value(receipt)],
            statusResults: Array(
                repeating: .value(status(captureID, state: .queued)),
                count: MeetingUploadController.maximumPollAttempts * 2
            )
        )
        let controller = fixture.controller(api: api)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(await api.captureCalls.count == 2)
        #expect(
            await api.statusIDs.count
                == MeetingUploadController.maximumPollAttempts * 2
        )
        #expect(controller.uploadState == .failed)
        #expect(controller.canRetry)
        #expect(controller.currentRevision?.retryMode == .post)
        #expect(controller.errorMessage?.contains("expected time") == true)
    }

    @Test
    func contentAndSpeakerEditsRequireExplicitNewRevisions() async throws {
        let fixture = try UploadFixture()
        var meeting = completedMeeting(title: "Revision sync")
        meeting.analysisState = .completed
        var utterances = try sampleUtterances()
        try fixture.meetingStore.save(meeting, utterances: utterances)
        try fixture.analysisStore.replace(
            StoredMeetingAnalysis(
                analysis: sampleAnalysis(quoteID: utterances[0].id),
                speakerState: SpeakerEditingState()
            ),
            meetingID: meeting.id
        )
        let firstID = uuid("44444444-4444-4444-8444-444444444444")
        let secondID = uuid("55555555-5555-4555-8555-555555555555")
        let thirdID = uuid("66666666-6666-4666-8666-666666666666")
        let api = MeetingUploadAPISpy(
            captureResults: [
                .value(BrainCaptureReceipt(id: firstID.uuidString.lowercased(), state: "queued")),
                .value(BrainCaptureReceipt(id: secondID.uuidString.lowercased(), state: "queued")),
                .value(BrainCaptureReceipt(id: thirdID.uuidString.lowercased(), state: "queued")),
            ],
            statusResults: [
                .value(status(firstID, state: .delivered)),
                .value(status(secondID, state: .delivered)),
                .value(status(thirdID, state: .delivered)),
            ]
        )
        let controller = fixture.controller(api: api)
        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)
        let first = try #require(controller.currentRevision)

        utterances[0].text = "Edited exact words."
        let persistedMeeting = try fixture.meetingStore.load(meeting.id).meeting
        try fixture.meetingStore.save(persistedMeeting, utterances: utterances)
        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(controller.canReupload)
        #expect(await api.captureCalls.count == 1)
        #expect(controller.currentRevision?.revision == 1)

        await controller.reupload(meetingID: meeting.id)
        let second = try #require(controller.currentRevision)
        #expect(second.revision == 2)
        #expect(second.transcriptDigest != first.transcriptDigest)
        #expect(second.idempotencyKey != first.idempotencyKey)
        #expect(await api.captureCalls.count == 2)

        var editedSpeakers = SpeakerEditor(utterances: utterances)
        let renamed = editedSpeakers.renameSpeaker("remote", to: "Named teammate")
        #expect(renamed)
        let loadedAnalysis = try fixture.analysisStore.load(meetingID: meeting.id)
        let storedAnalysis = try #require(loadedAnalysis)
        try fixture.analysisStore.replace(
            StoredMeetingAnalysis(
                analysis: storedAnalysis.analysis,
                speakerState: editedSpeakers.state
            ),
            meetingID: meeting.id
        )
        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(controller.canReupload)
        #expect(await api.captureCalls.count == 2)
        await controller.reupload(meetingID: meeting.id)
        let third = try #require(controller.currentRevision)
        #expect(third.revision == 3)
        #expect(third.transcriptDigest != second.transcriptDigest)
        #expect(third.request.transcript?.contains("Named teammate") == true)
        #expect(await api.captureCalls.count == 3)
    }

    @Test
    func rejectsRenderedUTF8OverSixMiBLocallyAndKeepsMeetingStored() async throws {
        let fixture = try UploadFixture()
        let meeting = completedMeeting(title: "Large transcript")
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: String(repeating: "é", count: (MeetingUploadController.maximumRenderedBytes / 2) + 1),
            baseSpeakerID: "you"
        )
        try fixture.meetingStore.save(meeting, utterances: [utterance])
        let api = MeetingUploadAPISpy(captureResults: [], statusResults: [])
        let controller = fixture.controller(api: api)

        await controller.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        #expect(controller.errorMessage == "Transcript must be 6 MiB or smaller.")
        #expect(controller.uploadState == .failed)
        #expect(await api.captureCalls.isEmpty)
        let preserved = try fixture.meetingStore.load(meeting.id)
        #expect(preserved.utterances == [utterance])
        #expect(preserved.meeting.lifecycleState == .completed)
    }
}

private struct MeetingUploadCall: Equatable, Sendable {
    let request: BrainCaptureRequest
    let idempotencyKey: UUID
}

private enum MeetingUploadResult<Value: Sendable>: Sendable {
    case value(Value)
    case failure(BrainAPIError)

    func get() throws -> Value {
        switch self {
        case .value(let value): value
        case .failure(let error): throw error
        }
    }
}

private actor MeetingUploadAPISpy: BrainCaptureAPI {
    private var captureResults: [MeetingUploadResult<BrainCaptureReceipt>]
    private var statusResults: [MeetingUploadResult<BrainCaptureStatus>]
    private(set) var captureCalls: [MeetingUploadCall] = []
    private(set) var statusIDs: [String] = []

    init(
        captureResults: [MeetingUploadResult<BrainCaptureReceipt>],
        statusResults: [MeetingUploadResult<BrainCaptureStatus>]
    ) {
        self.captureResults = captureResults
        self.statusResults = statusResults
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        captureCalls.append(MeetingUploadCall(request: capture, idempotencyKey: idempotencyKey))
        guard !captureResults.isEmpty else { throw BrainAPIError.invalidResponse }
        return try captureResults.removeFirst().get()
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        statusIDs.append(id)
        guard !statusResults.isEmpty else { throw BrainAPIError.invalidResponse }
        return try statusResults.removeFirst().get()
    }
}

@MainActor
private final class UploadFixture {
    let rootURL: URL
    let meetingStore: MeetingStore
    let notesStore: MeetingNotesStore
    let analysisStore: FileMeetingAnalysisStore
    let uploadStore: FileMeetingUploadStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingUploadTests-\(UUID().uuidString)", isDirectory: true)
        meetingStore = MeetingStore(rootURL: rootURL)
        notesStore = MeetingNotesStore(rootURL: rootURL)
        analysisStore = FileMeetingAnalysisStore(rootURL: rootURL)
        uploadStore = FileMeetingUploadStore(rootURL: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func controller(
        api: any BrainCaptureAPI,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> MeetingUploadController {
        MeetingUploadController(
            meetingStore: meetingStore,
            notesStore: notesStore,
            analysisStore: analysisStore,
            uploadStore: uploadStore,
            api: api,
            sleep: sleep,
            now: { Date(timeIntervalSince1970: 1_784_208_000) }
        )
    }
}

private func completedMeeting(title: String) -> MeetingRecord {
    MeetingRecord(
        id: uuid("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
        title: title,
        startedAt: Date(timeIntervalSince1970: 1_784_208_000),
        endedAt: Date(timeIntervalSince1970: 1_784_209_800),
        lifecycleState: .completed,
        speechEngine: "parakeet",
        speechModel: "large-v3"
    )
}

private func sampleUtterances() throws -> [MeetingUtterance] {
    [
        try MeetingUtterance(
            id: uuid("10000000-0000-4000-8000-000000000001"),
            source: .microphone,
            startMilliseconds: 1_250,
            endMilliseconds: 2_500,
            text: "Hello exactly.",
            baseSpeakerID: "you"
        ),
        try MeetingUtterance(
            id: uuid("10000000-0000-4000-8000-000000000002"),
            source: .system,
            startMilliseconds: 65_000,
            endMilliseconds: 67_125,
            text: "Reply café.",
            baseSpeakerID: "remote"
        ),
    ]
}

private func sampleAnalysis(quoteID: UUID) -> MeetingAnalysis {
    MeetingAnalysis(
        title: "Product sync",
        summary: "A concise summary.",
        topics: ["Launch"],
        decisions: ["Ship Friday"],
        actionItems: [MeetingAnalysisActionItem(text: "Prepare notes", owner: "Alice", due: "Friday")],
        risks: ["Capacity"],
        quotes: [MeetingAnalysisQuote(utteranceID: quoteID, text: "Hello")],
        speakerSuggestions: [],
        followUp: MeetingFollowUpDraft(subject: "Next steps", body: "Thanks for the discussion.")
    )
}

private func status(
    _ id: UUID,
    state: BrainCaptureState,
    retryable: Bool = false,
    error: String? = nil
) -> BrainCaptureStatus {
    BrainCaptureStatus(
        id: id.uuidString.lowercased(),
        state: state,
        retryable: retryable,
        error: error,
        createdAt: Date(timeIntervalSince1970: 1_784_208_000),
        updatedAt: Date(timeIntervalSince1970: 1_784_208_001),
        deliveredAt: state == .delivered ? Date(timeIntervalSince1970: 1_784_208_001) : nil
    )
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
