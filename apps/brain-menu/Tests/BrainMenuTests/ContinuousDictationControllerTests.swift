import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct ContinuousDictationControllerTests {
    @Test
    func fixedShortcutStartsLocksRollsThreeTimesAndStopsExactlyOncePerSegment() async {
        let voxType = FakeContinuousVoxType()
        let statuses = ContinuousStatusBroadcaster()
        let configuration = FakeContinuousConfiguration()
        let clock = ContinuousFakeClock()
        let registrar = FakeContinuousHotkeyRegistrar()
        let dictation = DictationController(voxType: nil)
        let controller = ContinuousDictationController(
            voxType: voxType,
            statuses: statuses,
            configuration: configuration,
            dictation: dictation,
            registrar: registrar,
            rolloverSleep: { duration in try await clock.sleep(for: duration) },
            timeoutSleep: { duration in try await Task.sleep(for: duration) }
        )

        #expect(controller.startShortcut())
        #expect(registrar.registeredHotkey == .controlOptionD)
        #expect(CaptureHotkey.controlOptionD != .controlOptionB)
        #expect(controller.isShortcutRegistered)

        controller.start()
        await eventually { await voxType.commands == [.start] }
        #expect(configuration.durations == [3_600])
        await eventually { statuses.streamCount == 1 }
        statuses.yield(runtime(.recording))
        await eventually { controller.state == .locked(segment: 1) }
        #expect(dictation.state == .locked)
        await eventually { await clock.pendingSleeps == 1 }
        #expect(await clock.recordedDurations == [.seconds(55 * 60)])

        for completedSegment in 1...3 {
            await eventually { await clock.pendingSleeps > 0 }
            #expect(await clock.advance())
            let stopCount = completedSegment
            await eventually {
                await voxType.commands.filter { $0 == .stop }.count == stopCount
            }
            await eventually { statuses.streamCount == completedSegment * 2 }
            statuses.yield(runtime(.transcribing))
            statuses.yield(runtime(.idle))
            let startCount = completedSegment + 1
            await eventually {
                await voxType.commands.filter { $0 == .start }.count == startCount
            }
            await eventually { statuses.streamCount == completedSegment * 2 + 1 }
            statuses.yield(runtime(.recording))
            await eventually {
                controller.state == .locked(segment: completedSegment + 1)
            }
            #expect(dictation.state == .locked)
        }

        controller.stop()
        await eventually { await voxType.commands.filter { $0 == .stop }.count == 4 }
        await eventually { statuses.streamCount == 8 }
        statuses.yield(runtime(.transcribing))
        #expect(dictation.state == .transcribing)
        statuses.yield(runtime(.idle))
        await controller.waitForPendingOperation()

        #expect(controller.state == .idle)
        #expect(dictation.state == .idle)
        #expect(await voxType.commands == [
            .start, .stop, .start, .stop, .start, .stop, .start, .stop,
        ])
        #expect(await clock.recordedDurations.count == 4)
    }

    @Test
    func manualStopCancelsPendingRolloverAndRepeatedStopDoesNotDuplicateCommand() async {
        let voxType = FakeContinuousVoxType()
        let statuses = ContinuousStatusBroadcaster()
        let clock = ContinuousFakeClock()
        let controller = makeController(
            voxType: voxType,
            statuses: statuses,
            clock: clock
        )

        controller.start()
        await eventually { statuses.streamCount == 1 }
        statuses.yield(runtime(.recording))
        await eventually { controller.state == .locked(segment: 1) }

        controller.stop()
        controller.stop()
        await eventually { await voxType.commands == [.start, .stop] }
        await eventually { statuses.streamCount == 2 }
        statuses.yield(runtime(.idle))
        await controller.waitForPendingOperation()
        _ = await clock.advance()
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.state == .idle)
        #expect(await voxType.commands == [.start, .stop])
    }

    @Test
    func meetingOwnershipAndFailuresRemainVisibleRecoverableAndNeverOpenVoxTypeImproperly() async {
        let ownership = ContinuousMeetingOwnership(owned: true)
        let voxType = FakeContinuousVoxType()
        let statuses = ContinuousStatusBroadcaster()
        let dictation = DictationController(voxType: nil, audioCapture: ownership)
        let controller = ContinuousDictationController(
            voxType: voxType,
            statuses: statuses,
            configuration: FakeContinuousConfiguration(),
            dictation: dictation,
            audioCapture: ownership,
            registrar: FakeContinuousHotkeyRegistrar()
        )

        controller.start()
        #expect(controller.state == .unavailable(.meetingOwnsAudioCapture))
        #expect(dictation.state == .unavailable(.meetingOwnsAudioCapture))
        #expect(await voxType.commands.isEmpty)

        ownership.owned = false
        await voxType.setStartFailures([ContinuousInjectedError()])
        controller.retry()
        await controller.waitForPendingOperation()
        #expect(controller.state == .failed(.startFailed))
        #expect(controller.state.errorMessage?.isEmpty == false)

        let brokenConfiguration = FakeContinuousConfiguration(fails: true)
        let configurationController = ContinuousDictationController(
            voxType: voxType,
            statuses: statuses,
            configuration: brokenConfiguration,
            dictation: DictationController(voxType: nil),
            registrar: FakeContinuousHotkeyRegistrar()
        )
        configurationController.start()
        await configurationController.waitForPendingOperation()
        #expect(configurationController.state == .failed(.configurationFailed))

        let conflictingRegistrar = FakeContinuousHotkeyRegistrar(fails: true)
        let conflict = ContinuousDictationController(
            voxType: voxType,
            statuses: statuses,
            configuration: FakeContinuousConfiguration(),
            dictation: DictationController(voxType: nil),
            registrar: conflictingRegistrar
        )
        #expect(!conflict.startShortcut())
        #expect(conflict.state == .failed(.shortcutConflict))
        #expect(conflict.shortcutErrorMessage?.contains("Control-Option-D") == true)
    }

    @Test
    func rolloverFailureAndStopTimeoutEndInRecoverableVisibleStates() async {
        let rolloverVoxType = FakeContinuousVoxType()
        let rolloverStatuses = ContinuousStatusBroadcaster()
        let rolloverClock = ContinuousFakeClock()
        let rollover = makeController(
            voxType: rolloverVoxType,
            statuses: rolloverStatuses,
            clock: rolloverClock
        )
        rollover.start()
        await eventually { rolloverStatuses.streamCount == 1 }
        rolloverStatuses.yield(runtime(.recording))
        await eventually { rollover.state == .locked(segment: 1) }
        await rolloverVoxType.setStopFailures([ContinuousInjectedError()])
        await eventually { await rolloverClock.pendingSleeps > 0 }
        #expect(await rolloverClock.advance())
        await eventually { rollover.state == .failed(.rolloverFailed) }
        #expect(rollover.state == .failed(.rolloverFailed))
        #expect(rollover.state.errorMessage?.isEmpty == false)

        let timeoutVoxType = FakeContinuousVoxType()
        let timeoutStatuses = ContinuousStatusBroadcaster()
        let timeoutClock = ContinuousTimeoutClock()
        let timeout = ContinuousDictationController(
            voxType: timeoutVoxType,
            statuses: timeoutStatuses,
            configuration: FakeContinuousConfiguration(),
            dictation: DictationController(voxType: nil),
            registrar: FakeContinuousHotkeyRegistrar(),
            rolloverSleep: { duration in try await Task.sleep(for: duration) },
            timeoutSleep: { duration in try await timeoutClock.sleep(for: duration) }
        )
        timeout.start()
        await eventually { timeoutStatuses.streamCount == 1 }
        timeoutStatuses.yield(runtime(.recording))
        await eventually { timeout.state == .locked(segment: 1) }
        timeout.stop()
        await eventually { timeoutStatuses.streamCount == 2 }
        await eventually { await timeoutClock.callCount == 2 }
        await timeout.waitForPendingOperation()
        #expect(timeout.state == .failed(.stopTimedOut))
    }

    @Test
    func productionControllerHasNoPassiveKeyboardOrFnGestureMonitoring() throws {
        let source = try String(
            contentsOf: sourceDirectory.appendingPathComponent("ContinuousDictationController.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "addGlobalMonitorForEvents",
            "addLocalMonitorForEvents",
            "CGEventTapCreate",
            "NSEvent.add",
            "double-Fn",
        ] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains("Control-Option-D"))
        #expect(source.contains("never observes or interprets Fn"))
    }

    private func makeController(
        voxType: FakeContinuousVoxType,
        statuses: ContinuousStatusBroadcaster,
        clock: ContinuousFakeClock
    ) -> ContinuousDictationController {
        ContinuousDictationController(
            voxType: voxType,
            statuses: statuses,
            configuration: FakeContinuousConfiguration(),
            dictation: DictationController(voxType: nil),
            registrar: FakeContinuousHotkeyRegistrar(),
            rolloverSleep: { duration in try await clock.sleep(for: duration) },
            timeoutSleep: { duration in try await Task.sleep(for: duration) }
        )
    }

    private func eventually(
        attempts: Int = 5_000,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            // A bare yield can exhaust every attempt before a sibling task is
            // scheduled when the complete Swift suite is running concurrently.
            // Give the MainActor a bounded five-second wall-clock window so
            // this remains reliable after the CPU-heavy repository gates.
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition did not become true")
    }

    private func runtime(_ state: VoxTypeRuntimeState) -> VoxTypeStatus {
        .available(VoxTypeStatusSnapshot(
            state: state,
            model: SpeechEngineCatalog.englishDefaultModelID,
            device: "default",
            backend: "ONNX"
        ))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu/Dictation", isDirectory: true)
    }
}

