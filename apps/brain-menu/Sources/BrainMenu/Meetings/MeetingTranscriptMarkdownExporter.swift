import Foundation

/// Writes readable Markdown exports beside the meeting's JSON transcript files.
struct MeetingTranscriptMarkdownExporter {
    static let rawFilename = "raw-transcript.md"
    static let processedFilename = "processed-transcript.md"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func rawURL(meetingID: UUID, rootURL: URL = MeetingStore.productionRootURL) -> URL {
        meetingDirectory(meetingID: meetingID, rootURL: rootURL)
            .appendingPathComponent(Self.rawFilename)
    }

    func processedURL(meetingID: UUID, rootURL: URL = MeetingStore.productionRootURL) -> URL {
        meetingDirectory(meetingID: meetingID, rootURL: rootURL)
            .appendingPathComponent(Self.processedFilename)
    }

    func renderRaw(
        meeting: MeetingRecord,
        attempt: MeetingTranscriptAttempt,
        speakerState: SpeakerEditingState = SpeakerEditingState(),
        suppressionSource: [MeetingUtterance] = []
    ) -> String {
        let merged = attempt.applyingSuppressions(from: suppressionSource)
        let turns = MeetingTranscriptTurnAssembler.assemble(
            utterances: merged.utterances,
            assignments: speakerState.assignments,
            speakers: speakerState.speakers
        )
        return render(
            meeting: meeting,
            titleSuffix: "Raw Transcript",
            turns: turns.map { (timestamp: $0.startMilliseconds, speaker: $0.speakerLabel, text: $0.text) }
        )
    }

    func renderProcessed(
        meeting: MeetingRecord,
        processedTranscript: MeetingProcessedTranscript
    ) -> String {
        let turns = processedTranscript.turns.compactMap { turn -> (Int64, String, String)? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (turn.startMilliseconds, turn.speakerLabel, text)
        }
        return render(
            meeting: meeting,
            titleSuffix: "Processed Transcript",
            turns: turns
        )
    }

    @discardableResult
    func writeRaw(
        meeting: MeetingRecord,
        attempt: MeetingTranscriptAttempt,
        speakerState: SpeakerEditingState = SpeakerEditingState(),
        suppressionSource: [MeetingUtterance] = [],
        rootURL: URL = MeetingStore.productionRootURL
    ) throws -> URL {
        let markdown = renderRaw(
            meeting: meeting,
            attempt: attempt,
            speakerState: speakerState,
            suppressionSource: suppressionSource
        )
        let destination = rawURL(meetingID: meeting.id, rootURL: rootURL)
        try write(markdown, to: destination)
        return destination
    }

    @discardableResult
    func writeProcessed(
        meeting: MeetingRecord,
        processedTranscript: MeetingProcessedTranscript,
        rootURL: URL = MeetingStore.productionRootURL
    ) throws -> URL {
        let markdown = renderProcessed(meeting: meeting, processedTranscript: processedTranscript)
        let destination = processedURL(meetingID: meeting.id, rootURL: rootURL)
        try write(markdown, to: destination)
        return destination
    }

    func export(
        markdown: String,
        to destination: URL
    ) throws {
        try write(markdown, to: destination)
    }

    private func render(
        meeting: MeetingRecord,
        titleSuffix: String,
        turns: [(timestamp: Int64, speaker: String, text: String)]
    ) -> String {
        var sections: [String] = []
        sections.append("# \(escapeInline(meeting.title)) — \(titleSuffix)")
        sections.append([
            "- Date: \(escapeInline(isoDate(meeting.startedAt)))",
            "- Duration: \(escapeInline(durationText(meeting: meeting, turns: turns)))",
        ].joined(separator: "\n"))

        let body = turns.map { turn in
            let timestamp = Self.timestamp(turn.timestamp)
            return "### [\(timestamp)] \(escapeHeading(turn.speaker))\n\n\(escapeBody(turn.text))"
        }.joined(separator: "\n\n")

        if body.isEmpty {
            sections.append("## Transcript\n\n_No transcript text._")
        } else {
            sections.append("## Transcript\n\n\(body)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private func write(
        _ markdown: String,
        to destination: URL
    ) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: destination, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
    }

    private func meetingDirectory(meetingID: UUID, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    private func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func durationText(
        meeting: MeetingRecord,
        turns: [(timestamp: Int64, speaker: String, text: String)]
    ) -> String {
        let wallClockMilliseconds: Int64?
        if let endedAt = meeting.endedAt {
            wallClockMilliseconds = max(
                0,
                Int64((endedAt.timeIntervalSince(meeting.startedAt) * 1_000).rounded())
            )
        } else {
            wallClockMilliseconds = turns.map(\.timestamp).max()
        }
        return Self.timestamp(wallClockMilliseconds ?? 0)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let value = max(0, milliseconds)
        let hours = value / 3_600_000
        let minutes = (value / 60_000) % 60
        let seconds = (value / 1_000) % 60
        let millis = value % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, millis)
    }

    private func escapeHeading(_ value: String) -> String {
        escapeInline(value)
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private func escapeInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "#", with: "\\#")
    }

    private func escapeBody(_ value: String) -> String {
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
                    }
                }
                return text
            }
            .joined(separator: "\n")
    }
}

extension MeetingTranscriptAttempt {
    /// Applies user suppressions from the editable transcript without mutating
    /// the immutable raw artifact on disk.
    func applyingSuppressions(from editedUtterances: [MeetingUtterance]) -> MeetingTranscriptAttempt {
        let suppressedIDs = Set(editedUtterances.filter(\.suppressed).map(\.id))
        guard !suppressedIDs.isEmpty else { return self }
        var copy = self
        copy.utterances = utterances.map { utterance in
            var merged = utterance
            if suppressedIDs.contains(utterance.id) {
                merged.suppressed = true
            }
            return merged
        }
        return copy
    }
}
