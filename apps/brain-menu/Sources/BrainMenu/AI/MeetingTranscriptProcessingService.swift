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
    private static let maximumChunkUtteranceCount = 200
    private static let maximumChunkTextCharacterCount = 12_000

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
        let localCandidate = MeetingTranscriptCleanup.makeTranscript(
            attempt: selectedAttempt,
            turns: assembledTurns,
            terminologyHash: terminologyHash
        )
        let localTranscript = Self.validatedCombinedTranscript(
            [localCandidate],
            selectedAttempt: selectedAttempt,
            assembledTurns: assembledTurns,
            terminology: terminology,
            terminologyHash: terminologyHash
        )
        let readiness = await provider.testConnection()
        guard readiness == .ready else {
            return await persist(
                localTranscript,
                attemptID: selectedAttempt.id,
                key: key
            )
        }
        var processedChunks: [MeetingProcessedTranscript] = []
        var providerFailed = false
        for turns in Self.chunked(assembledTurns) {
            guard !Task.isCancelled else {
                return failed(
                    attemptID: selectedAttempt.id,
                    previous: nil,
                    failure: .cancelled
                )
            }
            let chunkAttempt = Self.chunkAttempt(
                selectedAttempt,
                containing: turns
            )
            if providerFailed {
                processedChunks.append(MeetingTranscriptCleanup.makeTranscript(
                    attempt: chunkAttempt,
                    turns: turns,
                    terminologyHash: terminologyHash
                ))
                continue
            }
            let prompt = MeetingTranscriptProcessingPrompt.make(
                meeting: meeting,
                selectedAttempt: chunkAttempt,
                assembledTurns: turns,
                notes: notes,
                terminology: terminology,
                terminologyHash: terminologyHash
            )
            do {
                let data = try await provider.run(
                    prompt: prompt,
                    jsonSchema: MeetingTranscriptProcessingSchema.jsonSchema
                )
                processedChunks.append(try MeetingTranscriptProcessingSchema.decode(
                    data,
                    attempt: chunkAttempt,
                    assembledTurns: turns,
                    terminologyHash: terminologyHash,
                    terminology: terminology
                ))
            } catch AIProviderError.schemaFailure {
                processedChunks.append(MeetingTranscriptCleanup.makeTranscript(
                    attempt: chunkAttempt,
                    turns: turns,
                    terminologyHash: terminologyHash
                ))
            } catch is AIProviderError {
                providerFailed = true
                processedChunks.append(MeetingTranscriptCleanup.makeTranscript(
                    attempt: chunkAttempt,
                    turns: turns,
                    terminologyHash: terminologyHash
                ))
            } catch is CancellationError {
                return failed(
                    attemptID: selectedAttempt.id,
                    previous: nil,
                    failure: .cancelled
                )
            } catch {
                // Reject the model's unsafe projection, but keep this bounded
                // section readable by projecting the immutable raw turns.
                processedChunks.append(MeetingTranscriptCleanup.makeTranscript(
                    attempt: chunkAttempt,
                    turns: turns,
                    terminologyHash: terminologyHash
                ))
            }
        }

        let transcript = Self.validatedCombinedTranscript(
            processedChunks,
            selectedAttempt: selectedAttempt,
            assembledTurns: assembledTurns,
            terminology: terminology,
            terminologyHash: terminologyHash
        )
        return await persist(transcript, attemptID: selectedAttempt.id, key: key)
    }

    private func persist(
        _ transcript: MeetingProcessedTranscript,
        attemptID: UUID,
        key: MeetingTranscriptProcessingKey
    ) async -> MeetingTranscriptProcessingRunResult {
        do {
            guard try await Self.registry.persistIfCurrent(
                transcript,
                key: key,
                store: store
            ) else {
                return failed(
                    attemptID: attemptID,
                    previous: nil,
                    failure: .cancelled
                )
            }
        } catch {
            return failed(
                attemptID: attemptID,
                previous: nil,
                failure: .persistenceFailure
            )
        }
        return MeetingTranscriptProcessingRunResult(
            rawAttemptID: attemptID,
            transcript: transcript,
            failure: nil
        )
    }

    private static func chunked(
        _ turns: [MeetingTranscriptTurn]
    ) -> [[MeetingTranscriptTurn]] {
        guard !turns.isEmpty else { return [[]] }
        var chunks: [[MeetingTranscriptTurn]] = []
        var current: [MeetingTranscriptTurn] = []
        var utteranceCount = 0
        var textCharacterCount = 0

        for turn in turns {
            let nextUtteranceCount = utteranceCount + turn.utteranceIDs.count
            let nextTextCharacterCount = textCharacterCount + turn.text.count
            if !current.isEmpty,
               nextUtteranceCount > maximumChunkUtteranceCount
                || nextTextCharacterCount > maximumChunkTextCharacterCount {
                chunks.append(current)
                current = []
                utteranceCount = 0
                textCharacterCount = 0
            }
            current.append(turn)
            utteranceCount += turn.utteranceIDs.count
            textCharacterCount += turn.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func chunkAttempt(
        _ attempt: MeetingTranscriptAttempt,
        containing turns: [MeetingTranscriptTurn]
    ) -> MeetingTranscriptAttempt {
        let ids = Set(turns.flatMap(\.utteranceIDs))
        let utterances = attempt.utterances.filter { ids.contains($0.id) }
        let start = utterances.map(\.startMilliseconds).min()
        let end = utterances.map(\.endMilliseconds).max()
        let spanOutcomes = attempt.spanOutcomes.filter { span in
            guard let start, let end else { return false }
            return span.attemptedStartMilliseconds < end
                && span.attemptedEndMilliseconds > start
        }
        return MeetingTranscriptAttempt(
            id: attempt.id,
            createdAt: attempt.createdAt,
            modelAttestation: attempt.modelAttestation,
            spanOutcomes: spanOutcomes,
            retainedPreviews: attempt.retainedPreviews.filter { preview in
                guard let start, let end else { return false }
                return preview.startMilliseconds < end
                    && preview.endMilliseconds > start
            },
            utterances: utterances,
            isSuccessful: true
        )
    }

    private static func losslessTranscript(
        rawAttemptID: UUID,
        terminologyHash: String,
        turns: [MeetingTranscriptTurn]
    ) -> MeetingProcessedTranscript {
        MeetingProcessedTranscript(
            rawAttemptID: rawAttemptID,
            terminologyHash: terminologyHash,
            turns: turns.map { turn in
                MeetingProcessedTranscriptTurn(
                    id: turn.id,
                    utteranceIDs: turn.utteranceIDs,
                    startMilliseconds: turn.startMilliseconds,
                    endMilliseconds: turn.endMilliseconds,
                    speakerID: turn.speakerID,
                    speakerLabel: turn.speakerLabel,
                    text: turn.text,
                    unclear: turn.text.localizedCaseInsensitiveContains("[unclear]")
                )
            },
            bullets: [],
            corrections: []
        )
    }

    private static func validatedCombinedTranscript(
        _ chunks: [MeetingProcessedTranscript],
        selectedAttempt: MeetingTranscriptAttempt,
        assembledTurns: [MeetingTranscriptTurn],
        terminology: [String],
        terminologyHash: String
    ) -> MeetingProcessedTranscript {
        let candidate = MeetingProcessedTranscript(
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash,
            turns: chunks.flatMap(\.turns),
            bullets: combinedBullets(chunks),
            corrections: chunks.flatMap(\.corrections)
        )
        if let data = try? JSONEncoder().encode(candidate),
           let validated = try? MeetingTranscriptProcessingSchema.decode(
               data,
               attempt: selectedAttempt,
               assembledTurns: assembledTurns,
               terminologyHash: terminologyHash,
               terminology: terminology
           ) {
            return validated
        }
        return losslessTranscript(
            rawAttemptID: selectedAttempt.id,
            terminologyHash: terminologyHash,
            turns: assembledTurns
        )
    }

    private static func combinedBullets(
        _ chunks: [MeetingProcessedTranscript]
    ) -> [String] {
        var result: [String] = []
        var index = 0
        while result.count < MeetingTranscriptProcessingSchema.maximumBullets {
            var appended = false
            for chunk in chunks where chunk.bullets.indices.contains(index) {
                result.append(chunk.bullets[index])
                appended = true
                if result.count == MeetingTranscriptProcessingSchema.maximumBullets {
                    return result
                }
            }
            guard appended else { break }
            index += 1
        }
        return result
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
