import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct DictationControllerTests {
    @Test
    func startIsListeningBeforeTheSinglePasteCommandCompletes() async throws {
        let gate = AsyncGate()
        let voxType = FakeDictationVoxType(startGate: gate)
        let controller = makeController(voxType: voxType)

        controller.handle(.start)
        #expect(controller.state == .listening)
        await eventually { await voxType.commands == [.startForPaste] }

        controller.handle(.start)
        #expect(controller.state == .listening)
        #expect(await voxType.commands == [.startForPaste])

        await gate.releaseOne()
        await controller.waitForPendingWork()
        #expect(controller.state == .listening)
        #expect(await voxType.commands == [.startForPaste])

        controller.handle(.cancel)
        await controller.waitForPendingWork()
    }

    @Test
    func holdStopStaysTranscribingUntilVoxTypeReportsIdle() async {
        let pollSleep = AsyncGate()
        let voxType = FakeDictationVoxType(statuses: [
            runtimeStatus(.transcribing),
            runtimeStatus(.idle),
        ])
        let controller = makeController(
            voxType: voxType,
            sleep: { _ in await pollSleep.wait() }
        )

        controller.handle(.start)
        await controller.waitForPendingWork()
        #expect(controller.state == .listening)

        controller.handle(.stop)
        #expect(controller.state == .transcribing)
        await eventually { await voxType.statusCount == 1 }
        #expect(controller.state == .transcribing)
        #expect(await voxType.commands == [.startForPaste, .stopForPaste])

        await pollSleep.releaseOne()
        await controller.waitForPendingWork()
        #expect(controller.state == .idle)
        #expect(await voxType.statusCount == 2)
        #expect(await voxType.commands == [.startForPaste, .stopForPaste])
    }

    @Test
    func cancelRunsExactlyOnceAndNeverUsesThePasteStopPath() async {
        let voxType = FakeDictationVoxType()
        let controller = makeController(voxType: voxType)

        controller.handle(.start)
        await controller.waitForPendingWork()
        controller.handle(.cancel)
        #expect(controller.state == .idle)
        await controller.waitForPendingWork()
        controller.handle(.cancel)

        #expect(controller.state == .idle)
        #expect(await voxType.commands == [.startForPaste, .cancel])
        #expect(await voxType.statusCount == 0)
    }

    @Test
    func meetingAudioOwnershipRejectsStartWithVisibleReason() async {
        let ownership = MutableMeetingAudioCapture(owned: true)
        let voxType = FakeDictationVoxType()
        let controller = makeController(voxType: voxType, audioCapture: ownership)

        controller.handle(.start)
        #expect(controller.state == .unavailable(.meetingOwnsAudioCapture))
        #expect(controller.canRetry)
        #expect(DictationUnavailableReason.meetingOwnsAudioCapture.title
            == "Dictation unavailable while recording")
        #expect(DictationUnavailableReason.meetingOwnsAudioCapture.detail
            == "Stop the active Meeting or Voice Note before starting dictation.")
        #expect(await voxType.commands.isEmpty)

        ownership.owned = false
        controller.retry()
        await controller.waitForPendingWork()
        #expect(controller.state == .listening)
        #expect(await voxType.commands == [.startForPaste])
        controller.handle(.cancel)
        await controller.waitForPendingWork()
    }

    @Test
    func everyFailureIsDistinctVisibleAndRetryable() async {
        let unavailable = DictationController(voxType: nil)
        unavailable.handle(.start)
        #expect(unavailable.state == .failed(.voxTypeUnavailable))
        #expect(unavailable.canRetry)

        let startFailures: [DictationFailure] = [
            .daemonStopped,
            .permissionRevoked,
            .modelMissing,
            .commandTimedOut,
        ]
        for failure in startFailures {
            let voxType = FakeDictationVoxType(startFailures: [failure])
            let controller = makeController(voxType: voxType)

            controller.handle(.start)
            await controller.waitForPendingWork()

            #expect(controller.state == .failed(failure))
            #expect(controller.canRetry)
            #expect(failure.isRetryable)
            #expect(!failure.title.isEmpty)
            #expect(!failure.detail.isEmpty)
            #expect(await voxType.commands == [.startForPaste])
        }

        let failedStop = FakeDictationVoxType(
            stopFailures: [.transcriptionFailed]
        )
        let stoppedController = makeController(voxType: failedStop)
        stoppedController.handle(.start)
        await stoppedController.waitForPendingWork()
        stoppedController.handle(.stop)
        await stoppedController.waitForPendingWork()
        #expect(stoppedController.state == .failed(.transcriptionFailed))
        #expect(stoppedController.canRetry)
        #expect(await failedStop.commands == [.startForPaste, .stopForPaste])

        let all: Set<DictationFailure> = [
            .voxTypeUnavailable,
            .daemonStopped,
            .permissionRevoked,
            .modelMissing,
            .commandTimedOut,
            .transcriptionFailed,
        ]
        #expect(all.count == 6)
    }

    @Test
    func aRetryStartsOneFreshSessionAfterFailure() async {
        let voxType = FakeDictationVoxType(startFailures: [.commandTimedOut])
        let controller = makeController(voxType: voxType)

        controller.handle(.start)
        await controller.waitForPendingWork()
        #expect(controller.state == .failed(.commandTimedOut))

        controller.retry()
        await controller.waitForPendingWork()
        #expect(controller.state == .listening)
        #expect(await voxType.commands == [.startForPaste, .startForPaste])
        controller.handle(.cancel)
        await controller.waitForPendingWork()
    }

    @Test
    func controllerUsesOnlyVoxTypesFixedStartAndStopPasteArguments() async {
        let runner = RecordingVoxTypeRunner(outputs: [
            VoxTypeProcessOutput(stdout: #"{"class":"idle"}"#),
            VoxTypeProcessOutput(),
            VoxTypeProcessOutput(stdout: #"{"class":"recording"}"#),
            VoxTypeProcessOutput(),
            VoxTypeProcessOutput(stdout: #"{"class":"idle"}"#),
        ])
        let client = VoxTypeClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/voxtype"),
            runner: runner,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/brain-dictation-tests")
        )
        let controller = makeController(voxType: client)

        controller.handle(.start)
        await controller.waitForPendingWork()
        controller.handle(.stop)
        await controller.waitForPendingWork()

        #expect(controller.state == .idle)
        #expect(await runner.arguments == [
            ["status", "--format", "json", "--extended"],
            ["record", "start", "--paste"],
            ["status", "--format", "json", "--extended"],
            ["record", "stop", "--paste"],
            ["status", "--format", "json", "--extended"],
        ])
    }

    @Test
    func controllerUsesOnlyVoxTypesNonPasteCancelArgument() async {
        let runner = RecordingVoxTypeRunner(outputs: [
            VoxTypeProcessOutput(stdout: #"{"class":"idle"}"#),
            VoxTypeProcessOutput(),
            VoxTypeProcessOutput(stdout: #"{"class":"recording"}"#),
            VoxTypeProcessOutput(),
        ])
        let client = VoxTypeClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/voxtype"),
            runner: runner,
            workingDirectoryURL: URL(fileURLWithPath: "/private/tmp/brain-dictation-tests")
        )
        let controller = makeController(voxType: client)

        controller.handle(.start)
        await controller.waitForPendingWork()
        controller.handle(.cancel)
        await controller.waitForPendingWork()

        #expect(controller.state == .idle)
        #expect(await runner.arguments == [
            ["status", "--format", "json", "--extended"],
            ["record", "start", "--paste"],
            ["status", "--format", "json", "--extended"],
            ["record", "cancel"],
        ])
    }

    @Test
    func controllerHasNoContentClipboardOrActivationPersistencePath() throws {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("DictationController.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "NSPasteboard",
            "UserDefaults",
            "FileHandle",
            "Data(contentsOf:",
            "write(to:",
            "NSApplication",
            "NSWorkspace",
            ".activate(",
        ] {
            #expect(!source.contains(forbidden))
        }
        #expect(!source.contains("var transcript"))
        #expect(!source.contains("let transcript"))
        #expect(!source.contains("var dictatedAudio"))
        #expect(!source.contains("let dictatedAudio"))
    }

    @Test
    func statusObserverMapsEventsReadsShortcutRestartsAndCancelsExactlyOnce() async {
        let voxType = ControlledStatusVoxType()
        let delays = DurationRecorder()
        let controller = makeController(
            voxType: voxType,
            sleep: { duration in delays.append(duration) }
        )

        controller.startMonitoring()
        controller.startMonitoring()
        await eventually { voxType.streamCount == 1 && controller.shortcutDescription != nil }
        #expect(controller.shortcutDescription == "Control+Fn (push-to-talk)")

        voxType.yield(runtimeStatus(.recording), to: 0)
        await eventually { controller.state == .listening }
        voxType.yield(runtimeStatus(.transcribing), to: 0)
        await eventually { controller.state == .transcribing }
        voxType.yield(.unavailable(.malformedStatus), to: 0)
        await eventually { controller.state == .failed(.transcriptionFailed) }
        voxType.yield(runtimeStatus(.idle), to: 0)
        await eventually { controller.state == .idle }

        voxType.finish(stream: 0)
        await eventually { voxType.streamCount == 2 }
        #expect(delays.values == [.milliseconds(250)])

        voxType.yield(runtimeStatus(.stopped), to: 1)
        await eventually { controller.state == .failed(.daemonStopped) }
        voxType.yield(runtimeStatus(.recording), to: 1)
        await eventually { controller.state == .listening }

        voxType.finish(stream: 1)
        await eventually { voxType.streamCount == 3 }
        voxType.finish(stream: 2)
        await eventually { voxType.streamCount == 4 }
        voxType.finish(stream: 3)
        await eventually { voxType.streamCount == 5 }
        #expect(delays.values == [
            .milliseconds(250),
            .seconds(1),
            .seconds(5),
            .seconds(5),
        ])

        controller.stopMonitoring()
        await controller.waitForMonitoringToStop()
        await eventually { voxType.cancellationCount == 1 }
        #expect(voxType.streamCount == 5)
        #expect(voxType.cancellationCount == 1)
    }

    @Test
    func continuousLockSurvivesSegmentTranscribingAndIdleUntilExplicitFinalStop() async {
        let voxType = ControlledStatusVoxType()
        let controller = makeController(voxType: voxType)
        controller.startMonitoring()
        await eventually { voxType.streamCount == 1 }

        controller.beginContinuousSession()
        #expect(controller.state == .listening)
        controller.lockContinuousSession()
        #expect(controller.state == .locked)

        voxType.yield(runtimeStatus(.transcribing), to: 0)
        await Task.yield()
        #expect(controller.state == .locked)
        voxType.yield(runtimeStatus(.idle), to: 0)
        await Task.yield()
        #expect(controller.state == .locked)

        controller.beginContinuousStop()
        #expect(controller.state == .transcribing)
        voxType.yield(runtimeStatus(.idle), to: 0)
        await eventually { controller.state == .idle }

        controller.stopMonitoring()
        await controller.waitForMonitoringToStop()
    }

    private func makeController(
        voxType: any VoxTypeControlling,
        audioCapture: any DictationAudioCaptureChecking = NoMeetingAudioCapture(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> DictationController {
        DictationController(
            voxType: voxType,
            audioCapture: audioCapture,
            sleep: sleep
        )
    }

    private func eventually(
        attempts: Int = 200,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Dictation", isDirectory: true)
    }
}

private final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Duration] = []

    var values: [Duration] { lock.withLock { storage } }
    func append(_ duration: Duration) { lock.withLock { storage.append(duration) } }
}

