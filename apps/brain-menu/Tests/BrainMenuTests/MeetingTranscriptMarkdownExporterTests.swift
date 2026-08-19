import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingTranscriptMarkdownExporterTests {
    @Test
    func writesRawAndProcessedMarkdownBesideMeetingFiles() throws {
        let root = try makeTemporaryRoot()
        let meetingID = UUID()
        let meeting = try makeMeeting(id: meetingID)
        let utterance = try makeUtterance(text: "Um, we should ship this.")
        let attempt = MeetingTranscriptAttempt(
            id: meetingID,
            modelAttestation: .legacy(meeting: meeting),
            utterances: [utterance],
            isSuccessful: true
        )
        let processed = MeetingProcessedTranscript(
            rawAttemptID: meetingID,
            terminologyHash: "hash",
            turns: [
                MeetingProcessedTranscriptTurn(
                    id: utterance.id,
                    utteranceIDs: [utterance.id],
                    startMilliseconds: 0,
                    endMilliseconds: 1_000,
                    speakerID: "you",
                    speakerLabel: "You",
                    text: "We should ship this.",
                    unclear: false
                ),
            ],
            bullets: [],
            corrections: []
        )
        let exporter = MeetingTranscriptMarkdownExporter()

        let rawURL = try exporter.writeRaw(
            meeting: meeting,
            attempt: attempt,
            rootURL: root
        )
        let processedURL = try exporter.writeProcessed(
            meeting: meeting,
            processedTranscript: processed,
            rootURL: root
        )

        #expect(rawURL.lastPathComponent == MeetingTranscriptMarkdownExporter.rawFilename)
        #expect(processedURL.lastPathComponent == MeetingTranscriptMarkdownExporter.processedFilename)
        let rawMarkdown = try String(contentsOf: rawURL, encoding: .utf8)
        let processedMarkdown = try String(contentsOf: processedURL, encoding: .utf8)
        #expect(rawMarkdown.contains("Raw Transcript"))
        #expect(rawMarkdown.contains("Um, we should ship this."))
        #expect(processedMarkdown.contains("Processed Transcript"))
        #expect(processedMarkdown.contains("We should ship this."))
    }

    @Test
    func suppressionOverlayHidesRemovedRawTurns() throws {
        let meeting = try makeMeeting(id: UUID())
        let utterance = try makeUtterance(text: "Remove me")
        let attempt = MeetingTranscriptAttempt(
            id: meeting.id,
            modelAttestation: .legacy(meeting: meeting),
            utterances: [utterance],
            isSuccessful: true
        )
        var suppressed = utterance
        suppressed.suppressed = true
        let markdown = MeetingTranscriptMarkdownExporter().renderRaw(
            meeting: meeting,
            attempt: attempt,
            suppressionSource: [suppressed]
        )
        #expect(!markdown.contains("Remove me"))
        #expect(markdown.contains("_No transcript text._"))
    }
}

@Suite(.serialized)
struct MeetingTranscriptCleanupExtendedTests {
    @Test
    func removesFillersDotsAndRepeatedWords() throws {
        let meeting = try makeMeeting(id: UUID())
        let utterance = try makeUtterance(text: "Um . . . we we we should arr go")
        let attempt = MeetingTranscriptAttempt(
            id: meeting.id,
            modelAttestation: .legacy(meeting: meeting),
            utterances: [utterance],
            isSuccessful: true
        )
        let turns = MeetingTranscriptTurnAssembler.assemble(utterances: attempt.utterances)
        let processed = MeetingTranscriptCleanup.makeTranscript(
            attempt: attempt,
            turns: turns,
            terminologyHash: "hash"
        )
        #expect(processed.turns.first?.text == "we should go")
    }
}

private func makeTemporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("brain-transcript-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeMeeting(id: UUID) throws -> MeetingRecord {
    MeetingRecord(
        id: id,
        title: "Planning",
        startedAt: Date(timeIntervalSince1970: 1_000),
        endedAt: Date(timeIntervalSince1970: 61_000),
        lifecycleState: .completed,
        speechEngine: "voxtype",
        speechModel: "medium.en"
    )
}

private func makeUtterance(text: String) throws -> MeetingUtterance {
    try MeetingUtterance(
        source: .microphone,
        startMilliseconds: 0,
        endMilliseconds: 1_000,
        text: text,
        baseSpeakerID: "you",
        humanName: "You"
    )
}
