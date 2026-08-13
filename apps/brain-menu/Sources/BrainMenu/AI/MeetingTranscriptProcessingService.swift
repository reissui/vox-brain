import Foundation

enum MeetingTranscriptProcessingFailure: Equatable, Sendable {
    case noSelectedRawAttempt
    case selectedRawAttemptNotSuccessful
    case providerNotReady(AIConnectionState)
    case providerFailure(AIProviderError)
    case cancelled
    case schemaFailure
    case persistenceFailure
}

struct MeetingTranscriptProcessingRunResult: Equatable, Sendable {
    let rawAttemptID: UUID?
    let transcript: MeetingProcessedTranscript?
    let failure: MeetingTranscriptProcessingFailure?

    var isRetryable: Bool { failure != nil }
}

/// Builds a replaceable, evidence-traceable projection. The selected raw
/// attempt is read as a value and no dependency exposes a mutation API for it.
final class MeetingTranscriptProcessingService: Sendable {
    private let provider: any AIProviding
    private let store: any MeetingProcessedTranscriptStoring

    init(
        provider: any AIProviding,
        store: any MeetingProcessedTranscriptStoring = MeetingProcessedTranscriptStore()
    ) {
        self.provider = provider
        self.store = store
    }

    func process(
        meeting: MeetingRecord,
        artifact: MeetingTranscriptArtifact,
        speakerState: SpeakerEditingState = SpeakerEditingState(),
        notes: String = "",
        terminology: [String],
        terminologyHash: String
    ) async -> MeetingTranscriptProcessingRunResult {
        guard artifact.meetingID == meeting.id,
              let selectedID = artifact.selectedAttemptID,
              let selected = artifact.attempts.first(where: { $0.id == selectedID }) else {
            return MeetingTranscriptProcessingRunResult(
                rawAttemptID: artifact.selectedAttemptID,
                transcript: nil,
                failure: .noSelectedRawAttempt
            )
        }
        return await process(
            meeting: meeting,
            selectedAttempt: selected,
            speakerState: speakerState,
            notes: notes,
            terminology: terminology,
            terminologyHash: terminologyHash
        )
    }

    func process(
        meeting: MeetingRecord,
        selectedAttempt: MeetingTranscriptAttempt,
        speakerState: SpeakerEditingState = SpeakerEditingState(),
        notes: String = "",
        terminology: [String],
        terminologyHash: String
    ) async -> MeetingTranscriptProcessingRunResult {
        let previous = try? store.load(
            meetingID: meeting.id,
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash
        )
        guard selectedAttempt.isSuccessful else {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .selectedRawAttemptNotSuccessful
            )
        }
        let reconciled = SpeakerEditor(
            utterances: selectedAttempt.utterances,
            state: speakerState
        ).state
        let assembledTurns = MeetingTranscriptTurnAssembler.assemble(
            utterances: selectedAttempt.utterances,
            assignments: reconciled.assignments,
            speakers: reconciled.speakers
        )
        let readiness = await provider.testConnection()
        guard readiness == .ready else {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .providerNotReady(readiness)
            )
        }
        let prompt = MeetingTranscriptProcessingPrompt.make(
            meeting: meeting,
            selectedAttempt: selectedAttempt,
            assembledTurns: assembledTurns,
            notes: notes,
            terminology: terminology,
            terminologyHash: terminologyHash
        )
        do {
            let data = try await provider.run(
                prompt: prompt,
                jsonSchema: MeetingTranscriptProcessingSchema.jsonSchema
            )
            let transcript = try MeetingTranscriptProcessingSchema.decode(
                data,
                attempt: selectedAttempt,
                assembledTurns: assembledTurns,
                terminologyHash: terminologyHash,
                terminology: terminology
            )
            do {
                try store.replace(transcript, meetingID: meeting.id)
            } catch {
                return failed(
                    attemptID: selectedAttempt.id,
                    previous: previous,
                    failure: .persistenceFailure
                )
            }
            return MeetingTranscriptProcessingRunResult(
                rawAttemptID: selectedAttempt.id,
                transcript: transcript,
                failure: nil
            )
        } catch AIProviderError.schemaFailure {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .schemaFailure
            )
        } catch let error as AIProviderError {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .providerFailure(error)
            )
        } catch is CancellationError {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .cancelled
            )
        } catch {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .schemaFailure
            )
        }
    }

    func storedTranscript(
        meetingID: UUID,
        rawAttemptID: UUID,
        terminologyHash: String
    ) throws -> MeetingProcessedTranscript? {
        try store.load(
            meetingID: meetingID,
            rawAttemptID: rawAttemptID,
            terminologyHash: terminologyHash
        )
    }

    private func failed(
        attemptID: UUID,
        previous: MeetingProcessedTranscript?,
        failure: MeetingTranscriptProcessingFailure
    ) -> MeetingTranscriptProcessingRunResult {
        MeetingTranscriptProcessingRunResult(
            rawAttemptID: attemptID,
            transcript: previous,
            failure: failure
        )
    }
}