private final class ControlledStatusVoxType: VoxTypeControlling, VoxTypeStatusObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<VoxTypeStatus>.Continuation] = []
    private var recordedCancellations = 0

    var streamCount: Int { lock.withLock { continuations.count } }
    var cancellationCount: Int { lock.withLock { recordedCancellations } }

    func version() async throws -> VoxTypeVersion {
        VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
    }

    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(
            key: "FN",
            modifiers: ["LEFTCTRL"],
            mode: "PushToTalk"
        )
    }

    func status() async -> VoxTypeStatus { runtimeStatus(.idle) }
    func startRecordingForPaste() async throws {}
    func stopRecordingForPaste() async throws {}
    func cancelRecording() async throws {}
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }

    func statusEvents() -> AsyncStream<VoxTypeStatus> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
            continuation.onTermination = { @Sendable [weak self] reason in
                guard case .cancelled = reason, let self else { return }
                self.lock.withLock { self.recordedCancellations += 1 }
            }
        }
    }

    func yield(_ status: VoxTypeStatus, to index: Int) {
        lock.withLock {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(status)
        }
    }

    func finish(stream index: Int) {
        lock.withLock {
            guard continuations.indices.contains(index) else { return }
            continuations[index].finish()
        }
    }
}

private func runtimeStatus(_ state: VoxTypeRuntimeState) -> VoxTypeStatus {
    .available(VoxTypeStatusSnapshot(
        state: state,
        model: "small.en",
        device: "default",
        backend: "whisper"
    ))
}

