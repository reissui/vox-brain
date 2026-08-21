import Foundation

enum MeetingSpeakerIdentity {
    static func clusteredID(index: Int) -> String { "remote-\(index)" }

    static func isClusteredID(_ id: String) -> Bool {
        guard id.hasPrefix("remote-") else { return false }
        let digits = id.dropFirst("remote-".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func defaultDisplayName(for speakerID: String) -> String {
        SpeakerEditor.defaultDisplayName(for: speakerID)
    }

    static func resolved(
        source: MeetingUtteranceSource,
        baseSpeakerID: String,
        assignment: SpeakerAssignment?,
        speakers: [String: MeetingSpeaker]
    ) -> (id: String, label: String, provenance: SpeakerAssignmentProvenance) {
        if let assignment, assignment.provenance == .manual {
            return (
                assignment.speakerID,
                speakers[assignment.speakerID]?.displayName
                    ?? defaultDisplayName(for: assignment.speakerID),
                assignment.provenance
            )
        }
        let speakerID: String
        if source == .microphone {
            speakerID = SpeakerEditor.youSpeakerID
        } else if isClusteredID(baseSpeakerID) {
            speakerID = baseSpeakerID
        } else {
            speakerID = SpeakerEditor.remoteSpeakerID
        }
        return (
            speakerID,
            speakers[speakerID]?.displayName ?? defaultDisplayName(for: speakerID),
            .sourceDefault
        )
    }
}
