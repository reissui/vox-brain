import Foundation

/// A bounded, diagnostic-only prompt that the owner may copy into a tool of
/// their choice. It intentionally contains no transcript, notes, names, or
/// terminology entries.
enum MeetingImprovementPrompt {
    static let maximumCharacters = 4_000

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
        let verification = verified ? "verified" : "unverified"
        let spans = attempt.spanOutcomes.sorted(by: spanOrder)
        let failures = attempt.failures.sorted(by: failureOrder)
        let evidenceStarts = spans.map(\.originalStartMilliseconds)
            + attempt.utterances.map(\.startMilliseconds)
        let evidenceEnds = spans.map(\.originalEndMilliseconds)
            + attempt.utterances.map(\.endMilliseconds)
        let windowSpan = if let start = evidenceStarts.min(), let end = evidenceEnds.max() {
            "\(timestamp(start))-\(timestamp(end)) (\(max(0, end - start)) ms)"
        } else {
            "none"
        }
        let totalFinalWindowMilliseconds = spans.reduce(Int64(0)) {
            $0 + max(0, $1.originalEndMilliseconds - $1.originalStartMilliseconds)
        }
        let correctionCounts = Dictionary(
            grouping: processedTranscript?.corrections ?? [],
            by: \MeetingTranscriptCorrection.kind
        ).mapValues(\.count)

        var lines = [
            "Meeting transcript quality improvement request",
            "",
            "Evidence summary (diagnostics only; no transcript content is included):",
            "- Requested speech model: \(requested)",
            "- Effective speech model: \(effective)",
            "- Model verification: \(verification)",
            "- Raw attempt ID: \(attempt.id.uuidString.lowercased())",
            "- Raw utterances: \(attempt.utterances.count)",
            "- Retained live previews: \(attempt.retainedPreviews.count)",
            "- Attempt window span: \(windowSpan)",
            "- Final windows: \(spans.count)",
            "- Final window duration: \(totalFinalWindowMilliseconds) ms",
            "- Skipped/failed final windows: \(attempt.failureTotals.final)",
            "- Failures: \(attempt.failureTotals.total) total, \(attempt.failureTotals.systemic) systemic, \(attempt.failureTotals.preview) preview, \(attempt.failureTotals.final) final",
            "- Corrections: \(processedTranscript?.corrections.count ?? 0) total"
        ]

        for kind in MeetingTranscriptCorrectionKind.allCases {
            lines.append("  - \(kind.rawValue): \(correctionCounts[kind, default: 0])")
        }

        lines.append("")
        lines.append("Window spans:")
        if spans.isEmpty {
            lines.append("- None recorded")
        } else {
            for (index, span) in spans.prefix(20).enumerated() {
                let outcome = span.failure == nil && !span.wasCancelled ? "completed" : "failed/skipped"
                lines.append(
                    "- \(index + 1). \(timestamp(span.originalStartMilliseconds))-\(timestamp(span.originalEndMilliseconds)); \(span.source.rawValue); requests=\(span.requestCount); \(outcome)"
                )
            }
            if spans.count > 20 { lines.append("- \(spans.count - 20) additional windows omitted") }
        }

        lines.append("")
        lines.append("Failure diagnostics:")
        if failures.isEmpty {
            lines.append("- None recorded")
        } else {
            for failure in failures.prefix(12) {
                let range = failure.startMilliseconds.map { start in
                    "\(timestamp(start))-\(timestamp(failure.endMilliseconds ?? start))"
                } ?? "timestamp unavailable"
                lines.append(
                    "- \(range); \(failure.source.rawValue); \(failure.phase.rawValue); systemic=\(failure.isSystemic); category=\(failureCategory(failure.message))"
                )
            }
            if failures.count > 12 { lines.append("- \(failures.count - 12) additional failures omitted") }
        }

        lines += [
            "",
            "Concrete checks:",
            "1. Verify the configured model resolves to the effective model and reports a fresh attestation.",
            "2. Reproduce each failed final window at its timestamp and classify capture, speech-gate, model, timeout, or persistence cause.",
            "3. Compare retained preview and final-window counts to find speech lost during finalization.",
            "4. Use correction-kind counts to prioritize terminology, hallucination, punctuation, grammar, boundary, and unclear-audio regressions.",
            "5. Add a deterministic regression check for every confirmed failure without changing immutable raw evidence."
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

    private static func spanOrder(
        _ lhs: MeetingTranscriptSpanOutcome,
        _ rhs: MeetingTranscriptSpanOutcome
    ) -> Bool {
        if lhs.originalStartMilliseconds != rhs.originalStartMilliseconds {
            return lhs.originalStartMilliseconds < rhs.originalStartMilliseconds
        }
        if lhs.originalEndMilliseconds != rhs.originalEndMilliseconds {
            return lhs.originalEndMilliseconds < rhs.originalEndMilliseconds
        }
        return lhs.source.rawValue < rhs.source.rawValue
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
