import Darwin
import Foundation

struct StoredMeetingAnalysis: Codable, Equatable, Sendable {
    var analysis: MeetingAnalysis
    var speakerState: SpeakerEditingState
}

protocol MeetingAnalysisStoring: Sendable {
    func load(meetingID: UUID) throws -> StoredMeetingAnalysis?
    func replace(_ value: StoredMeetingAnalysis, meetingID: UUID) throws
}

enum MeetingAnalysisStoreEvent: Equatable, Sendable {
    case beforeAtomicReplacement(UUID)
}

enum MeetingAnalysisStoreError: Error, Equatable, Sendable {
    case unsafePath
    case corruptAnalysis
    case atomicWriteFailed
}

/// Stores analysis beside the local meeting record. It never reads from or
/// writes to the vault and never receives audio.
final class FileMeetingAnalysisStore: MeetingAnalysisStoring, @unchecked Sendable {
    static let filename = "analysis.json"

    private let rootURL: URL
    private let fileManager: FileManager
    private let failureInjector: (@Sendable (MeetingAnalysisStoreEvent) throws -> Void)?
    private let lock = NSLock()

    init(
        rootURL: URL = MeetingStore.productionRootURL,
        fileManager: FileManager = .default,
        failureInjector: (@Sendable (MeetingAnalysisStoreEvent) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.failureInjector = failureInjector
    }

    func load(meetingID: UUID) throws -> StoredMeetingAnalysis? {
        try withLock {
            let url = analysisURL(for: meetingID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            guard isRegularFile(url) else { throw MeetingAnalysisStoreError.unsafePath }
            do {
                return try JSONDecoder().decode(
                    StoredMeetingAnalysis.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw MeetingAnalysisStoreError.corruptAnalysis
            }
        }
    }

    func replace(_ value: StoredMeetingAnalysis, meetingID: UUID) throws {
        try withLock {
            let directory = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            try ensurePrivateDirectory(rootURL)
            try ensurePrivateDirectory(directory)
            let destination = analysisURL(for: meetingID)
            if fileManager.fileExists(atPath: destination.path), !isRegularFile(destination) {
                throw MeetingAnalysisStoreError.unsafePath
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            let temporary = directory.appendingPathComponent(
                ".\(Self.filename).\(UUID().uuidString).tmp"
            )
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw MeetingAnalysisStoreError.atomicWriteFailed
            }
            defer { try? fileManager.removeItem(at: temporary) }

            do {
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.synchronize()
                try handle.close()
                try failureInjector?(.beforeAtomicReplacement(meetingID))
                let result = temporary.withUnsafeFileSystemRepresentation { sourcePath in
                    destination.withUnsafeFileSystemRepresentation { destinationPath in
                        rename(sourcePath, destinationPath)
                    }
                }
                guard result == 0 else { throw MeetingAnalysisStoreError.atomicWriteFailed }
            } catch let error as MeetingAnalysisStoreError {
                throw error
            } catch {
                throw MeetingAnalysisStoreError.atomicWriteFailed
            }
        }
    }

    private func analysisURL(for meetingID: UUID) -> URL {
        rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.filename)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MeetingAnalysisStoreError.unsafePath
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

enum MeetingAnalysisFailure: Equatable, Sendable {
    case transcriptionNotFinal
    case providerNotReady(AIConnectionState)
    case providerFailure(AIProviderError)
    case cancelled
    case schemaFailure
    case persistenceFailure
}

struct MeetingAnalysisRunResult: Equatable, Sendable {
    let meeting: MeetingRecord
    let utterances: [MeetingUtterance]
    let speakerState: SpeakerEditingState
    let analysis: MeetingAnalysis?
    let failure: MeetingAnalysisFailure?

    var isRetryable: Bool { failure != nil }
}

/// Provider-neutral orchestration for completed local meetings. The only
/// process/network-capable dependency is the explicitly selected AI provider.
final class MeetingAnalysisService: Sendable {
    private let provider: any AIProviding
    private let contextChoice: AIContextChoice
    private let store: any MeetingAnalysisStoring

    init(
        provider: any AIProviding,
        contextChoice: AIContextChoice = .rich,
        store: any MeetingAnalysisStoring = FileMeetingAnalysisStore()
    ) {
        self.provider = provider
        self.contextChoice = contextChoice
        self.store = store
    }

    func analyzeAfterFinalTranscription(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState = SpeakerEditingState()
    ) async -> MeetingAnalysisRunResult {
        await analyze(
            meeting: meeting,
            utterances: utterances,
            speakerState: speakerState
        )
    }

    func reanalyze(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        await analyze(
            meeting: meeting,
            utterances: utterances,
            speakerState: speakerState
        )
    }

    func storedAnalysis(meetingID: UUID) throws -> StoredMeetingAnalysis? {
        try store.load(meetingID: meetingID)
    }

    /// Accepts exactly one suggestion and atomically persists the resulting
    /// speaker state. The caller's editor changes only after persistence wins.
    @discardableResult
    func acceptSpeakerSuggestion(
        meetingID: UUID,
        utteranceID: UUID,
        editor: inout SpeakerEditor
    ) throws -> Bool {
        guard var stored = try store.load(meetingID: meetingID),
              let suggestion = stored.analysis.speakerSuggestions.first(where: {
                  $0.utteranceID == utteranceID
              }) else {
            return false
        }
        var candidate = editor
        let speakerID = Self.stableAISpeakerID(for: suggestion.suggestedName)
        guard candidate.acceptAISuggestion(
            utteranceID: utteranceID,
            speakerID: speakerID,
            displayName: suggestion.suggestedName
        ) else {
            return false
        }
        stored.speakerState = candidate.state
        try store.replace(stored, meetingID: meetingID)
        editor = candidate
        return true
    }

    private func analyze(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        let reconciledSpeakerState = SpeakerEditor(
            utterances: utterances,
            state: speakerState
        ).state
        let previous = try? store.load(meetingID: meeting.id)

        guard meeting.lifecycleState == .completed,
              meeting.transcriptionState == .completed else {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .transcriptionNotFinal
            )
        }

        let readiness = await provider.testConnection()
        guard readiness == .ready else {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .providerNotReady(readiness)
            )
        }

        let prompt = MeetingAnalysisPrompt.make(
            contextChoice: contextChoice,
            utterances: utterances,
            speakerState: reconciledSpeakerState
        )
        do {
            let data = try await provider.run(
                prompt: prompt,
                jsonSchema: MeetingAnalysisSchema.jsonSchema
            )
            let analysis = try MeetingAnalysisSchema.decode(data, utterances: utterances)
            let value = StoredMeetingAnalysis(
                analysis: analysis,
                speakerState: reconciledSpeakerState
            )
            do {
                try store.replace(value, meetingID: meeting.id)
            } catch {
                return failedResult(
                    meeting: meeting,
                    utterances: utterances,
                    speakerState: reconciledSpeakerState,
                    previous: previous,
                    failure: .persistenceFailure
                )
            }
            var completed = meeting
            completed.analysisState = .completed
            if completed.titleSource != .manual,
               let title = MeetingContextTitle.normalizedAnalysisTitle(analysis.title) {
                completed.title = title
                completed.titleSource = .analysis
            }
            return MeetingAnalysisRunResult(
                meeting: completed,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                analysis: analysis,
                failure: nil
            )
        } catch AIProviderError.schemaFailure {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .schemaFailure
            )
        } catch let error as AIProviderError {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .providerFailure(error)
            )
        } catch is CancellationError {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .cancelled
            )
        } catch {
            return failedResult(
                meeting: meeting,
                utterances: utterances,
                speakerState: reconciledSpeakerState,
                previous: previous,
                failure: .schemaFailure
            )
        }
    }

    private func failedResult(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState,
        previous: StoredMeetingAnalysis?,
        failure: MeetingAnalysisFailure
    ) -> MeetingAnalysisRunResult {
        var failed = meeting
        failed.analysisState = .failed
        return MeetingAnalysisRunResult(
            meeting: failed,
            utterances: utterances,
            speakerState: speakerState,
            analysis: previous?.analysis,
            failure: failure
        )
    }

    private static func stableAISpeakerID(for displayName: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "ai-speaker-" + String(hash, radix: 16)
    }
}
