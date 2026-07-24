import Foundation

/// Persist this state beside a processed transcript. An explicit Unsuppress
/// choice is keyed by the utterance's stable ID so a later duplicate-
/// suppression pass cannot reverse the user's choice.
struct EchoDuplicateSuppressionState: Codable, Equatable, Sendable {
    private(set) var manuallyUnsuppressedUtteranceIDs: Set<UUID>

    init(manuallyUnsuppressedUtteranceIDs: Set<UUID> = []) {
        self.manuallyUnsuppressedUtteranceIDs = manuallyUnsuppressedUtteranceIDs
    }

    func preventsAutomaticSuppression(of utteranceID: UUID) -> Bool {
        manuallyUnsuppressedUtteranceIDs.contains(utteranceID)
    }

    fileprivate mutating func registerManualUnsuppress(of utteranceID: UUID) {
        manuallyUnsuppressedUtteranceIDs.insert(utteranceID)
    }

    private enum CodingKeys: String, CodingKey {
        case manuallyUnsuppressedUtteranceIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manuallyUnsuppressedUtteranceIDs = Set(try container.decode(
            [UUID].self,
            forKey: .manuallyUnsuppressedUtteranceIDs
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            manuallyUnsuppressedUtteranceIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            forKey: .manuallyUnsuppressedUtteranceIDs
        )
    }
}

/// Records why a microphone utterance was hidden while retaining both source
/// utterances and their original text for audit and undo.
struct EchoDuplicateMatch: Equatable, Sendable {
    let microphoneUtteranceID: UUID
    let systemUtteranceID: UUID
    let overlapRatio: Double
    let tokenSimilarity: Double
}

struct EchoDuplicateSuppressionResult: Equatable, Sendable {
    let utterances: [MeetingUtterance]
    let matches: [EchoDuplicateMatch]

    var visibleUtterances: [MeetingUtterance] {
        utterances.filter { !$0.suppressed }
    }

    var suppressedMicrophoneUtterances: [MeetingUtterance] {
        utterances.filter { $0.source == .microphone && $0.suppressed }
    }

    /// Visible talk time deliberately includes system speech. Only a matching
    /// microphone copy is excluded by duplicate suppression.
    func visibleTalkTimeMilliseconds(for source: MeetingUtteranceSource) -> Int64 {
        visibleUtterances
            .filter { $0.source == source }
            .reduce(0) { accumulated, utterance in
                let duration = utterance.endMilliseconds - utterance.startMilliseconds
                let (sum, overflow) = accumulated.addingReportingOverflow(duration)
                return overflow ? .max : sum
            }
    }
}

/// Deterministic transcript-level duplicate suppression for speaker leakage.
/// This operates only on stored text and timestamps; it never changes audio.
struct EchoDuplicateSuppressor: Sendable {
    static let minimumOverlapRatio = 0.5
    static let maximumMicrophoneLeadMilliseconds: Int64 = 1_500
    static let minimumNormalizedTokenCount = 3
    static let minimumTokenSimilarity = 0.85

    func suppressDuplicates(
        in utterances: [MeetingUtterance],
        state: EchoDuplicateSuppressionState = EchoDuplicateSuppressionState()
    ) -> EchoDuplicateSuppressionResult {
        let systemUtterances = utterances
            .filter { $0.source == .system }
            .sorted(by: Self.utteranceOrder)
        let systemCandidates = systemUtterances.map {
            Candidate(utterance: $0, tokens: Self.normalizedTokens(in: $0.text))
        }

        var processed = utterances
        var matches: [EchoDuplicateMatch] = []

        for index in processed.indices {
            // Reprocessing starts from visible and computes the complete current
            // result. This clears stale automatic decisions while manual state
            // remains authoritative.
            processed[index].suppressed = false
            guard processed[index].source == .microphone,
                  !state.preventsAutomaticSuppression(of: processed[index].id)
            else { continue }

            let microphone = Candidate(
                utterance: processed[index],
                tokens: Self.normalizedTokens(in: processed[index].text)
            )
            guard microphone.tokens.count >= Self.minimumNormalizedTokenCount else {
                continue
            }

            guard let match = deterministicMatch(
                for: microphone,
                among: systemCandidates
            ) else {
                continue
            }
            processed[index].suppressed = true
            matches.append(match)
        }

        matches.sort {
            if $0.microphoneUtteranceID != $1.microphoneUtteranceID {
                return $0.microphoneUtteranceID.uuidString
                    < $1.microphoneUtteranceID.uuidString
            }
            return $0.systemUtteranceID.uuidString < $1.systemUtteranceID.uuidString
        }
        return EchoDuplicateSuppressionResult(utterances: processed, matches: matches)
    }

