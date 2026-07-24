import Foundation
import Testing
@testable import BrainMenu

struct FallbackLiveTranscriptionClientTests {
    @Test
    func unsupportedParakeetRetriesWithWhisperAndStaysThere() async throws {
        let underlying = ScriptedLiveTranscriptionClient(outcomes: [
            .unsupported("parakeet"),
            .transcript("first fallback"),
            .transcript("second fallback"),
        ])
        let client = FallbackLiveTranscriptionClient(client: underlying)

        #expect(
            try await client.transcribe(wavURL: wav("first"), engine: "parakeet")
                == "first fallback"
        )
        #expect(
            try await client.transcribe(wavURL: wav("second"), engine: "parakeet")
                == "second fallback"
        )
        #expect(await underlying.engines == ["parakeet", "whisper", "whisper"])
    }

    @Test
    func ordinaryParakeetFailureDoesNotActivateFallback() async throws {
        let underlying = ScriptedLiveTranscriptionClient(outcomes: [
            .clientError(.invalidTranscript),
            .transcript("primary recovered"),
        ])
        let client = FallbackLiveTranscriptionClient(client: underlying)

        await #expect(throws: VoxTypeClientError.invalidTranscript) {
            try await client.transcribe(wavURL: wav("failed"), engine: "parakeet")
        }
        #expect(
            try await client.transcribe(wavURL: wav("recovered"), engine: "parakeet")
                == "primary recovered"
        )
        #expect(await underlying.engines == ["parakeet", "parakeet"])
    }

    @Test
    func explicitWhisperRequestPassesThroughWithoutChangingParakeetState() async throws {
        let underlying = ScriptedLiveTranscriptionClient(outcomes: [
            .transcript("explicit whisper"),
            .transcript("working parakeet"),
        ])
        let client = FallbackLiveTranscriptionClient(client: underlying)

        #expect(
            try await client.transcribe(wavURL: wav("whisper"), engine: "whisper")
                == "explicit whisper"
        )
        #expect(
            try await client.transcribe(wavURL: wav("parakeet"), engine: "parakeet")
                == "working parakeet"
        )
        #expect(await underlying.engines == ["whisper", "parakeet"])
    }

    @Test
    func concurrentParakeetRequestsShareOneCapabilityProbe() async throws {
        let underlying = BlockingUnsupportedLiveTranscriptionClient()
        let client = FallbackLiveTranscriptionClient(client: underlying)
        let first = Task {
            try await client.transcribe(wavURL: wav("first-concurrent"), engine: "parakeet")
        }
        await waitForCallCount(1, in: underlying)
        let second = Task {
            try await client.transcribe(wavURL: wav("second-concurrent"), engine: "parakeet")
        }

        for _ in 0..<100 { await Task.yield() }
        #expect(await underlying.engines == ["parakeet"])

        await underlying.releaseUnsupportedProbe()
        #expect(try await first.value == "whisper:first-concurrent.wav")
        #expect(try await second.value == "whisper:second-concurrent.wav")
        #expect(await underlying.engines == ["parakeet", "whisper", "whisper"])
    }

    @Test
    func concurrentMeetingRequestsNeverRunTwoVoxTypeJobsAtOnce() async throws {
        let underlying = BlockingSuccessLiveTranscriptionClient()
        let client = FallbackLiveTranscriptionClient(client: underlying)
        let first = Task {
            try await client.transcribe(wavURL: wav("first-serialized"), engine: "whisper")
        }
        await underlying.waitUntilCallCount(atLeast: 1)
        let second = Task {
            try await client.transcribe(wavURL: wav("second-serialized"), engine: "whisper")
        }

        for _ in 0..<100 { await Task.yield() }
        #expect(await underlying.callCount == 1)

        await underlying.releaseNext()
        #expect(try await first.value == "whisper:first-serialized.wav")
        await underlying.waitUntilCallCount(atLeast: 2)
        await underlying.releaseNext()
        #expect(try await second.value == "whisper:second-serialized.wav")
        #expect(await underlying.maximumConcurrentCalls == 1)
    }

    private func wav(_ name: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/\(name).wav")
    }

    private func waitForCallCount(
        _ count: Int,
        in client: BlockingUnsupportedLiveTranscriptionClient
    ) async {
        for _ in 0..<200 {
            if await client.engines.count == count { return }
            await Task.yield()
        }
        Issue.record("Expected \(count) transcription call(s)")
    }
}

private actor ScriptedLiveTranscriptionClient: LiveTranscriptionClient {
    enum Outcome: Sendable {
        case transcript(String)
        case unsupported(String)
        case clientError(VoxTypeClientError)
    }

    private var outcomes: [Outcome]
    private(set) var engines: [String] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        engines.append(engine)
        guard !outcomes.isEmpty else {
            throw VoxTypeClientError.launchFailed(command: .transcribe)
        }
        switch outcomes.removeFirst() {
        case .transcript(let value):
            return value
        case .unsupported(let unsupportedEngine):
            throw VoxTypeUnsupportedEngineError(engine: unsupportedEngine)
        case .clientError(let error):
            throw error
        }
    }
}

private actor BlockingUnsupportedLiveTranscriptionClient: LiveTranscriptionClient {
    private var releaseProbe: CheckedContinuation<Void, Never>?
    private(set) var engines: [String] = []

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        engines.append(engine)
        if engine == "parakeet" {
            await withCheckedContinuation { continuation in
                releaseProbe = continuation
            }
            throw VoxTypeUnsupportedEngineError(engine: engine)
        }
        return "\(engine):\(wavURL.lastPathComponent)"
    }

    func releaseUnsupportedProbe() {
        releaseProbe?.resume()
        releaseProbe = nil
    }
}

private actor BlockingSuccessLiveTranscriptionClient: LiveTranscriptionClient {
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var countContinuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        callCount += 1
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        let ready = countContinuations.filter { callCount >= $0.0 }
        countContinuations.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        concurrentCalls -= 1
        return "\(engine):\(wavURL.lastPathComponent)"
    }

    func waitUntilCallCount(atLeast expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            countContinuations.append((expected, continuation))
        }
    }

    func releaseNext() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
    }
}
