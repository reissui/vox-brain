import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct LiveTranscriptControllerTests {
    @Test
    @MainActor
    func publishesSettledPreviewSnapshotsForDurableCheckpointing() async throws {
        let fixture = try LiveTranscriptFixture()
        let service = try LiveTranscriptionService(
            client: FakeLiveTranscriptionClient(),
            engine: .whisper,
            originHostTimestamp: 100,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        var checkpoints: [[MeetingUtterance]] = []
        controller.setUtteranceCheckpointHandler { checkpoints.append($0) }

        let speech = fixture.buffer(
            source: .microphone,
            hostTimestamp: 100,
            duration: 3,
            amplitude: 0.25
        )
        let pause = fixture.buffer(
            source: .microphone,
            hostTimestamp: 103,
            duration: 1.3,
            amplitude: 0
        )
        await controller.append(speech)
        await controller.append(pause)
        await controller.waitForPendingPreview()

        #expect(checkpoints.last == controller.utterances)
        #expect(checkpoints.last?.first?.text == "preview microphone 0")
        #expect(checkpoints.last?.first?.endMilliseconds == 3_500)
    }

    @Test
    @MainActor
    func segmentsContextualSpeechSkipsSilenceFlushesTailAndCleansWAVs() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .whisper,
            originHostTimestamp: 100,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)

        let firstSpeech = fixture.buffer(
            source: .microphone,
            hostTimestamp: 100,
            duration: 4,
            amplitude: 0.25
        )
        let closingPause = fixture.buffer(
            source: .microphone,
            hostTimestamp: 104,
            duration: 1.3,
            amplitude: 0
        )
        let systemSilence = fixture.buffer(
            source: .system,
            hostTimestamp: 100,
            duration: 12,
            amplitude: 0
        )
        let shortTail = fixture.buffer(
            source: .microphone,
            hostTimestamp: 110,
            duration: 2,
            amplitude: 0.2
        )
        await controller.append(firstSpeech)
        await controller.append(closingPause)
        await controller.append(systemSilence)
        await controller.append(shortTail)
        await controller.waitForPendingPreview()

        #expect(controller.utterances.count == 1)
        #expect(controller.utterances.first?.source == .microphone)
        #expect(controller.utterances.first?.startMilliseconds == 0)
        #expect(controller.utterances.first?.endMilliseconds == 4_520)
        #expect(controller.utterances.first?.humanName == "You")

        let capture = try fixture.captureSummary(
            tracks: [(.microphone, 8, 0), (.system, 8, 0)]
        )
        await controller.stop(capture: capture)

        let calls = await client.calls
        let previews = calls.filter { $0.phase == .preview }
        let finals = calls.filter { $0.phase == .final }.sorted(by: callOrder)
        #expect(previews.map(\.source) == [.microphone, .microphone])
        #expect(previews.map(\.startMilliseconds) == [0, 9_490])
        #expect(previews.map(\.endMilliseconds) == [4_520, 12_000])
        #expect(finals.map(\.source) == [.microphone, .system])
        #expect(finals.map(\.startMilliseconds) == [0, 0])
        #expect(calls.allSatisfy { $0.engine == "whisper" })
        #expect(calls.allSatisfy { $0.wasOwnerOnly && $0.hadWAVHeader })
        #expect(previews.map(\.wavDataByteCount) == [
            4_520 * MeetingAudioWriter.sampleRate / 1_000 * MemoryLayout<Float>.size,
            2_510 * MeetingAudioWriter.sampleRate / 1_000 * MemoryLayout<Float>.size,
        ])
        #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))

        #expect(controller.utterances.count == 3)
        #expect(Set(controller.utterances.map(\.humanName)) == Set(["You", "Remote"]))
        #expect(controller.utterances.filter { $0.text.hasPrefix("final ") }.count == 2)
        #expect(controller.utterances.contains {
            $0.text == "preview microphone 9490"
                && $0.startMilliseconds == 9_490
                && $0.endMilliseconds == 12_000
        })
        #expect(controller.errors.isEmpty)
        #expect(controller.previewLag == .current)

        let first = LiveTranscriptSegment(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10_000,
            text: "one",
            phase: .preview
        )
        let repeated = LiveTranscriptSegment(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10_000,
            text: "different result, same source range",
            phase: .preview
        )
        #expect(first.id == repeated.id)
    }

    @Test
    @MainActor
    func keepsOneActiveAndNewestPendingPerSourceWithoutConcurrentProcesses() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(blockFirstPreviewSource: .microphone)
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 50,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)

        var capturedBuffers: [MeetingAudioSampleBuffer] = []
        let firstMicrophone = fixture.buffer(
            source: .microphone,
            hostTimestamp: 50,
            duration: 20,
            amplitude: 0.3
        )
        capturedBuffers.append(firstMicrophone)
        await controller.append(firstMicrophone)
        await client.waitUntilFirstBlockedPreviewStarts()

        // The other source remains independent and can complete while the
        // microphone process is deliberately blocked.
        let system = fixture.buffer(
            source: .system,
            hostTimestamp: 50,
            duration: 20,
            amplitude: 0.4
        )
        capturedBuffers.append(system)
        await controller.append(system)
        await client.waitForCallCount(2)
        await service.waitForPendingPreview(source: .system)
        #expect(controller.utterances.map(\.source) == [.system])

        for index in 1...3 {
            let buffer = fixture.buffer(
                source: .microphone,
                hostTimestamp: 50 + Double(index * 20),
                duration: 20,
                amplitude: 0.3
            )
            capturedBuffers.append(buffer)
            await controller.append(buffer)
        }

        let backedUp = await service.snapshot()
        #expect(backedUp.activeSources.contains(.microphone))
        #expect(backedUp.pendingChunksBySource[.microphone] == 1)
        #expect(backedUp.previewLag == .lagging(droppedChunksBySource: [.microphone: 2]))
        #expect(controller.previewLag == .lagging(droppedChunksBySource: [.microphone: 2]))

        await client.releaseBlockedPreview()
        await controller.waitForPendingPreview()

        let calls = await client.calls.filter { $0.phase == .preview }
        let microphoneCalls = calls.filter { $0.source == .microphone }
        #expect(microphoneCalls.count == 2)
        #expect(microphoneCalls.map(\.startMilliseconds) == [0, 60_000])
        #expect(!microphoneCalls.contains { $0.startMilliseconds == 20_000 })
        #expect(!microphoneCalls.contains { $0.startMilliseconds == 40_000 })
        #expect(await client.maximumConcurrent(for: .microphone) == 1)
        #expect(await client.maximumConcurrent(for: .system) == 1)
        #expect(controller.utterances == controller.utterances.sorted(by: utteranceOrder))
        #expect(controller.utterances.first { $0.source == .system }?.humanName == "Remote")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.wavDirectory.path).isEmpty)

        await controller.stop(capture: try fixture.captureSummary(buffers: capturedBuffers))

        let finalMicrophoneCalls = await client.calls.filter {
            $0.phase == .final && $0.source == .microphone
        }
        #expect(finalMicrophoneCalls.contains {
            ($0.startMilliseconds ?? .max) < 80_000 && ($0.endMilliseconds ?? 0) > 70_000
        })
        #expect(controller.utterances.contains {
            $0.source == .microphone && $0.endMilliseconds > 70_000
        })
        #expect(controller.previewLag == .current)
    }

    @Test
    @MainActor
    func stopWaitsForAdmittedActivePreviewAtPublicBoundary() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(blockFirstPreviewSource: .microphone)
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 90,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffer = fixture.buffer(
            source: .microphone,
            hostTimestamp: 90,
            duration: 20,
            amplitude: 0.2
        )
        await controller.append(buffer)
        await client.waitUntilFirstBlockedPreviewStarts()
        let capture = try fixture.captureSummary(buffers: [buffer])

        let stopping = Task { await controller.stop(capture: capture) }
        for _ in 0..<100 where !controller.isFinalizing { await Task.yield() }

        #expect(controller.isFinalizing)
        #expect(await client.calls.filter { $0.phase == .final }.isEmpty)
        await client.releaseBlockedPreview()
        await stopping.value

        #expect(controller.isFinalized)
        #expect(await client.calls.first?.phase == .preview)
        #expect(await client.calls.contains { $0.phase == .final })
        #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))
    }

    @Test
    @MainActor
    func finalizationOrdersAlternatingSourcesWithinOnePreviewWindow() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 100,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)

        let buffers = [
            fixture.buffer(source: .microphone, hostTimestamp: 100, duration: 2, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 102.5, duration: 1.5, amplitude: 0.2),
            fixture.buffer(source: .microphone, hostTimestamp: 105, duration: 1, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 107, duration: 2, amplitude: 0.2),
        ]
        for buffer in buffers {
            await controller.append(buffer)
        }
        let capture = try fixture.captureSummary(buffers: buffers)
        await controller.stop(capture: capture)

        #expect(controller.isFinalized)
        #expect(controller.utterances.map(\.source) == [
            .microphone, .system, .microphone, .system,
        ])
        let starts = controller.utterances.map(\.startMilliseconds)
        #expect(starts.allSatisfy { $0 < 10_000 })
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(controller.utterances.map(\.humanName) == [
            "You", "Remote", "You", "Remote",
        ])
        #expect(controller.utterances.allSatisfy { $0.text.hasPrefix("final ") })
        #expect(controller.errors.isEmpty)
    }

    @Test
    @MainActor
    func acknowledgementInRemotePauseKeepsConversationalOrder() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 150,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [
            fixture.buffer(source: .system, hostTimestamp: 150, duration: 0.6, amplitude: 0.2),
            fixture.buffer(
                source: .microphone,
                hostTimestamp: 150.63,
                duration: 0.24,
                amplitude: 0.2
            ),
            fixture.buffer(source: .system, hostTimestamp: 150.9, duration: 0.6, amplitude: 0.2),
        ]
        for buffer in buffers { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        #expect(controller.utterances.map(\.source) == [.system, .microphone, .system])
        #expect(controller.utterances.map(\.startMilliseconds) == [0, 430, 700])
        #expect(controller.utterances.map(\.text) == [
            "final system 0",
            "final microphone 430",
            "final system 700",
        ])
    }

    @Test
    @MainActor
    func finalizationRetainsGenuineCrossSourceOverlap() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 200,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [
            fixture.buffer(source: .microphone, hostTimestamp: 200, duration: 3, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 201, duration: 3, amplitude: 0.2),
        ]
        for buffer in buffers { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        let microphone = try #require(controller.utterances.first { $0.source == .microphone })
        let system = try #require(controller.utterances.first { $0.source == .system })
        #expect(microphone.startMilliseconds < system.startMilliseconds)
        #expect(microphone.endMilliseconds > system.startMilliseconds)
        #expect(system.endMilliseconds > microphone.startMilliseconds)
        #expect(controller.errors.isEmpty)
    }

    @Test
    @MainActor
    func spanSpecificFailureRetriesContinuesAndNeverFabricatesAnUtterance() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(transientFinalFailures: [.system: 2])
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 300,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [
            fixture.buffer(source: .microphone, hostTimestamp: 300, duration: 1, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 302, duration: 0.3, amplitude: 0.2),
            fixture.buffer(source: .microphone, hostTimestamp: 304, duration: 1, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 306, duration: 0.3, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 308, duration: 0.3, amplitude: 0.2),
        ]
        for buffer in buffers { await controller.append(buffer) }
        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        #expect(controller.utterances.filter { $0.source == .microphone }.count == 2)
        #expect(controller.utterances.filter { $0.source == .microphone }
            .allSatisfy { $0.text.hasPrefix("final ") })
        #expect(controller.utterances.filter { $0.source == .system }.count == 2)
        #expect(!controller.utterances.contains {
            $0.text.localizedCaseInsensitiveContains("transcript unavailable")
        })
        let failedCalls = await client.calls.filter {
            $0.phase == .final && $0.source == .system
        }
        #expect(failedCalls.count == 4)
        #expect(controller.errors.count == 1)
        let failure = try #require(controller.errors.first)
        #expect(failure.source == .system)
        #expect(failure.phase == .final)
        #expect(failure.startMilliseconds == failedCalls.first?.startMilliseconds)
        #expect(failure.endMilliseconds == failedCalls.first?.endMilliseconds)
        let meeting = MeetingRecord(
            title: "Failure-safe transcript",
            startedAt: Date(timeIntervalSince1970: 1_784_201_000),
            endedAt: Date(timeIntervalSince1970: 1_784_201_010),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        let store = MeetingStore(rootURL: fixture.root.appendingPathComponent("store"))
        try store.save(meeting, utterances: controller.utterances)
        let loaded = try store.load(meeting.id)
        #expect(loaded.utterances == controller.utterances)
        let markdown = MeetingMarkdownRenderer().render(
            meeting: loaded.meeting,
            utterances: loaded.utterances,
            storedAnalysis: nil
        )
        #expect(!markdown.localizedCaseInsensitiveContains("transcript unavailable"))
        #expect(controller.isFinalized)
        #expect(!controller.isFinalizing)
        #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))
    }

    @Test
    @MainActor
    func systemicFinalTimeoutTripsPerSourceCircuitAfterOneCall() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(systemicFinalFailureSources: [.system])
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 350,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [
            fixture.buffer(source: .system, hostTimestamp: 350, duration: 0.3, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 352, duration: 0.3, amplitude: 0.2),
            fixture.buffer(source: .system, hostTimestamp: 354, duration: 0.3, amplitude: 0.2),
        ]
        for buffer in buffers { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        let finalCalls = await client.calls.filter { $0.phase == .final }
        #expect(finalCalls.count == 1)
        #expect(controller.errors.count == 1)
        #expect(!controller.utterances.isEmpty)
        #expect(controller.utterances.allSatisfy { $0.text.hasPrefix("preview ") })
    }

    @Test
    @MainActor
    func repeatedOrdinaryFinalFailuresStopAfterThreeSpans() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(failingFinalSources: [.system])
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 375,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [0.0, 2.0, 4.0, 6.0].map { offset in
            fixture.buffer(
                source: .system,
                hostTimestamp: 375 + offset,
                duration: 0.3,
                amplitude: 0.2
            )
        }
        for buffer in buffers { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        let finalCalls = await client.calls.filter { $0.phase == .final }
        #expect(finalCalls.count == 6)
        #expect(controller.errors.count == 3)
        #expect(controller.utterances.count == 2)
        #expect(controller.utterances.allSatisfy { $0.text.hasPrefix("preview ") })
    }

    @Test
    @MainActor
    func transientFinalSpanFailureSucceedsOnItsSingleRetry() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient(transientFinalFailures: [.microphone: 1])
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 400,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffer = fixture.buffer(
            source: .microphone,
            hostTimestamp: 400,
            duration: 0.8,
            amplitude: 0.02
        )
        await controller.append(buffer)

        await controller.stop(capture: try fixture.captureSummary(buffers: [buffer]))

        let finalCalls = await client.calls.filter { $0.phase == .final }
        #expect(finalCalls.count == 2)
        #expect(controller.utterances.count == 1)
        #expect(controller.utterances.first?.source == .microphone)
        #expect(controller.errors.isEmpty)
    }

    @Test
    @MainActor
    func validTimelineWithNoFinalSpeechSpansRejectsWeakPreview() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 450,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let shortTurn = fixture.buffer(
            source: .microphone,
            hostTimestamp: 450,
            duration: 0.06,
            amplitude: 0.2
        )
        await controller.append(shortTurn)

        await controller.stop(capture: try fixture.captureSummary(buffers: [shortTurn]))

        #expect(controller.utterances.isEmpty)
        #expect(await client.calls.filter { $0.phase == .final }.isEmpty)
        #expect(controller.errors.isEmpty)
    }

    @Test
    @MainActor
    func preservesOnlyQuietSourcesWhileReplacingSuccessfulSources() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 475,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffers = [
            fixture.buffer(
                source: .microphone,
                hostTimestamp: 475,
                duration: 1,
                amplitude: 0.2
            ),
            fixture.sparseBuffer(
                source: .system,
                hostTimestamp: 475,
                duration: 0.06,
                peakAmplitude: 0.02
            ),
        ]
        for buffer in buffers { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(buffers: buffers))

        let microphone = try #require(controller.utterances.first { $0.source == .microphone })
        #expect(microphone.text.hasPrefix("final "))
        #expect(!controller.utterances.contains { $0.source == .system })
        #expect(controller.errors.isEmpty)
    }

    @Test
    @MainActor
    func rejectsLaterWeakPreviewAfterEarlierFinalSuccess() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 490,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let loud = fixture.buffer(
            source: .microphone,
            hostTimestamp: 490,
            duration: 1,
            amplitude: 0.2
        )
        let sparseAcknowledgement = fixture.sparseBuffer(
            source: .microphone,
            hostTimestamp: 500,
            duration: 0.06,
            peakAmplitude: 0.02
        )
        for buffer in [loud, sparseAcknowledgement] { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(
            buffers: [loud, sparseAcknowledgement]
        ))

        #expect(controller.utterances.count == 1)
        #expect(controller.utterances.first?.text.hasPrefix("final ") == true)
    }

    @Test
    @MainActor
    func sameWindowSparseAcknowledgementIsFinalizedBesideLoudSpeech() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 525,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let loud = fixture.buffer(
            source: .microphone,
            hostTimestamp: 525,
            duration: 1,
            amplitude: 0.2
        )
        let sparseAcknowledgement = fixture.sparseBuffer(
            source: .microphone,
            hostTimestamp: 530,
            duration: 0.15,
            peakAmplitude: 0.02
        )
        for buffer in [loud, sparseAcknowledgement] { await controller.append(buffer) }

        await controller.stop(capture: try fixture.captureSummary(
            buffers: [loud, sparseAcknowledgement]
        ))

        #expect(controller.utterances.count == 2)
        #expect(controller.utterances.allSatisfy { $0.text.hasPrefix("final ") })
        #expect(controller.utterances.map(\.startMilliseconds) == [0, 4_780])
        #expect(controller.utterances.map(\.endMilliseconds) == [1_220, 5_330])
    }

    @Test
    @MainActor
    func overflowingFinalTimelineKeepsPreviewsAndReturnsBoundedFailures() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = FakeLiveTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 500,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        for source in MeetingAudioSource.allCases {
            await controller.append(fixture.buffer(
                source: source,
                hostTimestamp: 500,
                duration: 10,
                amplitude: 0.2
            ))
        }
        await controller.waitForPendingPreview()
        let previews = controller.utterances
        let valid = try fixture.captureSummary(
            tracks: [(.microphone, 5, 0), (.system, 5, 0)]
        )
        let invalidChunks = valid.chunks.map { chunk in
            MeetingAudioChunk(
                source: chunk.source,
                timestampMilliseconds: .max,
                sourceTimestamp: chunk.sourceTimestamp,
                frameOffset: chunk.frameOffset,
                frameCount: chunk.frameCount
            )
        }
        let invalid = MeetingAudioCaptureSummary(
            origin: valid.origin,
            originHostTimestamp: valid.originHostTimestamp,
            tracks: valid.tracks,
            chunks: invalidChunks,
            discontinuities: valid.discontinuities,
            failures: valid.failures
        )

        await controller.stop(capture: invalid)

        #expect(previews.isEmpty)
        #expect(controller.utterances.count == 2)
        #expect(controller.utterances.allSatisfy { $0.text.hasPrefix("preview ") })
        #expect(Set(controller.errors.map(\.source)) == Set(MeetingAudioSource.allCases))
        #expect(controller.errors.allSatisfy { $0.phase == .final })
        #expect(controller.errors.allSatisfy { $0.endMilliseconds == .max })
    }

    @Test
    @MainActor
    func cancellationDuringFinalPassStopsClientAndPublishesNoFinalResult() async throws {
        let fixture = try LiveTranscriptFixture()
        let client = CancellableFinalTranscriptionClient()
        let service = try LiveTranscriptionService(
            client: client,
            engine: .parakeet,
            originHostTimestamp: 550,
            wavDirectory: fixture.wavDirectory
        )
        let controller = LiveTranscriptController(service: service)
        let buffer = fixture.buffer(
            source: .microphone,
            hostTimestamp: 550,
            duration: 1,
            amplitude: 0.2
        )
        let capture = try fixture.captureSummary(buffers: [buffer])
        let stopping = Task { await controller.stop(capture: capture) }
        await client.waitUntilFinalStarted()

        await controller.cancel()
        await stopping.value

        #expect(await client.wasCancelled)
        #expect(controller.utterances.isEmpty)
        #expect(controller.errors.isEmpty)
        #expect(!controller.isFinalizing)
        #expect(!controller.isFinalized)
        #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))
    }

    @Test
    @MainActor
    func removesPreviewWAVAfterFailureAndCancellation() async throws {
        do {
            let fixture = try LiveTranscriptFixture()
            let client = FakeLiveTranscriptionClient(failingPreviewSources: [.system])
            let service = try LiveTranscriptionService(
                client: client,
                engine: .parakeet,
                originHostTimestamp: 0,
                wavDirectory: fixture.wavDirectory
            )
            let controller = LiveTranscriptController(service: service)
            await controller.append(fixture.buffer(
                source: .system,
                hostTimestamp: 0,
                duration: 20,
                amplitude: 0.2
            ))
            await controller.waitForPendingPreview()

            #expect(controller.utterances.isEmpty)
            #expect(controller.errors.first?.phase == .preview)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: fixture.wavDirectory.path
            ).isEmpty)
            await controller.cancel()
            #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))
        }

        do {
            let fixture = try LiveTranscriptFixture()
            let client = CancellableLiveTranscriptionClient()
            let service = try LiveTranscriptionService(
                client: client,
                engine: .parakeet,
                originHostTimestamp: 0,
                wavDirectory: fixture.wavDirectory
            )
            let controller = LiveTranscriptController(service: service)
            await controller.append(fixture.buffer(
                source: .microphone,
                hostTimestamp: 0,
                duration: 20,
                amplitude: 0.2
            ))
            await client.waitUntilStarted()
            #expect(try !FileManager.default.contentsOfDirectory(
                atPath: fixture.wavDirectory.path
            ).isEmpty)

            // While one request is active, retain only the newest pending WAV;
            // cancellation must remove both active and pending files.
            await controller.append(fixture.buffer(
                source: .microphone,
                hostTimestamp: 20,
                duration: 20,
                amplitude: 0.2
            ))

            await controller.cancel()

            #expect(await client.wasCancelled)
            #expect(try transcriptionDirectoryIsAbsentOrEmpty(fixture.wavDirectory))
        }
    }

    @Test
    func sweepsOnlyOwnedKnownStaleWAVsAndKeepsUnknownEntries() async throws {
        let fixture = try LiveTranscriptFixture()
        try FileManager.default.createDirectory(
            at: fixture.wavDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let stale = fixture.wavDirectory.appendingPathComponent("preview-microphone-stale.wav")
        let unknown = fixture.wavDirectory.appendingPathComponent("keep.txt")
        let symlink = fixture.wavDirectory.appendingPathComponent("final-system-link.wav")
        let directory = fixture.wavDirectory.appendingPathComponent("final-system-folder.wav")
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("speech".utf8)))
        #expect(FileManager.default.createFile(atPath: unknown.path, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unknown)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let service = try LiveTranscriptionService(
            client: FakeLiveTranscriptionClient(),
            engine: .parakeet,
            originHostTimestamp: 0,
            wavDirectory: fixture.wavDirectory
        )

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        await service.cancel()
        #expect(FileManager.default.fileExists(atPath: fixture.wavDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test
    func livePathContainsNoPasteFocusOrStreamingPartialCommand() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu", isDirectory: true)
        let service = try String(
            contentsOf: sourceRoot.appendingPathComponent("Speech/LiveTranscriptionService.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: sourceRoot.appendingPathComponent("Meetings/LiveTranscriptController.swift"),
            encoding: .utf8
        )
        let implementation = service + controller

        #expect(!implementation.contains("record start"))
        #expect(!implementation.contains("--paste"))
        #expect(!implementation.contains("NSWorkspace"))
        #expect(!implementation.contains("makeKey"))
        #expect(!implementation.contains("partial-json"))
        #expect(service.contains("client.transcribe("))
        #expect(service.contains("engine: engine.rawValue"))
    }

    private func sourceOrder(_ lhs: MeetingAudioSource, _ rhs: MeetingAudioSource) -> Bool {
        Self.sourceIndex(lhs) < Self.sourceIndex(rhs)
    }

    private func callOrder(
        _ lhs: RecordedLiveTranscriptionCall,
        _ rhs: RecordedLiveTranscriptionCall
    ) -> Bool {
        let lhsStart = lhs.startMilliseconds ?? .max
        let rhsStart = rhs.startMilliseconds ?? .max
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        let lhsEnd = lhs.endMilliseconds ?? .max
        let rhsEnd = rhs.endMilliseconds ?? .max
        if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private func utteranceOrder(_ lhs: MeetingUtterance, _ rhs: MeetingUtterance) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds {
            return lhs.startMilliseconds < rhs.startMilliseconds
        }
        if lhs.endMilliseconds != rhs.endMilliseconds {
            return lhs.endMilliseconds < rhs.endMilliseconds
        }
        if lhs.source != rhs.source { return Self.sourceIndex(lhs.source) < Self.sourceIndex(rhs.source) }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sourceIndex(_ source: MeetingAudioSource) -> Int {
        MeetingAudioSource.allCases.firstIndex(of: source) ?? .max
    }
}