    /// Applies the user's explicit Unsuppress action immediately and records
    /// the override in Codable state for future processing passes.
    func manuallyUnsuppress(
        utteranceID: UUID,
        in utterances: [MeetingUtterance],
        state: inout EchoDuplicateSuppressionState
    ) -> EchoDuplicateSuppressionResult {
        if utterances.contains(where: {
            $0.id == utteranceID && $0.source == .microphone && $0.suppressed
        }) {
            state.registerManualUnsuppress(of: utteranceID)
        }
        return suppressDuplicates(in: utterances, state: state)
    }

    static func normalizedText(_ text: String) -> String {
        let caseFolded = text.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let punctuationRemoved = String(String.UnicodeScalarView(
            caseFolded.unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0)
            }
        ))
        return punctuationRemoved
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedTokens(in text: String) -> [String] {
        let normalized = normalizedText(text)
        return normalized.isEmpty ? [] : normalized.split(separator: " ").map(String.init)
    }

    static func tokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let total = max(lhs.count, rhs.count)
        guard total > 0 else { return 1 }
        let edits = tokenEditDistance(lhs, rhs)
        return Double(total - edits) / Double(total)
    }

    private func deterministicMatch(
        for microphone: Candidate,
        among systems: [Candidate]
    ) -> EchoDuplicateMatch? {
        for system in systems {
            guard microphone.utterance.startMilliseconds >=
                    system.utterance.startMilliseconds
                    - Self.maximumMicrophoneLeadMilliseconds,
                  Self.overlapsAtLeastHalf(microphone.utterance, system.utterance),
                  Self.tokensMeetSimilarityThreshold(microphone.tokens, system.tokens)
            else { continue }

            return EchoDuplicateMatch(
                microphoneUtteranceID: microphone.utterance.id,
                systemUtteranceID: system.utterance.id,
                overlapRatio: Self.overlapRatio(of: microphone.utterance, with: system.utterance),
                tokenSimilarity: Self.tokenSimilarity(microphone.tokens, system.tokens)
            )
        }
        return nil
    }

    private static func overlapsAtLeastHalf(
        _ microphone: MeetingUtterance,
        _ system: MeetingUtterance
    ) -> Bool {
        let microphoneDuration = microphone.endMilliseconds - microphone.startMilliseconds
        guard microphoneDuration > 0 else { return false }
        let overlap = overlapMilliseconds(of: microphone, with: system)
        let minimumOverlap = microphoneDuration / 2 + microphoneDuration % 2
        return overlap >= minimumOverlap
    }

    private static func overlapRatio(
        of microphone: MeetingUtterance,
        with system: MeetingUtterance
    ) -> Double {
        let duration = microphone.endMilliseconds - microphone.startMilliseconds
        guard duration > 0 else { return 0 }
        return Double(overlapMilliseconds(of: microphone, with: system)) / Double(duration)
    }

    private static func overlapMilliseconds(
        of lhs: MeetingUtterance,
        with rhs: MeetingUtterance
    ) -> Int64 {
        max(0, min(lhs.endMilliseconds, rhs.endMilliseconds)
            - max(lhs.startMilliseconds, rhs.startMilliseconds))
    }

    private static func tokensMeetSimilarityThreshold(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Bool {
        let total = max(lhs.count, rhs.count)
        guard total > 0 else { return true }
        let matched = total - tokenEditDistance(lhs, rhs)

        // Compare against 85/100 with integer arithmetic so the inclusive
        // threshold is not affected by floating-point rounding.
        let quotientAndRemainder = total.quotientAndRemainder(dividingBy: 100)
        let minimumMatched = quotientAndRemainder.quotient * 85
            + (quotientAndRemainder.remainder * 85 + 99) / 100
        return matched >= minimumMatched
    }

    private static func tokenEditDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        // Keep the row bounded by the shorter sequence.
        let columns: [String]
        let rows: [String]
        if lhs.count <= rhs.count {
            columns = lhs
            rows = rhs
        } else {
            columns = rhs
            rows = lhs
        }

        var previous = Array(0...columns.count)
        for (rowIndex, rowToken) in rows.enumerated() {
            var current = [rowIndex + 1]
            current.reserveCapacity(columns.count + 1)
            for (columnIndex, columnToken) in columns.enumerated() {
                let substitution = previous[columnIndex]
                    + (rowToken == columnToken ? 0 : 1)
                current.append(min(
                    current[columnIndex] + 1,
                    previous[columnIndex + 1] + 1,
                    substitution
                ))
            }
            previous = current
        }
        return previous[columns.count]
    }

    private static func utteranceOrder(
        _ lhs: MeetingUtterance,
        _ rhs: MeetingUtterance
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct Candidate {
        let utterance: MeetingUtterance
        let tokens: [String]
    }
}
