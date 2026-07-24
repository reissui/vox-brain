import Foundation
import Testing
@testable import BrainMenu

struct EchoDuplicateSuppressorTests {
    private let suppressor = EchoDuplicateSuppressor()

    @Test
    func exactDuplicateIsRetainedForAuditWhileSystemSpeechStaysVisible() throws {
        let system = try utterance(
            id: "00000000-0000-0000-0000-000000000001",
            source: .system,
            start: 1_000,
            end: 5_000,
            text: "we should ship the feature",
            suppressed: true
        )
        let microphone = try utterance(
            id: "00000000-0000-0000-0000-000000000002",
            source: .microphone,
            start: 1_100,
            end: 4_900,
            text: "we should ship the feature"
        )

        let result = suppressor.suppressDuplicates(in: [system, microphone])

        #expect(result.utterances.count == 2)
        #expect(result.utterances.first { $0.id == system.id }?.suppressed == false)
        let auditedCopy = try #require(result.suppressedMicrophoneUtterances.first)
        #expect(auditedCopy.id == microphone.id)
        #expect(auditedCopy.text == microphone.text)
        #expect(result.visibleUtterances.map(\.id) == [system.id])
        #expect(result.visibleTalkTimeMilliseconds(for: .system) == 4_000)
        #expect(result.visibleTalkTimeMilliseconds(for: .microphone) == 0)
        #expect(result.matches == [EchoDuplicateMatch(
            microphoneUtteranceID: microphone.id,
            systemUtteranceID: system.id,
            overlapRatio: 1,
            tokenSimilarity: 1
        )])
    }

    @Test
    func normalizationUsesUnicodeCaseFoldAndRemovesPunctuationWithoutChangingText() throws {
        let original = "  Straße,\n‘LAUNCH’\tNOW!!!  "
        #expect(EchoDuplicateSuppressor.normalizedText(original) == "strasse launch now")
        #expect(EchoDuplicateSuppressor.normalizedTokens(in: original) == [
            "strasse", "launch", "now",
        ])

        let system = try utterance(
            source: .system,
            start: 2_000,
            end: 4_000,
            text: "STRASSE launch now"
        )
        let microphone = try utterance(
            source: .microphone,
            start: 2_100,
            end: 3_900,
            text: original
        )
        let result = suppressor.suppressDuplicates(in: [microphone, system])

        #expect(result.utterances.first { $0.id == microphone.id }?.suppressed == true)
        #expect(result.utterances.first { $0.id == microphone.id }?.text == original)
    }

    @Test
    func inclusiveSimilarityAndOverlapThresholdsSuppressPartialDuplicate() throws {
        let systemTokens = (1...20).map { "word\($0)" }
        var microphoneTokens = systemTokens
        microphoneTokens.replaceSubrange(17...19, with: ["change1", "change2", "change3"])
        let system = try utterance(
            source: .system,
            start: 1_000,
            end: 3_000,
            text: systemTokens.joined(separator: " ")
        )
        let microphone = try utterance(
            source: .microphone,
            start: 2_000,
            end: 4_000,
            text: microphoneTokens.joined(separator: " ")
        )

        let result = suppressor.suppressDuplicates(in: [microphone, system])
        let match = try #require(result.matches.first)

        #expect(result.utterances.first { $0.id == microphone.id }?.suppressed == true)
        #expect(match.overlapRatio == EchoDuplicateSuppressor.minimumOverlapRatio)
        #expect(match.tokenSimilarity == EchoDuplicateSuppressor.minimumTokenSimilarity)
    }

    @Test
    func valuesImmediatelyBelowSimilarityAndOverlapThresholdsStayVisible() throws {
        let systemTokens = (1...20).map { "word\($0)" }
        var belowSimilarityTokens = systemTokens
        belowSimilarityTokens.replaceSubrange(
            16...19,
            with: ["change1", "change2", "change3", "change4"]
        )
        let system = try utterance(
            source: .system,
            start: 1_000,
            end: 3_000,
            text: systemTokens.joined(separator: " ")
        )
        let belowSimilarity = try utterance(
            source: .microphone,
            start: 1_000,
            end: 3_000,
            text: belowSimilarityTokens.joined(separator: " ")
        )
        let belowOverlap = try utterance(
            source: .microphone,
            start: 2_001,
            end: 4_001,
            text: system.text
        )

        let result = suppressor.suppressDuplicates(
            in: [belowSimilarity, system, belowOverlap]
        )

        #expect(result.suppressedMicrophoneUtterances.isEmpty)
        #expect(result.matches.isEmpty)
    }

    @Test
    func microphoneLeadBoundaryIsInclusiveAndOneMillisecondEarlierIsRejected() throws {
        let system = try utterance(
            source: .system,
            start: 3_000,
            end: 10_000,
            text: "this phrase has four tokens"
        )
        let atBoundary = try utterance(
            source: .microphone,
            start: 1_500,
            end: 5_000,
            text: system.text
        )
        let tooEarly = try utterance(
            source: .microphone,
            start: 1_499,
            end: 5_000,
            text: system.text
        )

        let result = suppressor.suppressDuplicates(in: [tooEarly, system, atBoundary])

        #expect(result.utterances.first { $0.id == atBoundary.id }?.suppressed == true)
        #expect(result.utterances.first { $0.id == tooEarly.id }?.suppressed == false)
    }

    @Test
    func threeTokenBoundaryIsInclusiveAndShortAcknowledgementsStayVisible() throws {
        let threeTokenSystem = try utterance(
            source: .system,
            start: 1_000,
            end: 3_000,
            text: "yes ship now"
        )
        let threeTokenMicrophone = try utterance(
            source: .microphone,
            start: 1_100,
            end: 2_900,
            text: "yes ship now"
        )
        let shortSystem = try utterance(
            source: .system,
            start: 4_000,
            end: 5_000,
            text: "sounds good"
        )
        let shortMicrophone = try utterance(
            source: .microphone,
            start: 4_000,
            end: 5_000,
            text: "sounds good"
        )

        let result = suppressor.suppressDuplicates(in: [
            shortMicrophone, threeTokenSystem, shortSystem, threeTokenMicrophone,
        ])

        #expect(result.utterances.first { $0.id == threeTokenMicrophone.id }?.suppressed == true)
        #expect(result.utterances.first { $0.id == shortMicrophone.id }?.suppressed == false)
    }

    @Test
    func interruptionsUniqueSpeechAndSameSourceRepeatsStayVisible() throws {
        let system = try utterance(
            source: .system,
            start: 1_000,
            end: 5_000,
            text: "one two three four five six seven"
        )
        let interruption = try utterance(
            source: .microphone,
            start: 1_500,
            end: 4_500,
            text: "one two I disagree five six actually"
        )
        let unique = try utterance(
            source: .microphone,
            start: 2_000,
            end: 4_000,
            text: "please let me add context"
        )
        let repeatedMicrophoneText = "same source repeats remain visible"
        let repeatedMicrophones = [
            try utterance(
                source: .microphone,
                start: 6_000,
                end: 8_000,
                text: repeatedMicrophoneText
            ),
            try utterance(
                source: .microphone,
                start: 6_500,
                end: 8_500,
                text: repeatedMicrophoneText
            ),
        ]

        let result = suppressor.suppressDuplicates(
            in: [system, interruption, unique] + repeatedMicrophones
        )

        #expect(result.suppressedMicrophoneUtterances.isEmpty)
        #expect(result.visibleUtterances.count == 5)
    }

    @Test
    func zeroDurationCandidateDoesNotCreateArtificialOverlap() throws {
        let system = try utterance(
            source: .system,
            start: 1_000,
            end: 3_000,
            text: "three matching tokens"
        )
        let point = try utterance(
            source: .microphone,
            start: 2_000,
            end: 2_000,
            text: system.text
        )

        let result = suppressor.suppressDuplicates(in: [system, point])

        #expect(result.utterances.first { $0.id == point.id }?.suppressed == false)
    }

    @Test
    func manualUnsuppressPersistsAndPreventsResuppression() throws {
        let system = try utterance(
            source: .system,
            start: 1_000,
            end: 4_000,
            text: "keep this duplicate auditable"
        )
        let microphone = try utterance(
            source: .microphone,
            start: 1_100,
            end: 3_900,
            text: system.text
        )
        let automaticallyProcessed = suppressor.suppressDuplicates(in: [system, microphone])
        #expect(automaticallyProcessed.suppressedMicrophoneUtterances.map(\.id) == [microphone.id])

        var state = EchoDuplicateSuppressionState()
        let manuallyProcessed = suppressor.manuallyUnsuppress(
            utteranceID: microphone.id,
            in: automaticallyProcessed.utterances,
            state: &state
        )
        #expect(manuallyProcessed.utterances.first { $0.id == microphone.id }?.suppressed == false)
        #expect(state.preventsAutomaticSuppression(of: microphone.id))

        let persisted = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(
            EchoDuplicateSuppressionState.self,
            from: persisted
        )
        let reprocessed = suppressor.suppressDuplicates(
            in: automaticallyProcessed.utterances,
            state: restored
        )

        #expect(restored == state)
        #expect(reprocessed.utterances.first { $0.id == microphone.id }?.suppressed == false)
        #expect(reprocessed.matches.isEmpty)
        #expect(reprocessed.utterances.first { $0.id == microphone.id }?.text == microphone.text)
    }

    @Test
    func matchingSystemSelectionIsStableAcrossInputOrder() throws {
        let earlier = try utterance(
            id: "00000000-0000-0000-0000-000000000010",
            source: .system,
            start: 1_000,
            end: 5_000,
            text: "repeat the stable matching phrase"
        )
        let later = try utterance(
            id: "00000000-0000-0000-0000-000000000011",
            source: .system,
            start: 1_100,
            end: 5_100,
            text: earlier.text
        )
        let microphone = try utterance(
            source: .microphone,
            start: 1_200,
            end: 4_800,
            text: earlier.text
        )

        let forward = suppressor.suppressDuplicates(in: [earlier, later, microphone])
        let reversed = suppressor.suppressDuplicates(in: [microphone, later, earlier])

        #expect(forward.matches.first?.systemUtteranceID == earlier.id)
        #expect(reversed.matches.first?.systemUtteranceID == earlier.id)
    }

    private func utterance(
        id: String = UUID().uuidString,
        source: MeetingUtteranceSource,
        start: Int64,
        end: Int64,
        text: String,
        suppressed: Bool = false
    ) throws -> MeetingUtterance {
        try MeetingUtterance(
            id: #require(UUID(uuidString: id)),
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            text: text,
            baseSpeakerID: source == .microphone ? "you" : "remote",
            humanName: source == .microphone ? "You" : "Remote",
            suppressed: suppressed
        )
    }
}