private struct RecordedLiveTranscriptionCall: Equatable, Sendable {
    let phase: LiveTranscriptionPhase
    let source: MeetingAudioSource
    let startMilliseconds: Int64?
    let endMilliseconds: Int64?
    let engine: String
    let wasOwnerOnly: Bool
    let hadWAVHeader: Bool
    let wavDataByteCount: Int
}

private enum FakeLiveTranscriptionError: Error, LocalizedError, Sendable {
    case finalFailure

    var errorDescription: String? { "Fake final transcription failed." }
}

private actor FakeLiveTranscriptionClient: LiveTranscriptionClient {
    private let blockFirstPreviewSource: MeetingAudioSource?
    private let failingPreviewSources: Set<MeetingAudioSource>
    private let failingPreviewStarts: [MeetingAudioSource: Set<Int64>]
    private let failingFinalSources: Set<MeetingAudioSource>
    private let systemicFinalFailureSources: Set<MeetingAudioSource>
    private var remainingTransientFinalFailures: [MeetingAudioSource: Int]
    private var recordedCalls: [RecordedLiveTranscriptionCall] = []
    private var activeBySource: [MeetingAudioSource: Int] = [:]
    private var maximumBySource: [MeetingAudioSource: Int] = [:]
    private var blockedPreviewStarted = false
    private var blockedPreviewReleased = false
    private var blockedPreviewContinuation: CheckedContinuation<Void, Never>?
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        blockFirstPreviewSource: MeetingAudioSource? = nil,
        failingPreviewSources: Set<MeetingAudioSource> = [],
        failingPreviewStarts: [MeetingAudioSource: Set<Int64>] = [:],
        failingFinalSources: Set<MeetingAudioSource> = [],
        systemicFinalFailureSources: Set<MeetingAudioSource> = [],
        transientFinalFailures: [MeetingAudioSource: Int] = [:]
    ) {
        self.blockFirstPreviewSource = blockFirstPreviewSource
        self.failingPreviewSources = failingPreviewSources
        self.failingPreviewStarts = failingPreviewStarts
        self.failingFinalSources = failingFinalSources
        self.systemicFinalFailureSources = systemicFinalFailureSources
        remainingTransientFinalFailures = transientFinalFailures
    }

    var calls: [RecordedLiveTranscriptionCall] { recordedCalls }

    func maximumConcurrent(for source: MeetingAudioSource) -> Int {
        maximumBySource[source, default: 0]
    }

    func waitUntilFirstBlockedPreviewStarts() async {
        guard !blockedPreviewStarted else { return }
        await withCheckedContinuation { blockedStartWaiters.append($0) }
    }

    func waitForCallCount(_ count: Int) async {
        guard recordedCalls.count < count else { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    func releaseBlockedPreview() {
        blockedPreviewReleased = true
        blockedPreviewContinuation?.resume()
        blockedPreviewContinuation = nil
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        let call = try Self.call(wavURL: wavURL, engine: engine)
        recordedCalls.append(call)
        activeBySource[call.source, default: 0] += 1
        maximumBySource[call.source] = max(
            maximumBySource[call.source, default: 0],
            activeBySource[call.source, default: 0]
        )
        resumeCallCountWaiters()

        let shouldBlock = call.phase == .preview
            && call.source == blockFirstPreviewSource
            && !blockedPreviewStarted
        if shouldBlock {
            blockedPreviewStarted = true
            let waiters = blockedStartWaiters
            blockedStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !blockedPreviewReleased {
                await withCheckedContinuation { blockedPreviewContinuation = $0 }
            }
        }

        activeBySource[call.source, default: 1] -= 1
        let failsAtStart = failingPreviewStarts[call.source, default: []]
            .contains(call.startMilliseconds ?? -1)
        if call.phase == .preview,
           failingPreviewSources.contains(call.source) || failsAtStart {
            throw FakeLiveTranscriptionError.finalFailure
        }
        if call.phase == .final {
            if systemicFinalFailureSources.contains(call.source) {
                throw VoxTypeClientError.timedOut(command: .transcribe)
            }
            if failingFinalSources.contains(call.source) {
                throw FakeLiveTranscriptionError.finalFailure
            }
            if remainingTransientFinalFailures[call.source, default: 0] > 0 {
                remainingTransientFinalFailures[call.source, default: 0] -= 1
                throw FakeLiveTranscriptionError.finalFailure
            }
            return "final \(call.source.rawValue) \(call.startMilliseconds ?? -1)"
        }
        return "preview \(call.source.rawValue) \(call.startMilliseconds ?? -1)"
    }

    private func resumeCallCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if recordedCalls.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }

    private static func call(
        wavURL: URL,
        engine: String
    ) throws -> RecordedLiveTranscriptionCall {
        let components = wavURL.deletingPathExtension().lastPathComponent.split(separator: "-")
        let phase: LiveTranscriptionPhase = components.first == "preview" ? .preview : .final
        let source = try #require(
            components.count > 1 ? MeetingAudioSource(rawValue: String(components[1])) : nil
        )
        let start = components.count > 2 ? Int64(components[2]) : nil
        let end = components.count > 3 ? Int64(components[3]) : nil
        let attributes = try FileManager.default.attributesOfItem(atPath: wavURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let data = try Data(contentsOf: wavURL)
        return RecordedLiveTranscriptionCall(
            phase: phase,
            source: source,
            startMilliseconds: start,
            endMilliseconds: end,
            engine: engine,
            wasOwnerOnly: owner == getuid() && permissions & 0o077 == 0,
            hadWAVHeader: data.count >= 44
                && String(data: data.prefix(4), encoding: .ascii) == "RIFF"
                && String(data: data[8..<12], encoding: .ascii) == "WAVE",
            wavDataByteCount: max(0, data.count - 44)
        )
    }
}

