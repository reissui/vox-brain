import Foundation

enum MeetingLifecycleState: String, Codable, CaseIterable, Sendable {
    case idle
    case startSuggested
    case starting
    case sourceSelectionRequired
    case recording
    case paused
    case stopSuggested
    case finalizing
    case completed
    case failed
}

enum MeetingAnalysisState: String, Codable, CaseIterable, Sendable {
    case notRequested
    case running
    case completed
    case failed
}

enum MeetingTranscriptionState: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

enum MeetingUploadState: String, Codable, CaseIterable, Sendable {
    case notUploaded
    case queued
    case delivering
    case delivered
    case failed
}

enum MeetingTitleSource: String, Codable, CaseIterable, Sendable {
    case application
    case transcript
    case analysis
    case manual
}

enum MeetingRecordingKind: String, Codable, CaseIterable, Sendable {
    case meeting
    case voiceNote
}

enum MeetingAudioRetentionState: String, Codable, CaseIterable, Sendable {
    case pending
    case retained
    case deleted
    /// Records written before retention intent was persisted can be
    /// indistinguishable from either an interrupted archive or an explicit
    /// deletion. Preserve their source files without guessing either outcome.
    case unresolvedLegacy
}

enum MeetingSpeechVerificationState: String, Codable, Equatable, Sendable {
    case verified
    case unverifiedLegacy
}

struct RetainedAudioMetadata: Codable, Equatable, Sendable {
    var filename: String
    var format: String
    var sizeBytes: Int64
    var durationMilliseconds: Int64
    var channelCount: Int

    init(
        filename: String,
        format: String,
        sizeBytes: Int64,
        durationMilliseconds: Int64,
        channelCount: Int = 2
    ) {
        self.filename = filename
        self.format = format
        self.sizeBytes = sizeBytes
        self.durationMilliseconds = durationMilliseconds
        self.channelCount = channelCount
    }
}

