import Foundation
import Testing
@testable import BrainMenu

struct MeetingTranscriptTurnAssemblerTests {
    @Test
    func groupsByResolvedSpeakerAndEightSecondSilenceBoundary() throws {
        let first = try utterance(.microphone, 0, 1_000, " First\nline ", base: "you")
        let withinBoundary = try utterance(.microphone, 8_999, 9_100, "second", base: "you")
        let atBoundary = try utterance(.microphone, 17_100, 17_300, "third", base: "you")
        let turns = MeetingTranscriptTurnAssembler.assemble(
            utterances: [atBoundary, withinBoundary, first]
        )

        #expect(turns.count == 2)
        #expect(turns[0].utteranceIDs == [first.id, withinBoundary.id])
        #expect(turns[0].startMilliseconds == 0)
        #expect(turns[0].endMilliseconds == 9_100)
        #expect(turns[0].text == "First line second")
        #expect(turns[1].utteranceIDs == [atBoundary.id])
    }

    @Test
    func manualAssignmentWinsAndSystemAudioStaysOneRemoteSpeaker() throws {
        let systemOne = try utterance(.system, 0, 1_000, "hello", base: "diarized-a")
        let systemTwo = try utterance(.system, 1_100, 2_000, "again", base: "diarized-b")
        let manual = try utterance(.system, 2_100, 3_000, "Alex here", base: "diarized-c")
        let turns = MeetingTranscriptTurnAssembler.assemble(
            utterances: [manual, systemTwo, systemOne],
            assignments: [manual.id: SpeakerAssignment(speakerID: "alex", provenance: .manual)],
            speakers: ["alex": MeetingSpeaker(id: "alex", displayName: "Alex")]
        )

        #expect(turns.map(\.speakerID) == ["remote", "alex"])
        #expect(turns.map(\.speakerLabel) == ["Remote", "Alex"])
        #expect(turns[0].text == "hello again")
        #expect(turns[1].provenance == .manual)
    }

    @Test
    func clusteredRemoteIDsSplitTurnsAndJunkStillCollapses() throws {
        let first = try utterance(.system, 0, 1_000, "hello", base: "remote-2")
        let same = try utterance(.system, 1_100, 2_000, "again", base: "remote-2")
        let other = try utterance(.system, 2_100, 3_000, "other", base: "remote-3")
        let junk = try utterance(.system, 3_100, 4_000, "junk", base: "untrusted-diarization")
        let mic = try utterance(.microphone, 4_100, 5_000, "me", base: "you")
        let turns = MeetingTranscriptTurnAssembler.assemble(
            utterances: [mic, junk, other, same, first]
        )
        #expect(turns.map(\.speakerID) == ["remote-2", "remote-3", "remote", "you"])
        #expect(turns.map(\.speakerLabel) == ["Speaker 2", "Speaker 3", "Remote", "You"])
        #expect(turns[0].text == "hello again")
    }

    @Test
    func preservesOverlapsAndUsesDeterministicOrderingForTies() throws {
        let sameSpeakerEarly = try utterance(.microphone, 0, 10_000, "one", base: "you")
        let sameSpeakerOverlap = try utterance(.microphone, 5_000, 6_000, "two", base: "you")
        let remoteOverlap = try utterance(.system, 5_000, 7_000, "three", base: "remote")
        let turns = MeetingTranscriptTurnAssembler.assemble(
            utterances: [remoteOverlap, sameSpeakerOverlap, sameSpeakerEarly]
        )

        #expect(turns.count == 2)
        #expect(turns[0].utteranceIDs == [sameSpeakerEarly.id, sameSpeakerOverlap.id])
        #expect(turns[0].endMilliseconds == 10_000)
        #expect(turns[1].utteranceIDs == [remoteOverlap.id])

        let tiedMicrophone = try utterance(.microphone, 20_000, 21_000, "microphone", base: "you")
        let tiedSystem = try utterance(.system, 20_000, 21_000, "system", base: "remote")
        let tied = MeetingTranscriptTurnAssembler.assemble(
            utterances: [tiedSystem, tiedMicrophone]
        )
        #expect(tied.map(\.text) == ["microphone", "system"])
    }

    @Test
    func excludesSuppressedUtterances() throws {
        let hidden = try utterance(.microphone, 0, 1_000, "hidden", base: "you", suppressed: true)
        let visible = try utterance(.microphone, 1_100, 2_000, "visible", base: "you")
        let turns = MeetingTranscriptTurnAssembler.assemble(utterances: [hidden, visible])

        #expect(turns.map(\.utteranceIDs) == [[visible.id]])
        #expect(turns.map(\.text) == ["visible"])
    }

    private func utterance(
        _ source: MeetingUtteranceSource,
        _ start: Int64,
        _ end: Int64,
        _ text: String,
        base: String,
        suppressed: Bool = false
    ) throws -> MeetingUtterance {
        try MeetingUtterance(
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            text: text,
            baseSpeakerID: base,
            suppressed: suppressed
        )
    }
}
