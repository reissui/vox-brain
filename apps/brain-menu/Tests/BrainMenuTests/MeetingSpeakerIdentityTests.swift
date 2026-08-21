import Foundation
import Testing
@testable import BrainMenu

struct MeetingSpeakerIdentityTests {
    @Test
    func clusteredIDsStartAtTwoAndIgnoreJunk() {
        #expect(MeetingSpeakerIdentity.clusteredID(index: 2) == "remote-2")
        #expect(MeetingSpeakerIdentity.isClusteredID("remote-2"))
        #expect(MeetingSpeakerIdentity.isClusteredID("remote-10"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-0"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-1"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-02"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-٢"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("remote-2x"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("untrusted-diarization"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("speaker-deadbeef"))
        #expect(!MeetingSpeakerIdentity.isClusteredID("you"))
    }

    @Test
    func labelsAndResolverPreferManualThenMicThenClusterThenRemote() throws {
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "you") == "You")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote") == "Remote")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote-2") == "Speaker 2")
        #expect(MeetingSpeakerIdentity.defaultDisplayName(for: "remote-3") == "Speaker 3")
        #expect(SpeakerEditor.defaultDisplayName(for: "remote-2") == "Speaker 2")

        let utteranceID = UUID()
        let manual = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-2",
            assignment: SpeakerAssignment(speakerID: "alex", provenance: .manual),
            speakers: ["alex": MeetingSpeaker(id: "alex", displayName: "Alex")]
        )
        #expect(manual.id == "alex")
        #expect(manual.label == "Alex")
        #expect(manual.provenance == .manual)

        let mic = MeetingSpeakerIdentity.resolved(
            source: .microphone,
            baseSpeakerID: "untrusted",
            assignment: nil,
            speakers: [:]
        )
        #expect(mic.id == "you")
        #expect(mic.label == "You")

        let clustered = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-3",
            assignment: nil,
            speakers: [:]
        )
        #expect(clustered.id == "remote-3")
        #expect(clustered.label == "Speaker 3")

        let junk = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "untrusted-diarization",
            assignment: nil,
            speakers: [:]
        )
        #expect(junk.id == "remote")
        #expect(junk.label == "Remote")
        _ = utteranceID
    }

    @Test
    func acceptedSuggestionsWinAndAdvisorySuggestionsDoNot() {
        let accepted = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-2",
            assignment: SpeakerAssignment(speakerID: "alex", provenance: .aiAccepted),
            speakers: ["alex": MeetingSpeaker(id: "alex", displayName: "Alex")]
        )
        #expect(accepted.id == "alex")
        #expect(accepted.label == "Alex")
        #expect(accepted.provenance == .aiAccepted)

        let suggested = MeetingSpeakerIdentity.resolved(
            source: .system,
            baseSpeakerID: "remote-2",
            assignment: SpeakerAssignment(speakerID: "alex", provenance: .aiSuggestion),
            speakers: ["alex": MeetingSpeaker(id: "alex", displayName: "Alex")]
        )
        #expect(suggested.id == "remote-2")
        #expect(suggested.label == "Speaker 2")
        #expect(suggested.provenance == .sourceDefault)
    }
}
