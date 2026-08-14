import Foundation

/// A short, call-specific prompt that contains quality signals but no private
/// transcript, notes, names, or terminology entries.
enum MeetingImprovementPrompt {
    static let maximumCharacters = 1_500

    static func make(
        meeting: MeetingRecord,
        attempt: MeetingTranscriptAttempt,
        processedTranscript: MeetingProcessedTranscript?
    ) -> String {
        make(attempt: attempt, processedTranscript: processedTranscript)
    }

    static func make(
        attempt: MeetingTranscriptAttempt,
        processedTranscript: MeetingProcessedTranscript?
    ) -> String {
        let attestation = attempt.modelAttestation
        let requested = modelIdentity(attestation.requestedSelection)
        let effective = modelIdentity(attestation.effectiveSelection)
        let verified = attestation.verificationState == .verified
            && attestation.requestedSelection == attestation.effectiveSelection
        let failures = attempt.failures.sorted(by: failureOrder)
        let cleanup = MeetingTranscriptCleanup.metrics(for: attempt)
        let correctionCounts = Dictionary(
            grouping: processedTranscript?.corrections ?? [],
            by: \MeetingTranscriptCorrection.kind
        ).mapValues(\.count)

        var issues: [String] = []
        if cleanup.fillerCount > 0 || cleanup.repeatedWordRunCount > 0 {
            issues.append(
                "- \(cleanup.fillerCount) filler word"
                    + (cleanup.fillerCount == 1 ? "" : "s")
                    + " and \(cleanup.repeatedWordRunCount) repeated-word run"
                    + (cleanup.repeatedWordRunCount == 1 ? "" : "s")
                    + " were detected; distinguish accidental disfluency from intentional emphasis."
            )
        }
        if cleanup.nonSpeechUtteranceCount > 0 {
            issues.append(
                "- \(cleanup.nonSpeechUtteranceCount) utterance"
                    + (cleanup.nonSpeechUtteranceCount == 1 ? " overlaps" : "s overlap")
                    + " audio classified as non-speech; verify before removing it."
            )
        }
        if !failures.isEmpty {
            let ranges = failures.prefix(6).map { failure in
                failure.startMilliseconds.map { start in
                    "\(timestamp(start))-\(timestamp(failure.endMilliseconds ?? start))"
                } ?? "timestamp unavailable"
            }.joined(separator: ", ")
            let categories = Dictionary(grouping: failures, by: {
                failureCategory($0.message)
            }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
            issues.append(
                "- \(attempt.failureTotals.final) final audio span"
                    + (attempt.failureTotals.final == 1 ? " was" : "s were")
                    + " skipped or failed at \(ranges) (\(categories))."
            )
        }
        if !verified {
            issues.append("- Model identity is unverified (requested \(requested), effective \(effective)).")
        }
        if let processedTranscript, !processedTranscript.corrections.isEmpty {
            let kinds = MeetingTranscriptCorrectionKind.allCases.compactMap { kind in
                let count = correctionCounts[kind, default: 0]
                return count > 0 ? "\(kind.rawValue)=\(count)" : nil
            }.joined(separator: ", ")
            issues.append("- Existing processing recorded \(processedTranscript.corrections.count) corrections (\(kinds)).")
        }
        if issues.isEmpty {
            issues.append("- No explicit failures were recorded; check only for subtle readability errors.")
        }

        let lines = [
            "Improve this meeting transcript using the retained audio and immutable raw evidence.",
            "",
            "Detected issues:"
        ] + issues + [
            "",
            "Compare the flagged timestamps with the audio-derived previews and speech activity. Remove fillers and accidental repetition, repair only well-supported wording, mark genuinely unclear audio as [unclear], and preserve names, numbers, decisions, speaker meaning, and intentional emphasis. Do not change the Raw transcript."
        ]

        return bounded(lines)
    }

    private static func bounded(_ lines: [String]) -> String {
        var value = ""
        for line in lines {
            let candidate = value.isEmpty ? line : value + "\n" + line
            guard candidate.count <= maximumCharacters else {
                let suffix = "\n[Additional diagnostics omitted to keep this prompt local and bounded.]"
                let available = max(0, maximumCharacters - suffix.count)
                return String(value.prefix(available)) + suffix
            }
            value = candidate
        }
        return value
    }

    private static func modelIdentity(_ selection: SpeechEngineSelection) -> String {
        "\(selection.engine.rawValue)/\(selection.modelID)"
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    private static func failureCategory(_ value: String) -> String {
        let normalized = value.lowercased()
        if normalized.contains("timeout") || normalized.contains("timed out") { return "timeout" }
        if normalized.contains("cancel") { return "cancelled" }
        if normalized.contains("model") || normalized.contains("engine") { return "model" }
        if normalized.contains("schema") || normalized.contains("json") { return "schema" }
        if normalized.contains("persist") || normalized.contains("write") { return "persistence" }
        if normalized.contains("audio") || normalized.contains("speech") { return "audio" }
        return "other"
    }

    private static func failureOrder(
        _ lhs: MeetingTranscriptFailureDiagnostic,
        _ rhs: MeetingTranscriptFailureDiagnostic
    ) -> Bool {
        let lhsStart = lhs.startMilliseconds ?? Int64.max
        let rhsStart = rhs.startMilliseconds ?? Int64.max
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.phase != rhs.phase { return lhs.phase.rawValue < rhs.phase.rawValue }
        return lhs.message < rhs.message
    }
}
