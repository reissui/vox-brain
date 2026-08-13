import CryptoKit
import Foundation

/// Converts final local meeting data into the single Markdown document sent to
/// Brain. The renderer has no filesystem, network, or audio API.
struct MeetingMarkdownRenderer: Sendable {
    static let captureSource = "Brain.app meeting"

    func render(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        storedAnalysis: StoredMeetingAnalysis?,
        notes: String? = nil
    ) -> String {
        render(
            meeting: meeting,
            utterances: utterances,
            analysis: meeting.analysisState == .completed ? storedAnalysis?.analysis : nil,
            speakerState: storedAnalysis?.speakerState ?? SpeakerEditingState(),
            notes: notes
        )
    }

    func render(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        analysis: MeetingAnalysis? = nil,
        speakerState: SpeakerEditingState = SpeakerEditingState(),
        notes: String? = nil
    ) -> String {
        let editedUtterances = SpeakerEditor(
            utterances: utterances,
            state: speakerState
        ).utterances.filter { !$0.suppressed }

        var sections: [String] = []
        sections.append("# \(Self.escapeHeading(meeting.title))")
        sections.append([
            "- Date: \(Self.escapeInline(Self.dateString(meeting.startedAt)))",
            "- Duration: \(Self.durationString(meeting: meeting, utterances: editedUtterances))",
            "- Engine: \(Self.escapeHeading(Self.engineDescription(meeting)))",
        ].joined(separator: "\n"))

        let participants = Self.participants(in: editedUtterances)
        let participantLines = participants.isEmpty
            ? "- Unknown speaker"
            : participants.map { Self.listItem($0) }.joined(separator: "\n")
        sections.append("## Participants\n\n\(participantLines)")

        if let analysis {
            sections.append("## Analysis title\n\n\(Self.escapeUnexpectedHeadings(analysis.title))")
            sections.append("## Summary\n\n\(Self.escapeUnexpectedHeadings(analysis.summary))")
            sections.append(Self.listSection(title: "Topics", values: analysis.topics))
            sections.append(Self.listSection(title: "Decisions", values: analysis.decisions))
            sections.append(Self.actionItemsSection(analysis.actionItems))
            sections.append(Self.listSection(title: "Risks", values: analysis.risks))
        }

        if let notes,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## Notes\n\n\(notes)")
        }

        let transcript = editedUtterances.map { utterance in
            let speaker = utterance.humanName
                ?? SpeakerEditor.defaultDisplayName(for: utterance.baseSpeakerID)
            let timestamp = "\(Self.timestamp(utterance.startMilliseconds))–\(Self.timestamp(utterance.endMilliseconds))"
            return "### [\(timestamp)] \(Self.escapeHeading(speaker))\n\n\(Self.escapeUnexpectedHeadings(utterance.text))"
        }.joined(separator: "\n\n")
        sections.append("## Transcript\n\n\(transcript)")

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func transcriptDigest(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func stableIdempotencyKey(meetingID: UUID, transcriptDigest: String) -> UUID {
        var material = Data("brain-meeting-transcript-v1\0".utf8)
        material.append(Data(meetingID.uuidString.lowercased().utf8))
        material.append(0)
        material.append(Data(transcriptDigest.lowercased().utf8))
        return uuid(from: SHA256.hash(data: material))
    }

    static func filenameSafeTitle(_ title: String) -> String {
        var result = title.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7f || scalar == "/" || scalar == ":" {
                return "-"
            }
            return Character(String(scalar))
        }.reduce(into: "") { $0.append($1) }

        result = result
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\n", with: "-")
            .replacingOccurrences(of: "\r", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        if result.isEmpty || result == "." || result == ".." {
            result = "Meeting"
        }

        // Leave room for `.md` and keep capture metadata bounded.
        result = String(result.prefix(116)).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = "Meeting" }
        return "\(result).md"
    }

    private static func participants(in utterances: [MeetingUtterance]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for utterance in utterances {
            let name = utterance.humanName
                ?? SpeakerEditor.defaultDisplayName(for: utterance.baseSpeakerID)
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    private static func engineDescription(_ meeting: MeetingRecord) -> String {
        if meeting.speechModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return meeting.speechEngine
        }
        return "\(meeting.speechEngine) / \(meeting.speechModel)"
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func durationString(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance]
    ) -> String {
        let wallClockMilliseconds: Int64?
        if let endedAt = meeting.endedAt {
            wallClockMilliseconds = max(
                0,
                Int64((endedAt.timeIntervalSince(meeting.startedAt) * 1_000).rounded())
            )
        } else {
            wallClockMilliseconds = utterances.map(\.endMilliseconds).max()
        }
        return timestamp(wallClockMilliseconds ?? 0)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = (value / 60_000) % 60
        let seconds = (value / 1_000) % 60
        let millis = value % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
    }

    private static func listSection(title: String, values: [String]) -> String {
        let body = values.isEmpty
            ? "- None"
            : values.map { listItem($0) }.joined(separator: "\n")
        return "## \(title)\n\n\(body)"
    }

    private static func actionItemsSection(_ items: [MeetingAnalysisActionItem]) -> String {
        guard !items.isEmpty else { return "## Action items\n\n- None" }
        let body = items.map { item -> String in
            var value = item.text
            if let owner = item.owner, !owner.isEmpty {
                value += " — Owner: \(owner)"
            }
            if let due = item.due, !due.isEmpty {
                value += " — Due: \(due)"
            }
            return listItem(value, marker: "- [ ] ")
        }.joined(separator: "\n")
        return "## Action items\n\n\(body)"
    }

    private static func listItem(_ value: String, marker: String = "- ") -> String {
        let safe = escapeUnexpectedHeadings(value)
            .replacingOccurrences(of: "\n", with: "\n  ")
        return marker + safe
    }

    /// Dynamic values placed in an ATX heading must remain on one heading and
    /// may not close/open Markdown or raw HTML syntax.
    private static func escapeHeading(_ value: String) -> String {
        escapeInline(value)
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    private static func escapeInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Transcript and analysis prose stays verbatim except where a line would
    /// otherwise become an unintended Markdown heading. The inserted escape is
    /// not rendered, so the user's visible text remains unchanged.
    private static func escapeUnexpectedHeadings(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                let indentation = text.prefix(while: { $0 == " " }).count
                guard indentation <= 3 else { return text }
                let markerIndex = text.index(text.startIndex, offsetBy: indentation)
                let suffix = text[markerIndex...]
                if suffix.first == "#" {
                    let hashes = suffix.prefix(while: { $0 == "#" }).count
                    let afterHashes = suffix.dropFirst(hashes)
                    if (1...6).contains(hashes), afterHashes.isEmpty || afterHashes.first?.isWhitespace == true {
                        text.insert("\\", at: markerIndex)
                        return text
                    }
                }

                let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 3,
                   trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                    text.insert("\\", at: markerIndex)
                }
                return text
            }
            .joined(separator: "\n")
    }

    private static func uuid<D: Sequence>(from digest: D) -> UUID where D.Element == UInt8 {
        var bytes = Array(digest.prefix(16))
        precondition(bytes.count == 16)
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
