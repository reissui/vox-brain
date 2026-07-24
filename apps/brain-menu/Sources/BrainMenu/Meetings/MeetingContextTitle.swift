import Foundation

enum MeetingContextTitle {
    static let maximumWords = 9

    static func make(
        utterances: [MeetingUtterance],
        applicationName: String?
    ) -> String {
        let ordered = utterances
            .filter { !$0.suppressed }
            .sorted {
                if $0.startMilliseconds != $1.startMilliseconds {
                    return $0.startMilliseconds < $1.startMilliseconds
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        // The microphone is the most reliable source of the meeting's intent:
        // system audio may contain a video or other playback that happened to
        // be audible when recording began. AI analysis can refine this later.
        for source in [MeetingUtteranceSource.microphone, .system] {
            for utterance in ordered where utterance.source == source {
                if let title = title(from: utterance.text) { return title }
            }
        }

        guard let applicationName = applicationName?.trimmedMeetingTitleText,
              !applicationName.isEmpty else {
            return "Meeting"
        }
        return "Meeting in \(applicationName)"
    }

    static func normalizedAnalysisTitle(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(100))
    }

    private static func title(from text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let sentences = normalized.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences {
            var candidate = sentence.trimmedMeetingTitleText
            candidate = strippingOpeners(from: candidate)
            let words = candidate.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count >= 3 else { continue }
            let bounded = Array(words.prefix(maximumWords))
            let title = bounded.enumerated().map { index, word in
                titleWord(word, isFirst: index == 0)
            }.joined(separator: " ")
            let lowercased = title.lowercased()
            guard lowercased != "thank you very much",
                  lowercased != "can you hear me" else { continue }
            return title
        }
        return nil
    }

    private static func strippingOpeners(from value: String) -> String {
        var result = value
        let openers = [
            "all right", "alright", "okay", "ok", "so", "well", "hello", "hi",
            "this is me", "we are here to", "we're here to", "we need to",
            "we are going to", "we're going to", "let's talk about",
        ]
        var changed = true
        while changed {
            changed = false
            let lowercased = result.lowercased()
            for opener in openers where lowercased == opener
                || lowercased.hasPrefix(opener + " ")
                || lowercased.hasPrefix(opener + ",") {
                result = String(result.dropFirst(opener.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                        CharacterSet(charactersIn: ",:;-—")
                    ))
                changed = true
                break
            }
        }
        return result
    }

    private static func titleWord(_ value: String, isFirst: Bool) -> String {
        let stopWords = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to"]
        let clean = value.trimmingCharacters(in: .punctuationCharacters)
        guard !clean.isEmpty else { return value }
        if !isFirst, stopWords.contains(clean.lowercased()) { return clean.lowercased() }
        if clean == clean.uppercased(), clean.count > 1 { return clean }
        return clean.prefix(1).uppercased() + clean.dropFirst()
    }
}

private extension String {
    var trimmedMeetingTitleText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
