import Foundation

/// Uses the requested Parakeet engine until VoxType reports that the installed
/// executable lacks that compile-time feature. The first such failure retries
/// the same audio with Whisper; subsequent Parakeet requests go directly to
/// Whisper for the lifetime of this wrapper.
actor FallbackLiveTranscriptionClient: LiveTranscriptionClient {
    private enum PrimaryEngineState: Equatable {
        case available
        case probing
        case useFallback
    }

    private let client: any LiveTranscriptionClient
    private let primaryEngine: String
    private let fallbackEngine: String
    private var primaryState = PrimaryEngineState.available
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcriptionIsRunning = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: any LiveTranscriptionClient,
        primaryEngine: SpeechEngineID = .parakeet,
        fallbackEngine: SpeechEngineID = .whisper
    ) {
        self.client = client
        self.primaryEngine = primaryEngine.rawValue
        self.fallbackEngine = fallbackEngine.rawValue
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        try await transcribe(wavURL: wavURL, engine: engine, model: nil)
    }

    func transcribe(wavURL: URL, engine: String, model: String?) async throws -> String {
        await acquireTranscriptionSlot()
        defer { releaseTranscriptionSlot() }
        try Task.checkCancellation()
        return try await transcribeExclusively(wavURL: wavURL, engine: engine, model: model)
    }

    private func transcribeExclusively(
        wavURL: URL,
        engine: String,
        model: String?
    ) async throws -> String {
        guard engine == primaryEngine else {
            return try await client.transcribe(wavURL: wavURL, engine: engine, model: model)
        }

        while primaryState == .probing {
            await waitForPrimaryProbe()
            try Task.checkCancellation()
        }
        if primaryState == .useFallback {
            return try await client.transcribe(
                wavURL: wavURL,
                engine: fallbackEngine,
                model: model
            )
        }

        primaryState = .probing
        do {
            let transcript = try await client.transcribe(
                wavURL: wavURL,
                engine: primaryEngine,
                model: model
            )
            completePrimaryProbe(with: .available)
            return transcript
        } catch let error as VoxTypeUnsupportedEngineError
            where error.engine.caseInsensitiveCompare(primaryEngine) == .orderedSame {
            completePrimaryProbe(with: .useFallback)
            return try await client.transcribe(
                wavURL: wavURL,
                engine: fallbackEngine,
                model: model
            )
        } catch {
            completePrimaryProbe(with: .available)
            throw error
        }
    }

    private func acquireTranscriptionSlot() async {
        guard transcriptionIsRunning else {
            transcriptionIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func releaseTranscriptionSlot() {
        guard !transcriptionWaiters.isEmpty else {
            transcriptionIsRunning = false
            return
        }
        transcriptionWaiters.removeFirst().resume()
    }

    func effectiveEngine(for requestedEngine: String) -> String {
        requestedEngine == primaryEngine && primaryState == .useFallback
            ? fallbackEngine
            : requestedEngine
    }

    private func waitForPrimaryProbe() async {
        await withCheckedContinuation { continuation in
            probeWaiters.append(continuation)
        }
    }

    private func completePrimaryProbe(with state: PrimaryEngineState) {
        primaryState = state
        let waiters = probeWaiters
        probeWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}