private enum FakeDictationCommand: Equatable, Sendable {
    case startForPaste
    case stopForPaste
    case cancel
}

private actor FakeDictationVoxType: VoxTypeControlling {
    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
    }
    private(set) var commands: [FakeDictationCommand] = []
    private(set) var statusCount = 0
    private var statuses: [VoxTypeStatus]
    private var startFailures: [DictationFailure]
    private var stopFailures: [DictationFailure]
    private let startGate: AsyncGate?

    init(
        statuses: [VoxTypeStatus] = [],
        startFailures: [DictationFailure] = [],
        stopFailures: [DictationFailure] = [],
        startGate: AsyncGate? = nil
    ) {
        self.statuses = statuses
        self.startFailures = startFailures
        self.stopFailures = stopFailures
        self.startGate = startGate
    }

    func version() async throws -> VoxTypeVersion {
        VoxTypeVersion(major: 2, minor: 4, patch: 1, prerelease: nil)
    }

    func status() async -> VoxTypeStatus {
        statusCount += 1
        guard !statuses.isEmpty else { return runtimeStatus(.idle) }
        return statuses.removeFirst()
    }

    func startRecordingForPaste() async throws {
        commands.append(.startForPaste)
        if let startGate { await startGate.wait() }
        if !startFailures.isEmpty { throw startFailures.removeFirst() }
    }

    func stopRecordingForPaste() async throws {
        commands.append(.stopForPaste)
        if !stopFailures.isEmpty { throw stopFailures.removeFirst() }
    }

    func cancelRecording() async throws {
        commands.append(.cancel)
    }

    func transcribe(wavURL: URL, engine: String) async throws -> String {
        Issue.record("Dictation must not call meeting transcription")
        return ""
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private final class MutableMeetingAudioCapture: DictationAudioCaptureChecking,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(owned: Bool) {
        storage = owned
    }

    var owned: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var meetingOwnsAudioCapture: Bool { owned }
}

private actor RecordingVoxTypeRunner: VoxTypeProcessRunning {
    private var outputs: [VoxTypeProcessOutput]
    private var requests: [VoxTypeProcessRequest] = []

    init(outputs: [VoxTypeProcessOutput]) {
        self.outputs = outputs
    }

    var arguments: [[String]] { requests.map(\.arguments) }

    func run(_ request: VoxTypeProcessRequest) async throws -> VoxTypeProcessOutput {
        requests.append(request)
        guard !outputs.isEmpty else {
            Issue.record("Unexpected VoxType request: \(request.arguments)")
            return VoxTypeProcessOutput(exitStatus: 99)
        }
        return outputs.removeFirst()
    }
}
