import Foundation

/// A display-ready span of adjacent transcript utterances from one speaker.
///
/// Turns deliberately retain their source utterance IDs so speaker editing can
/// still act on the original, persisted transcript records.
struct MeetingTranscriptTurn: Equatable, Identifiable, Sendable {
    let id: UUID
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let utteranceIDs: [UUID]
    let source: MeetingUtteranceSource
    let speakerID: String
    let speakerLabel: String
    let provenance: SpeakerAssignmentProvenance
    let text: String
}

enum MeetingTranscriptTurnAssembler {
    static let silenceBreakMilliseconds: Int64 = 8_000

    static func assemble(
        utterances: [MeetingUtterance],
        assignments: [UUID: SpeakerAssignment] = [:],
        speakers: [String: MeetingSpeaker] = [:]
    ) -> [MeetingTranscriptTurn] {
        let ordered = utterances
            .filter { !$0.suppressed }
            .sorted(by: MeetingUtterance.chronologicallyPrecedes)

        var turns: [MeetingTranscriptTurn] = []
        for utterance in ordered {
            let speaker = resolvedSpeaker(
                for: utterance,
                assignment: assignments[utterance.id],
                speakers: speakers
            )
            let text = normalized(utterance.text)

            if let lastIndex = turns.indices.last,
               turns[lastIndex].speakerID == speaker.id,
               utterance.startMilliseconds - turns[lastIndex].endMilliseconds < silenceBreakMilliseconds {
                let previous = turns[lastIndex]
                turns[lastIndex] = MeetingTranscriptTurn(
                    id: previous.id,
                    startMilliseconds: previous.startMilliseconds,
                    endMilliseconds: max(previous.endMilliseconds, utterance.endMilliseconds),
                    utteranceIDs: previous.utteranceIDs + [utterance.id],
                    source: previous.source,
                    speakerID: previous.speakerID,
                    speakerLabel: previous.speakerLabel,
                    provenance: previous.provenance,
                    text: joined(previous.text, text)
                )
            } else {
                turns.append(MeetingTranscriptTurn(
                    id: utterance.id,
                    startMilliseconds: utterance.startMilliseconds,
                    endMilliseconds: utterance.endMilliseconds,
                    utteranceIDs: [utterance.id],
                    source: utterance.source,
                    speakerID: speaker.id,
                    speakerLabel: speaker.label,
                    provenance: speaker.provenance,
                    text: text
                ))
            }
        }
        return turns
    }

    private static func resolvedSpeaker(
        for utterance: MeetingUtterance,
        assignment: SpeakerAssignment?,
        speakers: [String: MeetingSpeaker]
    ) -> (id: String, label: String, provenance: SpeakerAssignmentProvenance) {
        if let assignment, assignment.provenance == .manual {
            return (
                assignment.speakerID,
                speakers[assignment.speakerID]?.displayName
                    ?? SpeakerEditor.defaultDisplayName(for: assignment.speakerID),
                assignment.provenance
            )
        }

        // System audio is a single remote participant until a person assigns
        // otherwise; transcript grouping does not infer diarized speakers.
        let speakerID: String
        if utterance.source == .system {
            speakerID = SpeakerEditor.remoteSpeakerID
        } else if !utterance.baseSpeakerID.isEmpty {
            speakerID = utterance.baseSpeakerID
        } else {
            speakerID = SpeakerEditor.youSpeakerID
        }
        return (
            speakerID,
            utterance.humanName ?? SpeakerEditor.defaultDisplayName(for: speakerID),
            .sourceDefault
        )
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, _): rhs
        case (_, true): lhs
        case (false, false): lhs + " " + rhs
        }
    }
}