private actor FakeContinuousVoxType: VoxTypeControlling {
    enum Command: Equatable { case start, stop, cancel }

    private(set) var commands: [Command] = []
    private var startFailures: [any Error] = []
    private var stopFailures: [any Error] = []

    func setStartFailures(_ values: [any Error]) { startFailures = values }
    func setStopFailures(_ values: [any Error]) { stopFailures = values }

    func version() async throws -> VoxTypeVersion {
        VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
    }
    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "push_to_talk")
    }
    func status() async -> VoxTypeStatus { runtimeStatus(.idle) }
    func startRecordingForPaste() async throws {
        commands.append(.start)
        if !startFailures.isEmpty { throw startFailures.removeFirst() }
    }
    func stopRecordingForPaste() async throws {
        commands.append(.stop)
        if !stopFailures.isEmpty { throw stopFailures.removeFirst() }
    }
    func cancelRecording() async throws { commands.append(.cancel) }
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }

    private func runtimeStatus(_ state: VoxTypeRuntimeState) -> VoxTypeStatus {
        .available(VoxTypeStatusSnapshot(
            state: state,
            model: SpeechEngineCatalog.englishDefaultModelID,
            device: nil,
            backend: nil
        ))
    }
}

private final class ContinuousStatusBroadcaster: VoxTypeStatusObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<VoxTypeStatus>.Continuation] = []
    private var streams = 0

    var streamCount: Int { lock.withLock { streams } }

    func statusEvents() -> AsyncStream<VoxTypeStatus> {
        return AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
                streams += 1
            }
        }
    }

    func yield(_ status: VoxTypeStatus) {
        let active = lock.withLock { continuations }
        active.forEach { $0.yield(status) }
    }
}