struct MeetingRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var recordingKind: MeetingRecordingKind
    var recordingKindNeedsReview: Bool
    var titleSource: MeetingTitleSource
    var detectedApplication: String?
    var startedAt: Date
    var endedAt: Date?
    var lifecycleState: MeetingLifecycleState
    var speechEngine: String
    var speechModel: String
    var requestedSpeechSelection: SpeechEngineSelection
    var effectiveSpeechSelection: SpeechEngineSelection
    var speechVerificationState: MeetingSpeechVerificationState
    var speechVerifiedAt: Date?
    var voxTypeVersion: VoxTypeVersion?
    var transcriptionState: MeetingTranscriptionState
    var transcriptionAttemptCount: Int
    var transcriptionErrorMessage: String?
    var analysisState: MeetingAnalysisState
    var uploadState: MeetingUploadState
    var retainedAudio: RetainedAudioMetadata?
    var audioRetentionState: MeetingAudioRetentionState
    var isUnread: Bool

    var isVoiceNote: Bool {
        recordingKind == .voiceNote
    }

    var acceptsAutomaticAnalysisTitle: Bool {
        guard titleSource == .manual else { return true }
        guard isVoiceNote else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Voice note") == .orderedSame
    }

    init(
        id: UUID = UUID(),
        title: String,
        recordingKind: MeetingRecordingKind = .meeting,
        recordingKindNeedsReview: Bool = false,
        titleSource: MeetingTitleSource? = nil,
        detectedApplication: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        lifecycleState: MeetingLifecycleState,
        speechEngine: String,
        speechModel: String,
        speechModelAttestation: VoxTypeModelAttestation? = nil,
        transcriptionState: MeetingTranscriptionState? = nil,
        transcriptionAttemptCount: Int = 0,
        transcriptionErrorMessage: String? = nil,
        analysisState: MeetingAnalysisState = .notRequested,
        uploadState: MeetingUploadState = .notUploaded,
        retainedAudio: RetainedAudioMetadata? = nil,
        audioRetentionState: MeetingAudioRetentionState? = nil,
        isUnread: Bool = true
    ) {
        self.id = id
        self.title = title
        self.recordingKind = recordingKind
        self.recordingKindNeedsReview = recordingKindNeedsReview
        self.titleSource = titleSource ?? Self.inferredTitleSource(for: title)
        self.detectedApplication = detectedApplication
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lifecycleState = lifecycleState
        self.speechEngine = speechEngine
        self.speechModel = speechModel
        let legacySelection = SpeechEngineSelection(
            engine: SpeechEngineID(rawValue: speechEngine) ?? .whisper,
            modelID: speechModel
        )
        requestedSpeechSelection = speechModelAttestation?.requestedSelection ?? legacySelection
        effectiveSpeechSelection = speechModelAttestation?.effectiveSelection ?? legacySelection
        speechVerificationState = speechModelAttestation == nil ? .unverifiedLegacy : .verified
        speechVerifiedAt = speechModelAttestation?.verifiedAt
        voxTypeVersion = speechModelAttestation?.voxTypeVersion
        self.transcriptionState = transcriptionState
            ?? (lifecycleState == .completed ? .completed : .pending)
        self.transcriptionAttemptCount = max(0, transcriptionAttemptCount)
        self.transcriptionErrorMessage = transcriptionErrorMessage
        self.analysisState = analysisState
        self.uploadState = uploadState
        self.retainedAudio = retainedAudio
        self.audioRetentionState = audioRetentionState
            ?? (retainedAudio == nil ? .pending : .retained)
        self.isUnread = isUnread
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case recordingKind
        case recordingKindNeedsReview
        case titleSource
        case detectedApplication
        case startedAt
        case endedAt
        case lifecycleState
        case speechEngine
        case speechModel
        case requestedSpeechSelection
        case effectiveSpeechSelection
        case speechVerificationState
        case speechVerifiedAt
        case voxTypeVersion
        case transcriptionState
        case transcriptionAttemptCount
        case transcriptionErrorMessage
        case analysisState
        case uploadState
        case retainedAudio
        case audioRetentionState
        case isUnread
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let titleSource = try container.decodeIfPresent(MeetingTitleSource.self, forKey: .titleSource)
            ?? Self.inferredTitleSource(for: title)
        let detectedApplication = try container.decodeIfPresent(
            String.self,
            forKey: .detectedApplication
        )
        let persistedRecordingKind = try container.decodeIfPresent(
            MeetingRecordingKind.self,
            forKey: .recordingKind
        )
        let lifecycleState = try container.decode(
            MeetingLifecycleState.self,
            forKey: .lifecycleState
        )
        let transcriptionState = try container.decodeIfPresent(
            MeetingTranscriptionState.self,
            forKey: .transcriptionState
        ) ?? (lifecycleState == .completed ? .completed : .pending)
        let retainedAudio = try container.decodeIfPresent(
            RetainedAudioMetadata.self,
            forKey: .retainedAudio
        )
        let audioRetentionState = try container.decodeIfPresent(
            MeetingAudioRetentionState.self,
            forKey: .audioRetentionState
        ) ?? Self.legacyAudioRetentionState(
            lifecycleState: lifecycleState,
            transcriptionState: transcriptionState,
            retainedAudio: retainedAudio
        )
        let legacyMigration = Self.legacyRecordingKindMigration(
            title: title,
            titleSource: titleSource,
            detectedApplication: detectedApplication
        )
        let legacyEngine = try container.decode(String.self, forKey: .speechEngine)
        let legacyModel = try container.decode(String.self, forKey: .speechModel)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: title,
            recordingKind: persistedRecordingKind ?? legacyMigration.kind,
            recordingKindNeedsReview: try container.decodeIfPresent(
                Bool.self,
                forKey: .recordingKindNeedsReview
            ) ?? (persistedRecordingKind == nil && legacyMigration.needsReview),
            titleSource: titleSource,
            detectedApplication: detectedApplication,
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
            lifecycleState: lifecycleState,
            speechEngine: legacyEngine,
            speechModel: legacyModel,
            transcriptionState: transcriptionState,
            transcriptionAttemptCount: try container.decodeIfPresent(
                Int.self,
                forKey: .transcriptionAttemptCount
            ) ?? 0,
            transcriptionErrorMessage: try container.decodeIfPresent(
                String.self,
                forKey: .transcriptionErrorMessage
            ),
            analysisState: try container.decode(MeetingAnalysisState.self, forKey: .analysisState),
            uploadState: try container.decode(MeetingUploadState.self, forKey: .uploadState),
            retainedAudio: retainedAudio,
            audioRetentionState: audioRetentionState,
            // Records written before unread tracking existed are treated as
            // already seen. Only newly completed recordings receive the New state.
            isUnread: try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        )
        requestedSpeechSelection = try container.decodeIfPresent(
            SpeechEngineSelection.self,
            forKey: .requestedSpeechSelection
        ) ?? SpeechEngineSelection(
            engine: SpeechEngineID(rawValue: legacyEngine) ?? .whisper,
            modelID: legacyModel
        )
        effectiveSpeechSelection = try container.decodeIfPresent(
            SpeechEngineSelection.self,
            forKey: .effectiveSpeechSelection
        ) ?? requestedSpeechSelection
        speechVerificationState = try container.decodeIfPresent(
            MeetingSpeechVerificationState.self,
            forKey: .speechVerificationState
        ) ?? .unverifiedLegacy
        speechVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .speechVerifiedAt)
        voxTypeVersion = try container.decodeIfPresent(VoxTypeVersion.self, forKey: .voxTypeVersion)
    }

    private static func inferredTitleSource(for title: String) -> MeetingTitleSource {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "meeting" || normalized.hasPrefix("meeting in ")
            ? .application
            : .manual
    }

    private static func legacyAudioRetentionState(
        lifecycleState: MeetingLifecycleState,
        transcriptionState: MeetingTranscriptionState,
        retainedAudio: RetainedAudioMetadata?
    ) -> MeetingAudioRetentionState {
        if retainedAudio != nil {
            return .retained
        }
        if lifecycleState == .completed, transcriptionState == .completed {
            return .unresolvedLegacy
        }
        return .pending
    }

    private static func legacyRecordingKindMigration(
        title: String,
        titleSource: MeetingTitleSource,
        detectedApplication: String?
    ) -> (kind: MeetingRecordingKind, needsReview: Bool) {
        guard titleSource == .manual, detectedApplication == nil else {
            return (.meeting, false)
        }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("Voice note") == .orderedSame {
            return (.voiceNote, false)
        }

        // Before recordingKind existed, a manually started meeting and a
        // renamed voice note had identical metadata. Keep ambiguous records in
        // Meetings and surface an explicit section choice instead of guessing.
        return (.meeting, true)
    }
}

