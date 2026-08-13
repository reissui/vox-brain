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
        #expect(first.contains("Requested speech model: whisper/large-v3"))
        #expect(first.contains("Raw utterances: 1"))
        #expect(first.contains("Attempt window span: 00:08-00:13 (5000 ms)"))
        #expect(first.contains("Final window duration: 5000 ms"))
        #expect(first.contains("Corrections: 1 total"))
        #expect(first.contains("00:00-00:00") || first.contains("timestamp unavailable"))
        #expect(first.contains("Concrete checks:"))
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
        ).contains("Model verification: unverified"))
        #expect(MeetingImprovementPrompt.make(
            attempt: legacy,
            processedTranscript: nil
        ).contains("Model verification: unverified"))
    }
}
