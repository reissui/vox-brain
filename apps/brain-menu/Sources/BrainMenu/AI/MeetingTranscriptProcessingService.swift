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

private struct MeetingTranscriptProcessingKey: Hashable, Sendable {
    let meetingID: UUID
    let rawAttemptID: UUID
    let terminologyHash: String
}

/// Process-wide coordination is intentional: automatic analysis and a detail
/// view can construct separate service instances for the same persisted
/// meeting. They must still share correction work and agree which source key
/// is newest.
private actor MeetingTranscriptProcessingRegistry {
    private struct InFlight: Sendable {
        let token: UUID
        let task: Task<MeetingTranscriptProcessingRunResult, Never>
    }

    private var inFlight: [MeetingTranscriptProcessingKey: InFlight] = [:]
    private var latestKeyByMeeting: [UUID: MeetingTranscriptProcessingKey] = [:]

    func register(_ key: MeetingTranscriptProcessingKey) {
        latestKeyByMeeting[key.meetingID] = key
    }

    func run(
        key: MeetingTranscriptProcessingKey,
        operation: @escaping @Sendable () async -> MeetingTranscriptProcessingRunResult
    ) async -> MeetingTranscriptProcessingRunResult {
        register(key)
        if let existing = inFlight[key] {
            return await existing.task.value
        }
        let token = UUID()
        let task = Task { await operation() }
        inFlight[key] = InFlight(token: token, task: task)
        let result = await task.value
        if inFlight[key]?.token == token {
            inFlight[key] = nil
        }
        return result
    }

    func persistIfCurrent(
        _ transcript: MeetingProcessedTranscript,
        key: MeetingTranscriptProcessingKey,
        store: any MeetingProcessedTranscriptStoring
    ) throws -> Bool {
        guard latestKeyByMeeting[key.meetingID] == key else { return false }
        try store.replace(transcript, meetingID: key.meetingID)
        return true
    }
}

/// Builds a replaceable, evidence-traceable projection. The selected raw
/// attempt is read as a value and no dependency exposes a mutation API for it.
final class MeetingTranscriptProcessingService: Sendable {
    private static let registry = MeetingTranscriptProcessingRegistry()

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
        let key = MeetingTranscriptProcessingKey(
            meetingID: meeting.id,
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash
        )
        await Self.registry.register(key)
        let previous = try? store.load(
            meetingID: meeting.id,
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash
        )
        if let previous {
            return MeetingTranscriptProcessingRunResult(
                rawAttemptID: selectedAttempt.id,
                transcript: previous,
                failure: nil
            )
        }
        guard selectedAttempt.isSuccessful else {
            return failed(
                attemptID: selectedAttempt.id,
                previous: previous,
                failure: .selectedRawAttemptNotSuccessful
            )
        }
        guard !Task.isCancelled else {
            return failed(
                attemptID: selectedAttempt.id,
                previous: nil,
                failure: .cancelled
            )
        }
        let result = await Self.registry.run(key: key) { [self] in
            await performProcessing(
                meeting: meeting,
                selectedAttempt: selectedAttempt,
                speakerState: speakerState,
                notes: notes,
                terminology: terminology,
                terminologyHash: terminologyHash,
                key: key
            )
        }
        guard !Task.isCancelled else {
            return failed(
                attemptID: selectedAttempt.id,
                previous: nil,
                failure: .cancelled
            )
        }
        return result
    }

    private func performProcessing(
        meeting: MeetingRecord,
        selectedAttempt: MeetingTranscriptAttempt,
        speakerState: SpeakerEditingState,
        notes: String,
        terminology: [String],
        terminologyHash: String,
        key: MeetingTranscriptProcessingKey
    ) async -> MeetingTranscriptProcessingRunResult {
        if let current = try? store.load(
            meetingID: meeting.id,
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash
        ) {
            return MeetingTranscriptProcessingRunResult(
                rawAttemptID: selectedAttempt.id,
                transcript: current,
                failure: nil
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
                previous: nil,
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
                guard try await Self.registry.persistIfCurrent(
                    transcript,
                    key: key,
                    store: store
                ) else {
                    return failed(
                        attemptID: selectedAttempt.id,
                        previous: nil,
                        failure: .cancelled
                    )
                }
            } catch {
                return failed(
                    attemptID: selectedAttempt.id,
                    previous: nil,
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
                previous: nil,
                failure: .schemaFailure
            )
        } catch let error as AIProviderError {
            return failed(
                attemptID: selectedAttempt.id,
                previous: nil,
                failure: .providerFailure(error)
            )
        } catch is CancellationError {
            return failed(
                attemptID: selectedAttempt.id,
                previous: nil,
                failure: .cancelled
            )
        } catch {
            return failed(
                attemptID: selectedAttempt.id,
                previous: nil,
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
