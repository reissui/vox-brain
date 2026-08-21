import Foundation
import Testing
@testable import BrainMenu

struct SpeakerEditorTests {
    @Test
    func sourceAwareDefaultsAndSavedAssignmentsWin() throws {
        let microphone = try utterance(
            id: "00000000-0000-0000-0000-000000000001",
            source: .microphone,
            start: 0,
            end: 1_000,
            text: "my words",
            baseSpeakerID: "incorrect"
        )
        let system = try utterance(
            id: "00000000-0000-0000-0000-000000000002",
            source: .system,
            start: 1_000,
            end: 2_000,
            text: "their words",
            baseSpeakerID: "also-incorrect"
        )
        let saved = try utterance(
            id: "00000000-0000-0000-0000-000000000003",
            source: .system,
            start: 2_000,
            end: 3_000,
            text: "Alex speaking"
        )

        let editor = SpeakerEditor(
            utterances: [system, saved, microphone],
            savedAssignments: [
                saved.id: SpeakerAssignment(speakerID: "alex", provenance: .manual),
            ],
            speakers: [
                "alex": MeetingSpeaker(id: "alex", displayName: "Alex"),
            ]
        )

        #expect(editor.assignment(for: microphone.id) == SpeakerAssignment(
            speakerID: "you",
            provenance: .sourceDefault
        ))
        #expect(editor.assignment(for: system.id) == SpeakerAssignment(
            speakerID: "remote",
            provenance: .sourceDefault
        ))
        #expect(editor.assignment(for: saved.id) == SpeakerAssignment(
            speakerID: "alex",
            provenance: .manual
        ))
        #expect(editor.displayName(for: "you") == "You")
        #expect(editor.displayName(for: "remote") == "Remote")
        #expect(editor.displayName(for: "alex") == "Alex")
        #expect(editor.utterances.first { $0.id == saved.id }?.humanName == "Alex")
    }

    @Test
    func renameMergeAndReassignHaveExactScopesAndManualProvenance() throws {
        let youOne = try utterance(
            id: "00000000-0000-0000-0000-000000000011",
            source: .microphone,
            start: 100,
            end: 300,
            text: "verbatim one"
        )
        let youTwo = try utterance(
            id: "00000000-0000-0000-0000-000000000012",
            source: .microphone,
            start: 300,
            end: 600,
            text: "verbatim two"
        )
        let remote = try utterance(
            id: "00000000-0000-0000-0000-000000000013",
            source: .system,
            start: 400,
            end: 800,
            text: "remote text"
        )
        var editor = SpeakerEditor(utterances: [youOne, youTwo, remote])
        let originals = transcriptFields(editor.utterances)

        let renamed = editor.rename(speakerID: "you", to: "the owner")
        #expect(renamed)
        #expect(editor.utterances.filter { $0.baseSpeakerID == "you" }.allSatisfy {
            $0.humanName == "the owner"
        })
        #expect(editor.utterances.first { $0.id == remote.id }?.humanName == "Remote")

        let reassigned = editor.reassign(utteranceIDs: [youTwo.id], to: "alex")
        #expect(reassigned)
        #expect(editor.assignment(for: youTwo.id) == SpeakerAssignment(
            speakerID: "alex",
            provenance: .manual
        ))
        #expect(editor.assignment(for: youOne.id)?.speakerID == "you")

        let merged = editor.merge(speakerIDs: ["alex"], into: "remote")
        #expect(merged)
        #expect(editor.assignment(for: youTwo.id) == SpeakerAssignment(
            speakerID: "remote",
            provenance: .manual
        ))
        #expect(editor.assignment(for: remote.id)?.speakerID == "remote")
        #expect(editor.speakers["alex"] == nil)
        #expect(transcriptFields(editor.utterances) == originals)
    }

    @Test
    func splitUsesStableIDAndUndoRestoresImmediatelyPreviousEdit() throws {
        let first = try utterance(
            id: "00000000-0000-0000-0000-000000000021",
            source: .system,
            start: 0,
            end: 1_000,
            text: "first"
        )
        let second = try utterance(
            id: "00000000-0000-0000-0000-000000000022",
            source: .system,
            start: 1_000,
            end: 2_000,
            text: "second"
        )
        var editor = SpeakerEditor(utterances: [first, second])
        let before = editor

        let splitID = editor.split(
            speakerID: "remote",
            utteranceIDs: [second.id],
            displayName: "Jamie"
        )

        #expect(splitID.hasPrefix("speaker-"))
        #expect(editor.assignment(for: first.id)?.speakerID == "remote")
        #expect(editor.assignment(for: second.id) == SpeakerAssignment(
            speakerID: splitID,
            provenance: .manual
        ))
        #expect(editor.displayName(for: splitID) == "Jamie")
        let undone = editor.undo()
        #expect(undone)
        #expect(editor.utterances == before.utterances)
        #expect(editor.state == before.state)
        let secondUndo = editor.undo()
        #expect(!secondUndo)

        let sameSplitID = editor.split(
            speakerID: "remote",
            utteranceIDs: [second.id],
            displayName: "Jamie"
        )
        #expect(sameSplitID == splitID)
    }

    @Test
    func manualAssignmentSurvivesAISuggestionsAndReprocessing() throws {
        let first = try utterance(
            id: "00000000-0000-0000-0000-000000000031",
            source: .system,
            start: 0,
            end: 1_000,
            text: "original first"
        )
        let second = try utterance(
            id: "00000000-0000-0000-0000-000000000032",
            source: .system,
            start: 1_000,
            end: 2_000,
            text: "original second"
        )
        var editor = SpeakerEditor(utterances: [first, second])
        let reassigned = editor.reassign(utteranceIDs: [first.id], to: "jamie")
        #expect(reassigned)

        editor.applyAISuggestions([
            first.id: "ai-wrong",
            second.id: "ai-speaker",
        ])

        #expect(editor.assignment(for: first.id) == SpeakerAssignment(
            speakerID: "jamie",
            provenance: .manual
        ))
        #expect(editor.assignment(for: second.id) == SpeakerAssignment(
            speakerID: "ai-speaker",
            provenance: .aiSuggestion
        ))

        let reprocessedFirst = try utterance(
            id: first.id.uuidString,
            source: .system,
            start: 10,
            end: 1_010,
            text: "fresh transcript first",
            baseSpeakerID: "remote"
        )
        let reprocessedSecond = try utterance(
            id: second.id.uuidString,
            source: .system,
            start: 1_010,
            end: 2_010,
            text: "fresh transcript second",
            baseSpeakerID: "remote"
        )
        editor.reprocessFinalUtterances([reprocessedSecond, reprocessedFirst])

        #expect(editor.assignment(for: first.id) == SpeakerAssignment(
            speakerID: "jamie",
            provenance: .manual
        ))
        #expect(editor.assignment(for: second.id) == SpeakerAssignment(
            speakerID: "ai-speaker",
            provenance: .aiSuggestion
        ))
        #expect(editor.utterances.first { $0.id == first.id }?.text == "fresh transcript first")
        #expect(editor.utterances.first { $0.id == first.id }?.startMilliseconds == 10)
    }

    @Test
    func mergedSourceIDsRemainManualForNewReprocessedUtterances() throws {
        let remote = try utterance(
            id: "00000000-0000-0000-0000-000000000041",
            source: .system,
            start: 0,
            end: 1_000,
            text: "remote"
        )
        var editor = SpeakerEditor(utterances: [remote])
        let merged = editor.merge(speakerIDs: ["remote"], into: "you")
        #expect(merged)

        let laterRemote = try utterance(
            id: "00000000-0000-0000-0000-000000000042",
            source: .system,
            start: 1_000,
            end: 2_000,
            text: "later remote"
        )
        editor.reprocessFinalUtterances([remote, laterRemote])

        #expect(editor.assignment(for: laterRemote.id) == SpeakerAssignment(
            speakerID: "you",
            provenance: .manual
        ))
        editor.applyAISuggestions([laterRemote.id: "another-ai-speaker"])
        #expect(editor.assignment(for: laterRemote.id) == SpeakerAssignment(
            speakerID: "you",
            provenance: .manual
        ))
    }

    @Test
    func talkTimeUnionsSameSpeakerAndKeepsSimultaneousSpeakers() throws {
        let youOne = try utterance(
            id: "00000000-0000-0000-0000-000000000051",
            source: .microphone,
            start: 0,
            end: 1_000,
            text: "one"
        )
        let youOverlap = try utterance(
            id: "00000000-0000-0000-0000-000000000052",
            source: .microphone,
            start: 500,
            end: 1_500,
            text: "two"
        )
        let simultaneousRemote = try utterance(
            id: "00000000-0000-0000-0000-000000000053",
            source: .system,
            start: 500,
            end: 1_500,
            text: "three"
        )
        let suppressed = try utterance(
            id: "00000000-0000-0000-0000-000000000054",
            source: .system,
            start: 0,
            end: 9_000,
            text: "duplicate",
            suppressed: true
        )
        let editor = SpeakerEditor(utterances: [
            simultaneousRemote, suppressed, youOverlap, youOne,
        ])

        let chart = TalkTimeCalculator().calculate(for: editor)
        let you = try #require(chart.data.first { $0.speakerID == "you" })
        let remote = try #require(chart.data.first { $0.speakerID == "remote" })

        #expect(you.durationMilliseconds == 1_500)
        #expect(you.utteranceCount == 2)
        #expect(you.percentage == 60)
        #expect(remote.durationMilliseconds == 1_000)
        #expect(remote.utteranceCount == 1)
        #expect(remote.percentage == 40)
        #expect(chart.totalAttributedSpeechMilliseconds == 2_500)
        #expect(chart.data.map(\.speakerID) == ["you", "remote"])
        #expect(abs(chart.data.map(\.percentage).reduce(0, +) - 100) < 0.000_001)
        #expect(you.accessibilityLabel.contains("2 utterances"))
    }

    @Test
    func talkTimeSplitsClusteredRemoteSpeakers() throws {
        let you = try utterance(
            id: "00000000-0000-0000-0000-000000000071",
            source: .microphone,
            start: 0,
            end: 1_000,
            text: "me"
        )
        let remoteTwo = try utterance(
            id: "00000000-0000-0000-0000-000000000072",
            source: .system,
            start: 0,
            end: 2_000,
            text: "a",
            base: "remote-2"
        )
        let remoteThree = try utterance(
            id: "00000000-0000-0000-0000-000000000073",
            source: .system,
            start: 2_000,
            end: 3_000,
            text: "b",
            base: "remote-3"
        )
        let chart = TalkTimeCalculator().calculate(utterances: [you, remoteTwo, remoteThree])
        #expect(Set(chart.data.map(\.speakerID)) == ["you", "remote-2", "remote-3"])
        #expect(chart.data.first { $0.speakerID == "remote-2" }?.displayName == "Speaker 2")
        #expect(chart.data.first { $0.speakerID == "remote-3" }?.displayName == "Speaker 3")
        #expect(chart.data.contains { $0.speakerID == "remote" } == false)
    }

    @Test
    func talkTimeKeepsAcceptedSuggestionsAndIgnoresAdvisoryOnes() throws {
        let accepted = try utterance(
            id: "00000000-0000-0000-0000-000000000081",
            source: .system,
            start: 0,
            end: 2_000,
            text: "a",
            base: "remote-2"
        )
        let suggested = try utterance(
            id: "00000000-0000-0000-0000-000000000082",
            source: .system,
            start: 2_000,
            end: 3_000,
            text: "b",
            base: "remote-3"
        )
        let chart = TalkTimeCalculator().calculate(
            utterances: [accepted, suggested],
            assignments: [
                accepted.id: SpeakerAssignment(speakerID: "alex", provenance: .aiAccepted),
                suggested.id: SpeakerAssignment(speakerID: "sam", provenance: .aiSuggestion),
            ],
            speakers: [
                "alex": MeetingSpeaker(id: "alex", displayName: "Alex"),
                "sam": MeetingSpeaker(id: "sam", displayName: "Sam"),
            ]
        )

        #expect(Set(chart.data.map(\.speakerID)) == ["alex", "remote-3"])
        #expect(chart.data.first { $0.speakerID == "alex" }?.displayName == "Alex")
        #expect(chart.data.first { $0.speakerID == "alex" }?.durationMilliseconds == 2_000)
        #expect(chart.data.contains { $0.speakerID == "remote" } == false)
    }

    @Test
    func zeroSpeechAndChartOrderingAndColorsAreStable() throws {
        let point = try utterance(
            id: "00000000-0000-0000-0000-000000000061",
            source: .microphone,
            start: 500,
            end: 500,
            text: "point"
        )
        let suppressed = try utterance(
            id: "00000000-0000-0000-0000-000000000062",
            source: .system,
            start: 0,
            end: 1_000,
            text: "hidden",
            suppressed: true
        )
        let calculator = TalkTimeCalculator()

        let zero = calculator.calculate(utterances: [suppressed, point])
        #expect(zero.totalAttributedSpeechMilliseconds == 0)
        #expect(zero.data.count == 1)
        #expect(zero.data[0].speakerID == "you")
        #expect(zero.data[0].durationMilliseconds == 0)
        #expect(zero.data[0].percentage == 0)
        #expect(zero.data[0].utteranceCount == 1)
        #expect(calculator.calculate(utterances: []).data.isEmpty)

        let equalYou = try utterance(
            id: "00000000-0000-0000-0000-000000000063",
            source: .microphone,
            start: 0,
            end: 1_000,
            text: "you"
        )
        let equalRemote = try utterance(
            id: "00000000-0000-0000-0000-000000000064",
            source: .system,
            start: 2_000,
            end: 3_000,
            text: "remote"
        )
        let forward = calculator.calculate(utterances: [equalYou, equalRemote]).data
        let reversed = calculator.calculate(utterances: [equalRemote, equalYou]).data

        #expect(forward == reversed)
        #expect(forward.map(\.speakerID) == ["remote", "you"])
        #expect(forward.map(\.colorKey) == reversed.map(\.colorKey))
        #expect(forward.allSatisfy { !$0.colorKey.isEmpty })
        #expect(abs(forward.map(\.percentage).reduce(0, +) - 100) < 0.000_001)
    }

    private func transcriptFields(_ utterances: [MeetingUtterance]) -> [TranscriptFields] {
        utterances.map {
            TranscriptFields(
                id: $0.id,
                source: $0.source,
                start: $0.startMilliseconds,
                end: $0.endMilliseconds,
                text: $0.text,
                suppressed: $0.suppressed
            )
        }
    }

    private func utterance(
        id: String = UUID().uuidString,
        source: MeetingUtteranceSource,
        start: Int64,
        end: Int64,
        text: String,
        base: String? = nil,
        baseSpeakerID: String? = nil,
        suppressed: Bool = false
    ) throws -> MeetingUtterance {
        try MeetingUtterance(
            id: UUID(uuidString: id)!,
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            text: text,
            baseSpeakerID: base ?? baseSpeakerID ?? (source == .microphone ? "you" : "remote"),
            suppressed: suppressed
        )
    }

    private struct TranscriptFields: Equatable {
        let id: UUID
        let source: MeetingUtteranceSource
        let start: Int64
        let end: Int64
        let text: String
        let suppressed: Bool
    }
}