private final class FakeContinuousConfiguration: VoxTypeContinuousConfigurationEditing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var values: [Int] = []

    var durations: [Int] { lock.withLock { values } }

    init(fails: Bool = false) { self.fails = fails }

    func configureMaximumDuration(seconds: Int) throws {
        lock.withLock { values.append(seconds) }
        if fails { throw ContinuousInjectedError() }
    }
}

@MainActor
private final class FakeContinuousHotkeyRegistrar: CaptureHotkeyRegistering {
    private let fails: Bool
    private(set) var registeredHotkey: CaptureHotkey?

    init(fails: Bool = false) { self.fails = fails }

    func register(_ hotkey: CaptureHotkey, action: @escaping @MainActor () -> Void) throws {
        registeredHotkey = hotkey
        if fails { throw CaptureHotkeyError.shortcutUnavailable }
    }

    func unregister() { registeredHotkey = nil }
}

private actor ContinuousFakeClock {
    private(set) var recordedDurations: [Duration] = []
    private var pending: [AsyncStream<Void>.Continuation] = []
    var pendingSleeps: Int { pending.count }

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
        let stream = AsyncStream<Void> { continuation in pending.append(continuation) }
        for await _ in stream { break }
        try Task.checkCancellation()
    }

    func advance() -> Bool {
        guard !pending.isEmpty else { return false }
        let continuation = pending.removeFirst()
        continuation.yield(())
        continuation.finish()
        return true
    }
}

private actor ContinuousTimeoutClock {
    private(set) var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(for: .seconds(3_600))
        }
    }
}

private final class ContinuousMeetingOwnership: DictationAudioCaptureChecking,
    @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    var owned: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var meetingOwnsAudioCapture: Bool { owned }

    init(owned: Bool) { value = owned }
}

private struct ContinuousInjectedError: Error {}
