import Foundation

/// Immutable, engine-produced evidence for a meeting transcription attempt.
/// User edits belong in `transcript.json`; values in this document are never
/// rewritten after an attempt has been committed.
struct MeetingTranscriptArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var meetingID: UUID
    var attempts: [MeetingTranscriptAttempt]
    var selectedAttemptID: UUID?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        meetingID: UUID,
        attempts: [MeetingTranscriptAttempt] = [],
        selectedAttemptID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.attempts = attempts
        self.selectedAttemptID = selectedAttemptID
    }

    var selectedAttempt: MeetingTranscriptAttempt? {
        guard let selectedAttemptID else { return nil }
        return attempts.first { $0.id == selectedAttemptID }
    }
}

typealias MeetingTranscriptArtifacts = MeetingTranscriptArtifact

struct MeetingTranscriptAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var modelAttestation: MeetingTranscriptModelAttestation
    var spanOutcomes: [MeetingTranscriptSpanOutcome]
    var retainedPreviews: [MeetingUtterance]
    var utterances: [MeetingUtterance]
    var failures: [MeetingTranscriptFailureDiagnostic]
    var failureTotals: MeetingTranscriptFailureTotals
    var isSuccessful: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        modelAttestation: MeetingTranscriptModelAttestation,
        spanOutcomes: [MeetingTranscriptSpanOutcome] = [],
        retainedPreviews: [MeetingUtterance] = [],
        utterances: [MeetingUtterance] = [],
        failures: [MeetingTranscriptFailureDiagnostic] = [],
        failureTotals: MeetingTranscriptFailureTotals? = nil,
        isSuccessful: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modelAttestation = modelAttestation
        self.spanOutcomes = spanOutcomes
        self.retainedPreviews = retainedPreviews.sorted(by: MeetingUtterance.chronologicallyPrecedes)
        self.utterances = utterances.sorted(by: MeetingUtterance.chronologicallyPrecedes)
        self.failures = failures
        self.failureTotals = failureTotals ?? MeetingTranscriptFailureTotals(failures: failures)
        self.isSuccessful = isSuccessful
    }

    static func legacy(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance]
    ) -> MeetingTranscriptAttempt {
        MeetingTranscriptAttempt(
            id: meeting.id,
            createdAt: meeting.endedAt ?? meeting.startedAt,
            modelAttestation: .legacy(meeting: meeting),
            retainedPreviews: utterances,
            utterances: utterances,
            isSuccessful: meeting.transcriptionState == .completed
        )
    }
}

typealias RawTranscriptAttempt = MeetingTranscriptAttempt

struct MeetingTranscriptModelAttestation: Codable, Equatable, Sendable {
    var requestedSelection: SpeechEngineSelection
    var effectiveSelection: SpeechEngineSelection
    var verificationState: MeetingSpeechVerificationState
    var verifiedAt: Date?
    var voxTypeVersion: VoxTypeVersion?

    init(meeting: MeetingRecord) {
        requestedSelection = meeting.requestedSpeechSelection
        effectiveSelection = meeting.effectiveSpeechSelection
        verificationState = meeting.speechVerificationState
        verifiedAt = meeting.speechVerifiedAt
        voxTypeVersion = meeting.voxTypeVersion
    }

    static func legacy(meeting: MeetingRecord) -> Self {
        var value = Self(meeting: meeting)
        value.verificationState = .unverifiedLegacy
        value.verifiedAt = nil
        value.voxTypeVersion = nil
        return value
    }
}

struct MeetingTranscriptSpeechEvidence: Codable, Equatable, Sendable {
    var isSpeechBearing: Bool
    var frameCount: Int
    var maximumRMS: Float
    var estimatedNoiseFloor: Float
    var voicedMilliseconds: Double
    var voicedRatio: Double

    init(_ result: SpeechActivityGate.Result) {
        isSpeechBearing = result.isSpeechBearing
        frameCount = result.frameCount
        maximumRMS = result.maximumRMS
        estimatedNoiseFloor = result.estimatedNoiseFloor
        voicedMilliseconds = result.voicedMilliseconds
        voicedRatio = result.voicedRatio
    }
}

struct MeetingTranscriptSpanOutcome: Codable, Equatable, Sendable {
    var source: MeetingAudioSource
    var originalStartMilliseconds: Int64
    var originalEndMilliseconds: Int64
    var attemptedStartMilliseconds: Int64
    var attemptedEndMilliseconds: Int64
    var speechEvidence: MeetingTranscriptSpeechEvidence
    var requestCount: Int
    var text: String?
    var failure: String?
    var wasCancelled: Bool
    var attestedEngine: String
    var attestedModel: String?

    init(_ outcome: RawTranscriptionSpanOutcome) {
        source = outcome.source
        originalStartMilliseconds = outcome.originalStartMilliseconds
        originalEndMilliseconds = outcome.originalEndMilliseconds
        attemptedStartMilliseconds = outcome.attemptedStartMilliseconds
        attemptedEndMilliseconds = outcome.attemptedEndMilliseconds
        speechEvidence = MeetingTranscriptSpeechEvidence(outcome.speechEvidence)
        requestCount = outcome.requestCount
        text = outcome.text
        failure = outcome.failure
        wasCancelled = outcome.wasCancelled
        attestedEngine = outcome.attestedEngine
        attestedModel = outcome.attestedModel
    }
}

struct MeetingTranscriptFailureDiagnostic: Codable, Equatable, Sendable {
    var source: MeetingAudioSource
    var phase: LiveTranscriptionPhase
    var startMilliseconds: Int64?
    var endMilliseconds: Int64?
    var message: String
    var isSystemic: Bool

    init(_ failure: LiveTranscriptFailure) {
        source = failure.source
        phase = failure.phase
        startMilliseconds = failure.startMilliseconds
        endMilliseconds = failure.endMilliseconds
        message = String(failure.message.prefix(720))
        isSystemic = failure.isSystemic
    }

    init(message: String, isSystemic: Bool = true) {
        source = .microphone
        phase = .final
        startMilliseconds = nil
        endMilliseconds = nil
        self.message = String(message.prefix(720))
        self.isSystemic = isSystemic
    }
}

struct MeetingTranscriptFailureTotals: Codable, Equatable, Sendable {
    var total: Int
    var systemic: Int
    var preview: Int
    var final: Int

    init(total: Int = 0, systemic: Int = 0, preview: Int = 0, final: Int = 0) {
        self.total = total
        self.systemic = systemic
        self.preview = preview
        self.final = final
    }

    init(failures: [MeetingTranscriptFailureDiagnostic]) {
        total = failures.count
        systemic = failures.filter(\.isSystemic).count
        preview = failures.filter { $0.phase == .preview }.count
        final = failures.filter { $0.phase == .final }.count
    }
}
