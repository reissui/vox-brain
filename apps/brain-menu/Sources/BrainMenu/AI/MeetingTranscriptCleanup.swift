import Foundation

struct MeetingTranscriptCleanupMetrics: Equatable, Sendable {
    let fillerCount: Int
    let repeatedWordRunCount: Int
    let nonSpeechUtteranceCount: Int
}

/// Produces a conservative local projection when optional AI enhancement is
/// unavailable. Every edit remains traceable to one immutable raw utterance.
enum MeetingTranscriptCleanup {
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:um+|uh+|erm+|er+|ah+|hmm+|arr+)(?![\p{L}\p{N}])"#
    )
    private static let repeatedWordPattern = try! NSRegularExpression(
        pattern: #"(?i)\b([\p{L}\p{N}][\p{L}\p{N}’'-]*)(?:[\s,;:-]+\1\b){2,}"#
    )
    private static let repeatedWhitespacePattern = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let whitespaceBeforePunctuationPattern = try! NSRegularExpression(
        pattern: #"\s+([,.;:!?])"#
    )
    private static let punctuationCollisionPattern = try! NSRegularExpression(
        pattern: #"[,;:]+\s*([.!?])"#
    )
    private static let repeatedSeparatorPattern = try! NSRegularExpression(
        pattern: #"([,;:])(?:\s*[,;:])+"#
    )
    private static let leadingSeparatorPattern = try! NSRegularExpression(pattern: #"^[\s,;:]+"#)

    static func metrics(for attempt: MeetingTranscriptAttempt) -> MeetingTranscriptCleanupMetrics {
        var fillers = 0
        var repetitions = 0
        var nonSpeech = 0
        for utterance in attempt.utterances where !utterance.suppressed {
            fillers += matchCount(fillerPattern, in: utterance.text)
            repetitions += matchCount(repeatedWordPattern, in: utterance.text)
            if nonSpeechEvidence(for: utterance, in: attempt) != nil { nonSpeech += 1 }
        }
        return MeetingTranscriptCleanupMetrics(
            fillerCount: fillers,
            repeatedWordRunCount: repetitions,
            nonSpeechUtteranceCount: nonSpeech
        )
    }

    static func makeTranscript(
        attempt: MeetingTranscriptAttempt,
        turns: [MeetingTranscriptTurn],
        terminologyHash: String
    ) -> MeetingProcessedTranscript {
        var textByUtteranceID: [UUID: String] = [:]
        var corrections: [MeetingTranscriptCorrection] = []

        for utterance in attempt.utterances
            .filter({ !$0.suppressed })
            .sorted(by: MeetingUtterance.chronologicallyPrecedes) {
            let original = utterance.text
            guard !original.isEmpty else {
                textByUtteranceID[utterance.id] = original
                continue
            }
            if let evidence = nonSpeechEvidence(for: utterance, in: attempt) {
                textByUtteranceID[utterance.id] = ""
                corrections.append(MeetingTranscriptCorrection(
                    id: utterance.id,
                    utteranceIDs: [utterance.id],
                    kind: .hallucination,
                    before: original,
                    after: "",
                    reason: "Overlapping audio activity was classified as non-speech "
                        + "(\(Int(evidence.voicedMilliseconds.rounded())) voiced ms, "
                        + "ratio \(String(format: "%.2f", evidence.voicedRatio))).",
                    confidence: 1
                ))
                continue
            }

            let correctionSource = normalized(original)
            let cleaned = clean(correctionSource)
            textByUtteranceID[utterance.id] = cleaned.text
            guard cleaned.text != correctionSource else { continue }
            var detected: [String] = []
            if cleaned.fillerCount > 0 {
                detected.append("\(cleaned.fillerCount) standalone filler word"
                    + (cleaned.fillerCount == 1 ? "" : "s"))
            }
            if cleaned.repeatedWordRunCount > 0 {
                detected.append("\(cleaned.repeatedWordRunCount) accidental repeated-word run"
                    + (cleaned.repeatedWordRunCount == 1 ? "" : "s"))
            }
            corrections.append(MeetingTranscriptCorrection(
                id: utterance.id,
                utteranceIDs: [utterance.id],
                kind: .grammar,
                before: correctionSource,
                after: cleaned.text,
                reason: "Removed " + detected.joined(separator: " and ")
                    + " while preserving the remaining words and meaning.",
                confidence: 0.98
            ))
        }

        return MeetingProcessedTranscript(
            rawAttemptID: attempt.id,
            terminologyHash: terminologyHash,
            turns: turns.map { turn in
                MeetingProcessedTranscriptTurn(
                    id: turn.id,
                    utteranceIDs: turn.utteranceIDs,
                    startMilliseconds: turn.startMilliseconds,
                    endMilliseconds: turn.endMilliseconds,
                    speakerID: turn.speakerID,
                    speakerLabel: turn.speakerLabel,
                    text: turn.utteranceIDs.compactMap { textByUtteranceID[$0] }
                        .joined(separator: " "),
                    unclear: false
                )
            },
            bullets: [],
            corrections: corrections
        )
    }

    private struct CleanedText {
        let text: String
        let fillerCount: Int
        let repeatedWordRunCount: Int
    }

    private static func clean(_ value: String) -> CleanedText {
        let fillerCount = matchCount(fillerPattern, in: value)
        let repeatedWordRunCount = matchCount(repeatedWordPattern, in: value)
        guard fillerCount > 0 || repeatedWordRunCount > 0 else {
            return CleanedText(text: value, fillerCount: 0, repeatedWordRunCount: 0)
        }

        var text = replacing(repeatedWordPattern, in: value, with: "$1")
        text = replacing(fillerPattern, in: text, with: "")
        text = replacing(repeatedWhitespacePattern, in: text, with: " ")
        text = replacing(whitespaceBeforePunctuationPattern, in: text, with: "$1")
        text = replacing(punctuationCollisionPattern, in: text, with: "$1")
        text = replacing(repeatedSeparatorPattern, in: text, with: "$1")
        text = replacing(leadingSeparatorPattern, in: text, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanedText(
            text: text,
            fillerCount: fillerCount,
            repeatedWordRunCount: repeatedWordRunCount
        )
    }

    private static func nonSpeechEvidence(
        for utterance: MeetingUtterance,
        in attempt: MeetingTranscriptAttempt
    ) -> MeetingTranscriptSpeechEvidence? {
        let overlapping = attempt.spanOutcomes.filter { span in
            span.source.rawValue == utterance.source.rawValue
                && span.attemptedStartMilliseconds < utterance.endMilliseconds
                && span.attemptedEndMilliseconds > utterance.startMilliseconds
        }
        guard let evidence = overlapping.first?.speechEvidence,
              overlapping.allSatisfy({ !$0.speechEvidence.isSpeechBearing }) else {
            return nil
        }
        return evidence
    }

    private static func matchCount(_ expression: NSRegularExpression, in value: String) -> Int {
        expression.numberOfMatches(
            in: value,
            range: NSRange(location: 0, length: value.utf16.count)
        )
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: value.utf16.count),
            withTemplate: replacement
        )
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