private actor CancellableLiveTranscriptionClient: LiveTranscriptionClient {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var wasCancelled: Bool { cancelled }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return "unexpected"
        } catch {
            cancelled = true
            throw CancellationError()
        }
    }
}

private actor CancellableFinalTranscriptionClient: LiveTranscriptionClient {
    private var finalStarted = false
    private var finalCancelled = false
    private var finalStartWaiters: [CheckedContinuation<Void, Never>] = []

    var wasCancelled: Bool { finalCancelled }

    func waitUntilFinalStarted() async {
        guard !finalStarted else { return }
        await withCheckedContinuation { finalStartWaiters.append($0) }
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        guard wavURL.lastPathComponent.hasPrefix("final-") else {
            return "preview"
        }
        finalStarted = true
        let waiters = finalStartWaiters
        finalStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return "unexpected final"
        } catch {
            finalCancelled = true
            throw CancellationError()
        }
    }
}

private final class LiveTranscriptFixture: @unchecked Sendable {
    let root: URL
    let wavDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-live-transcript-tests-\(UUID().uuidString)")
        wavDirectory = root.appendingPathComponent("wav", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func buffer(
        source: MeetingAudioSource,
        hostTimestamp: TimeInterval,
        duration: TimeInterval,
        amplitude: Float
    ) -> MeetingAudioSampleBuffer {
        let frameCount = Int((duration * Double(MeetingAudioWriter.sampleRate)).rounded())
        let samples = (0..<frameCount).map { index in
            amplitude == 0 ? 0 : (index.isMultiple(of: 2) ? amplitude : -amplitude)
        }
        return MeetingAudioSampleBuffer(
            source: source,
            sourceTimestamp: hostTimestamp * 3,
            hostTimestamp: hostTimestamp,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channelCount: MeetingAudioWriter.channelCount,
            interleavedSamples: samples
        )
    }

    func sparseBuffer(
        source: MeetingAudioSource,
        hostTimestamp: TimeInterval,
        duration: TimeInterval,
        peakAmplitude: Float
    ) -> MeetingAudioSampleBuffer {
        let frameCount = Int((duration * Double(MeetingAudioWriter.sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: frameCount)
        for index in stride(from: 0, to: frameCount, by: 480) {
            samples[index] = peakAmplitude
        }
        return MeetingAudioSampleBuffer(
            source: source,
            sourceTimestamp: hostTimestamp * 3,
            hostTimestamp: hostTimestamp,
            sampleRate: Double(MeetingAudioWriter.sampleRate),
            channelCount: MeetingAudioWriter.channelCount,
            interleavedSamples: samples
        )
    }

    func captureSummary(
        tracks specifications: [(source: MeetingAudioSource, duration: Int, start: Int64)]
    ) throws -> MeetingAudioCaptureSummary {
        var tracks: [MeetingAudioTrack] = []
        var chunks: [MeetingAudioChunk] = []
        for specification in specifications {
            let frameCount = specification.duration * MeetingAudioWriter.sampleRate
            let url = root.appendingPathComponent("\(specification.source.rawValue).pcm")
            let samples = [Float](repeating: 0.1, count: frameCount)
            let data = samples.withUnsafeBytes { Data($0) }
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw LiveTranscriptionServiceError.wavWriteFailed
            }
            tracks.append(MeetingAudioTrack(
                source: specification.source,
                fileURL: url,
                sampleRate: MeetingAudioWriter.sampleRate,
                channelCount: MeetingAudioWriter.channelCount,
                frameCount: Int64(frameCount)
            ))
            chunks.append(MeetingAudioChunk(
                source: specification.source,
                timestampMilliseconds: specification.start,
                sourceTimestamp: Double(specification.start) / 1_000,
                frameOffset: 0,
                frameCount: frameCount
            ))
        }
        return MeetingAudioCaptureSummary(
            origin: Date(timeIntervalSince1970: 1_784_201_000),
            originHostTimestamp: 0,
            tracks: tracks,
            chunks: chunks,
            discontinuities: [],
            failures: []
        )
    }

    func captureSummary(
        buffers: [MeetingAudioSampleBuffer]
    ) throws -> MeetingAudioCaptureSummary {
        let directory = root.appendingPathComponent(
            "capture-\(UUID().uuidString)",
            isDirectory: true
        )
        let writer = try MeetingAudioWriter(meetingDirectory: directory)
        for buffer in buffers {
            _ = try writer.append(buffer)
        }
        return try writer.finalize()
    }
}

private func transcriptionDirectoryIsAbsentOrEmpty(_ directory: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else { return true }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
}
