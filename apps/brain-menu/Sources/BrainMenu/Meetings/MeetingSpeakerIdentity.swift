import Foundation

enum MeetingSpeakerIdentity {
    static let clusterPrefix = "remote-"
    /// `remote` already means the undifferentiated remote side, so a cluster
    /// only exists once the diarizer found at least two distinct voices.
    static let firstClusterIndex = 2

    static func clusteredID(index: Int) -> String { "\(clusterPrefix)\(index)" }

    static func isClusteredID(_ id: String) -> Bool {
        guard id.hasPrefix(clusterPrefix) else { return false }
        let digits = id.dropFirst(clusterPrefix.count)
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.first != "0",
              let index = Int(digits) else { return false }
        return index >= firstClusterIndex
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
        // A manual edit and an explicitly accepted suggestion are both the
        // owner's own decision, so either outranks any clustered or default ID.
        // An unaccepted `aiSuggestion` stays advisory.
        if let assignment, assignment.provenance == .manual || assignment.provenance == .aiAccepted {
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
