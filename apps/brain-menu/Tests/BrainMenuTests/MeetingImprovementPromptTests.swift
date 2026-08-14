import Foundation
import Testing
@testable import BrainMenu

struct MeetingImprovementPromptTests {
    @Test
    func promptIsDeterministicBoundedAndContainsOnlyQualityDiagnostics() throws {
        let rawID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let utteranceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let correctionID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let meeting = MeetingRecord(
            title: "SECRET MEETING TITLE",
            startedAt: Date(timeIntervalSince1970: 100),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "large-v3"
        )
        let utterance = try MeetingUtterance(
            id: utteranceID,
            source: .microphone,
            startMilliseconds: 9_000,
            endMilliseconds: 12_000,
            text: "SECRET TRANSCRIPT BODY",
            baseSpeakerID: "SECRET PARTICIPANT"
        )
        var failures: [MeetingTranscriptFailureDiagnostic] = []
        for index in 0..<40 {
            let failure = LiveTranscriptFailure(
                source: index.isMultiple(of: 2) ? .microphone : .system,
                phase: .final,
                startMilliseconds: Int64(index * 1_000),
                endMilliseconds: Int64(index * 1_000 + 500),
                message: "timeout diagnostic \(index) " + String(repeating: "x", count: 300),
                isSystemic: index.isMultiple(of: 3)
            )
            failures.append(MeetingTranscriptFailureDiagnostic(failure))
        }
        let attempt = MeetingTranscriptAttempt(
            id: rawID,
            createdAt: Date(timeIntervalSince1970: 200),
            modelAttestation: MeetingTranscriptModelAttestation(meeting: meeting),
            spanOutcomes: [MeetingTranscriptSpanOutcome(RawTranscriptionSpanOutcome(
                source: .microphone,
                originalStartMilliseconds: 8_000,
                originalEndMilliseconds: 13_000,
                attemptedStartMilliseconds: 7_500,
                attemptedEndMilliseconds: 13_500,
                speechEvidence: SpeechActivityGate.Result(
                    isSpeechBearing: true,
                    frameCount: 20,
                    maximumRMS: 0.2,
                    estimatedNoiseFloor: 0.003,
                    voicedMilliseconds: 500,
                    voicedRatio: 0.5
                ),
                requestCount: 2,
                text: "SECRET FINAL SPAN",
                failure: nil,
                wasCancelled: false,
                attestedEngine: "whisper",
                attestedModel: "large-v3"
            ))],
            retainedPreviews: [utterance],
            utterances: [utterance],
            failures: failures,
            isSuccessful: true
        )
        let processed = MeetingProcessedTranscript(
            rawAttemptID: rawID,
            terminologyHash: "SECRET GLOSSARY HASH",
            turns: [],
            bullets: ["SECRET SUMMARY"],
            corrections: [MeetingTranscriptCorrection(
                id: correctionID,
                utteranceIDs: [utteranceID],
                kind: .terminology,
                before: "SECRET BEFORE",
                after: "SECRET AFTER",
                reason: "SECRET REASON",
                confidence: 1
            )]
        )

        let first = MeetingImprovementPrompt.make(
            meeting: meeting,
            attempt: attempt,
            processedTranscript: processed
        )
        let second = MeetingImprovementPrompt.make(
            meeting: meeting,
            attempt: attempt,
            processedTranscript: processed
        )

        #expect(first == second)
        #expect(first.count <= MeetingImprovementPrompt.maximumCharacters)
        #expect(first.contains("40 final audio spans"))
        #expect(first.contains("00:00-00:00"))
        #expect(first.contains("timeout=40"))
        #expect(first.contains("requested whisper/large-v3"))
        #expect(first.contains("Existing processing recorded 1 corrections (terminology=1)"))
        #expect(first.localizedCaseInsensitiveContains("retained audio"))
        #expect(!first.contains("Concrete checks:"))
        #expect(!first.contains("SECRET MEETING TITLE"))
        #expect(!first.contains("SECRET TRANSCRIPT BODY"))
        #expect(!first.contains("SECRET FINAL SPAN"))
        #expect(!first.contains("SECRET PARTICIPANT"))
        #expect(!first.contains("SECRET SUMMARY"))
        #expect(!first.contains("SECRET GLOSSARY HASH"))
        #expect(!first.contains("SECRET BEFORE"))
        #expect(!first.contains("timeout diagnostic"))
    }

    @Test
    func mismatchedOrLegacyModelIdentityIsNeverClaimedVerified() {
        var meeting = MeetingRecord(
            title: "Meeting",
            startedAt: .now,
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "large-v3"
        )
        meeting.requestedSpeechSelection = SpeechEngineSelection(
            engine: .whisper,
            modelID: "large-v3"
        )
        meeting.effectiveSpeechSelection = SpeechEngineSelection(
            engine: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )
        meeting.speechVerificationState = .verified
        let mismatch = MeetingTranscriptAttempt(
            modelAttestation: MeetingTranscriptModelAttestation(meeting: meeting),
            isSuccessful: true
        )
        let legacy = MeetingTranscriptAttempt.legacy(meeting: meeting, utterances: [])

        #expect(MeetingImprovementPrompt.make(
            attempt: mismatch,
            processedTranscript: nil
        ).contains("Model identity is unverified"))
        #expect(MeetingImprovementPrompt.make(
            attempt: legacy,
            processedTranscript: nil
        ).contains("Model identity is unverified"))
    }

    @Test
    func promptBrieflyTargetsDetectedCallSpecificProblems() throws {
        let meeting = MeetingRecord(
            title: "Private title",
            startedAt: .now,
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "large-v3"
        )
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 2_000,
            text: "Um, hello, hello, hello. Uh, ship it.",
            baseSpeakerID: "you"
        )
        let attempt = MeetingTranscriptAttempt(
            modelAttestation: MeetingTranscriptModelAttestation(meeting: meeting),
            retainedPreviews: [utterance],
            utterances: [utterance],
            failures: [MeetingTranscriptFailureDiagnostic(LiveTranscriptFailure(
                source: .microphone,
                phase: .final,
                startMilliseconds: 5_000,
                endMilliseconds: 6_000,
                message: "timed out"
            ))],
            isSuccessful: true
        )

        let prompt = MeetingImprovementPrompt.make(
            attempt: attempt,
            processedTranscript: nil
        )

        #expect(prompt.count < 1_500)
        #expect(prompt.contains("2 filler"))
        #expect(prompt.contains("1 repeated-word"))
        #expect(prompt.contains("00:05-00:06"))
        #expect(prompt.localizedCaseInsensitiveContains("timeout"))
        #expect(prompt.localizedCaseInsensitiveContains("compare"))
        #expect(!prompt.contains("Private title"))
        #expect(!prompt.contains("ship it"))
    }
}