enum MeetingUtteranceSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
}

enum MeetingAudioReceptionState: Equatable, Sendable {
    case waiting
    case microphone
    case system
    case microphoneAndSystem

    init(receivedSources: some Sequence<MeetingUtteranceSource>) {
        let sources = Set(receivedSources)
        self = switch (sources.contains(.microphone), sources.contains(.system)) {
        case (true, true): .microphoneAndSystem
        case (true, false): .microphone
        case (false, true): .system
        case (false, false): .waiting
        }
    }

    var isReceiving: Bool { self != .waiting }

    var statusText: String {
        switch self {
        case .waiting: "Waiting for audio."
        case .microphone: "Receiving microphone audio."
        case .system: "Receiving system audio."
        case .microphoneAndSystem: "Receiving microphone and system audio."
        }
    }

    var compactStatusText: String {
        switch self {
        case .waiting: "Waiting for audio…"
        case .microphone: "Receiving microphone audio…"
        case .system: "Receiving system audio…"
        case .microphoneAndSystem: "Receiving microphone and system audio…"
        }
    }
}

enum MeetingModelError: Error, Equatable, LocalizedError, Sendable {
    case invalidUtteranceTime(id: UUID, startMilliseconds: Int64, endMilliseconds: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidUtteranceTime:
            "An utterance must have non-negative timestamps with its end at or after its start."
        }
    }
}

struct MeetingUtterance: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: MeetingUtteranceSource
    var startMilliseconds: Int64
    var endMilliseconds: Int64
    var text: String
    var baseSpeakerID: String
    var humanName: String?
    var suppressed: Bool
    var transcriptionPhase: LiveTranscriptionPhase?

    var isSuppressed: Bool {
        get { suppressed }
        set { suppressed = newValue }
    }

    init(
        id: UUID = UUID(),
        source: MeetingUtteranceSource,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String,
        baseSpeakerID: String,
        humanName: String? = nil,
        suppressed: Bool = false,
        transcriptionPhase: LiveTranscriptionPhase? = nil
    ) throws {
        guard startMilliseconds >= 0, endMilliseconds >= startMilliseconds else {
            throw MeetingModelError.invalidUtteranceTime(
                id: id,
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
        }

        self.id = id
        self.source = source
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.baseSpeakerID = baseSpeakerID
        self.humanName = humanName
        self.suppressed = suppressed
        self.transcriptionPhase = transcriptionPhase
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case startMilliseconds
        case endMilliseconds
        case text
        case baseSpeakerID
        case humanName
        case suppressed
        case transcriptionPhase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            source: container.decode(MeetingUtteranceSource.self, forKey: .source),
            startMilliseconds: container.decode(Int64.self, forKey: .startMilliseconds),
            endMilliseconds: container.decode(Int64.self, forKey: .endMilliseconds),
            text: container.decode(String.self, forKey: .text),
            baseSpeakerID: container.decode(String.self, forKey: .baseSpeakerID),
            humanName: container.decodeIfPresent(String.self, forKey: .humanName),
            suppressed: container.decode(Bool.self, forKey: .suppressed),
            transcriptionPhase: container.decodeIfPresent(
                LiveTranscriptionPhase.self,
                forKey: .transcriptionPhase
            )
        )
    }
}

extension MeetingUtterance {
    static func chronologicallyPrecedes(
        _ lhs: MeetingUtterance,
        _ rhs: MeetingUtterance
    ) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

typealias RetainedMeetingAudio = RetainedAudioMetadata

struct StoredMeeting: Equatable, Sendable {
    var meeting: MeetingRecord
    var utterances: [MeetingUtterance]
}
