import Foundation
import Observation

enum ContinuousDictationFailure: Error, Equatable, LocalizedError, Sendable {
    case shortcutConflict
    case configurationFailed
    case voxTypeUnavailable
    case daemonStopped
    case startFailed
    case rolloverFailed
    case stopTimedOut
    case stopFailed

    var errorDescription: String? {
        switch self {
        case .shortcutConflict:
            "Control-Option-D is already in use. Choose another app shortcut; Brain has not changed Quick Capture or VoxType's shortcut."
        case .configurationFailed:
            "Brain could not set VoxType's maximum recording duration. Check VoxType Settings, then retry."
        case .voxTypeUnavailable:
            "VoxType is unavailable. Start VoxType, then retry continuous dictation."
        case .daemonStopped:
            "VoxType stopped during continuous dictation. Start VoxType, then retry."
        case .startFailed:
            "VoxType could not start continuous dictation. Retry when VoxType is ready."
        case .rolloverFailed:
            "Brain could not continue the next dictation segment. The completed segment is safe; retry to continue."
        case .stopTimedOut:
            "VoxType did not finish transcribing in time. Check VoxType, then retry."
        case .stopFailed:
            "VoxType could not finish continuous dictation. Check VoxType, then retry."
        }
    }
}

enum ContinuousDictationState: Equatable, Sendable {
    case idle
    case starting
    case locked(segment: Int)
    case stopping
    case unavailable(DictationUnavailableReason)
    case failed(ContinuousDictationFailure)

    var isActive: Bool {
        switch self {
        case .starting, .locked, .stopping:
            true
        case .idle, .unavailable, .failed:
            false
        }
    }

    var errorMessage: String? {
        switch self {
        case .unavailable(let reason): reason.title
        case .failed(let failure): failure.localizedDescription
        case .idle, .starting, .locked, .stopping: nil
        }
    }
}

/// Owns the explicit privacy-compatible continuous mode. It registers only
/// Control-Option-D through Carbon and never observes or interprets Fn events.
/// VoxType remains the sole audio and paste owner.
@MainActor
@Observable
final class ContinuousDictationController {
    static let hotkey = CaptureHotkey.controlOptionD
    static let shortcutDescription = "Control-Option-D"
    static let maximumDurationSeconds = 3_600
    static let rolloverInterval: Duration = .seconds(55 * 60)
    static let statusTimeout: Duration = .seconds(30)

    private(set) var state: ContinuousDictationState = .idle
    private(set) var isShortcutRegistered = false
    private(set) var shortcutErrorMessage: String?

    @ObservationIgnored private let voxType: (any VoxTypeControlling)?
    @ObservationIgnored private let statuses: (any VoxTypeStatusObserving)?
    @ObservationIgnored private let configuration: any VoxTypeContinuousConfigurationEditing
    @ObservationIgnored private let dictation: DictationController
    @ObservationIgnored private let audioCapture: any DictationAudioCaptureChecking
    @ObservationIgnored private let registrar: any CaptureHotkeyRegistering
    @ObservationIgnored private let rolloverSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let timeoutSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var rolloverTask: Task<Void, Never>?
    @ObservationIgnored private var segmentIsRecording = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var sessionGeneration: UInt64 = 0

    init(
        voxType: (any VoxTypeControlling)?,
        statuses: (any VoxTypeStatusObserving)?,
        configuration: any VoxTypeContinuousConfigurationEditing = VoxTypeConfigurationEditor(),
        dictation: DictationController,
        audioCapture: any DictationAudioCaptureChecking = NoMeetingAudioCapture(),
        registrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(identifier: 2),
        rolloverSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.voxType = voxType
        self.statuses = statuses
        self.configuration = configuration
        self.dictation = dictation
        self.audioCapture = audioCapture
        self.registrar = registrar
        self.rolloverSleep = rolloverSleep
        self.timeoutSleep = timeoutSleep
    }

    @discardableResult
    func startShortcut() -> Bool {
        do {
            try registrar.register(Self.hotkey) { [weak self] in self?.toggle() }
            isShortcutRegistered = true
            shortcutErrorMessage = nil
            if case .failed(.shortcutConflict) = state { state = .idle }
            return true
        } catch {
            isShortcutRegistered = false
            shortcutErrorMessage = ContinuousDictationFailure.shortcutConflict.localizedDescription
            state = .failed(.shortcutConflict)
            return false
        }
    }

    func stopShortcut() {
        registrar.unregister()
        isShortcutRegistered = false
        rolloverTask?.cancel()
        rolloverTask = nil
    }

    func toggle() {
        state.isActive ? stop() : start()
    }

    func start() {
        guard !state.isActive, operationTask == nil else { return }
        guard !audioCapture.meetingOwnsAudioCapture else {
            state = .unavailable(.meetingOwnsAudioCapture)
            dictation.beginContinuousSession()
            dictation.failContinuousSession(.meetingOwnsAudioCapture)
            return
        }
        guard let voxType, let statuses else {
            fail(.voxTypeUnavailable)
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        stopRequested = false
        segmentIsRecording = false
        state = .starting
        dictation.beginContinuousSession()
        launchOperation { [weak self, voxType, statuses] in
            guard let self else { return }
            do {
                try self.configuration.configureMaximumDuration(
                    seconds: Self.maximumDurationSeconds
                )
            } catch {
                self.fail(.configurationFailed)
                return
            }

            do {
                try await voxType.startRecordingForPaste()
                self.segmentIsRecording = true
                if self.stopRequested {
                    await self.finishManually(voxType: voxType, statuses: statuses)
                    return
                }
                try await self.waitForRecording(statuses)
                guard self.sessionGeneration == generation else { return }
                if self.stopRequested {
                    await self.finishManually(voxType: voxType, statuses: statuses)
                    return
                }
                self.lock(segment: 1, generation: generation)
            } catch {
                self.fail(self.failure(for: error, during: .start))
            }
        }
    }

    func stop() {
        guard state.isActive else { return }
        stopRequested = true
        rolloverTask?.cancel()
        rolloverTask = nil
        guard operationTask == nil, let voxType, let statuses else { return }
        launchOperation { [weak self, voxType, statuses] in
            await self?.finishManually(voxType: voxType, statuses: statuses)
        }
    }

    func retry() {
        guard !state.isActive else { return }
        start()
    }

    func waitForPendingOperation() async {
        while let task = operationTask { await task.value }
    }

    private func lock(segment: Int, generation: UInt64) {
        guard !stopRequested, sessionGeneration == generation else { return }
        state = .locked(segment: segment)
        dictation.lockContinuousSession()
        scheduleRollover(after: segment, generation: generation)
    }

    private func scheduleRollover(after segment: Int, generation: UInt64) {
        rolloverTask?.cancel()
        rolloverTask = Task { @MainActor [weak self, rolloverSleep] in
            do {
                try await rolloverSleep(Self.rolloverInterval)
            } catch {
                return
            }
            // `lock` schedules the next rollover immediately before the
            // current start/rollover operation releases its serialization
            // slot. A fake clock can advance at that exact boundary, so wait
            // for the slot instead of losing the rollover.
            while self?.operationTask != nil, !Task.isCancelled {
                await Task.yield()
            }
            guard let self,
                  !Task.isCancelled,
                  !self.stopRequested,
                  self.sessionGeneration == generation,
                  let voxType = self.voxType,
                  let statuses = self.statuses else { return }
            self.rolloverTask = nil
            self.launchOperation { [weak self, voxType, statuses] in
                await self?.rollover(
                    completedSegment: segment,
                    generation: generation,
                    voxType: voxType,
                    statuses: statuses
                )
            }
        }
    }

    private func rollover(
        completedSegment: Int,
        generation: UInt64,
        voxType: any VoxTypeControlling,
        statuses: any VoxTypeStatusObserving
    ) async {
        do {
            guard segmentIsRecording else { throw ContinuousDictationFailure.rolloverFailed }
            try await voxType.stopRecordingForPaste()
            segmentIsRecording = false
            try await waitForIdle(statuses)
            guard sessionGeneration == generation else { return }
            if stopRequested {
                finishWithoutRecording()
                return
            }

            try await voxType.startRecordingForPaste()
            segmentIsRecording = true
            if stopRequested {
                await finishManually(voxType: voxType, statuses: statuses)
                return
            }
            try await waitForRecording(statuses)
            guard sessionGeneration == generation else { return }
            if stopRequested {
                await finishManually(voxType: voxType, statuses: statuses)
                return
            }
            lock(segment: completedSegment + 1, generation: generation)
        } catch {
            fail(failure(for: error, during: .rollover))
        }
    }

    private func finishManually(
        voxType: any VoxTypeControlling,
        statuses: any VoxTypeStatusObserving
    ) async {
        rolloverTask?.cancel()
        rolloverTask = nil
        state = .stopping
        dictation.beginContinuousStop()
        do {
            if segmentIsRecording {
                // Clear before awaiting so re-entrant Stop actions cannot issue
                // a duplicate command for this segment.
                segmentIsRecording = false
                try await voxType.stopRecordingForPaste()
            }
            try await waitForIdle(statuses)
            finishWithoutRecording()
        } catch {
            fail(failure(for: error, during: .stop))
        }
    }

    private func finishWithoutRecording() {
        rolloverTask?.cancel()
        rolloverTask = nil
        stopRequested = false
        segmentIsRecording = false
        state = .idle
        dictation.finishContinuousSession()
    }

    private func fail(_ failure: ContinuousDictationFailure) {
        sessionGeneration &+= 1
        rolloverTask?.cancel()
        rolloverTask = nil
        stopRequested = false
        segmentIsRecording = false
        state = .failed(failure)
        dictation.failContinuousSession(Self.dictationFailure(for: failure))
    }

    private func launchOperation(_ operation: @escaping @MainActor () async -> Void) {
        guard operationTask == nil else { return }
        operationTask = Task { @MainActor [weak self] in
            await operation()
            guard let self else { return }
            self.operationTask = nil
            if self.stopRequested,
               self.state.isActive,
               let voxType = self.voxType,
               let statuses = self.statuses {
                self.launchOperation { [weak self, voxType, statuses] in
                    await self?.finishManually(voxType: voxType, statuses: statuses)
                }
            }
        }
    }

    private func waitForRecording(_ observer: any VoxTypeStatusObserving) async throws {
        try await waitForStatus(observer) { snapshot in
            snapshot.state == .recording || snapshot.state == .streaming
        }
    }

    private func waitForIdle(_ observer: any VoxTypeStatusObserving) async throws {
        try await waitForStatus(observer) { $0.state == .idle }
    }

    private func waitForStatus(
        _ observer: any VoxTypeStatusObserving,
        matching predicate: @escaping @Sendable (VoxTypeStatusSnapshot) -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await status in observer.statusEvents() {
                    try Task.checkCancellation()
                    switch status {
                    case .available(let snapshot):
                        if predicate(snapshot) { return }
                        if snapshot.state == .stopped {
                            throw ContinuousDictationFailure.daemonStopped
                        }
                    case .unavailable:
                        throw ContinuousDictationFailure.daemonStopped
                    }
                }
                throw ContinuousDictationFailure.daemonStopped
            }
            group.addTask { [timeoutSleep] in
                try await timeoutSleep(Self.statusTimeout)
                throw ContinuousDictationFailure.stopTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private enum Phase { case start, rollover, stop }

    private func failure(for error: Error, during phase: Phase) -> ContinuousDictationFailure {
        if let failure = error as? ContinuousDictationFailure {
            if failure == .stopTimedOut, phase == .stop { return .stopTimedOut }
            if failure == .daemonStopped { return .daemonStopped }
        }
        if let client = error as? VoxTypeClientError {
            switch client {
            case .timedOut:
                return phase == .stop ? .stopTimedOut : phase == .rollover ? .rolloverFailed : .startFailed
            case .daemonUnavailable:
                return .daemonStopped
            default:
                break
            }
        }
        return switch phase {
        case .start: ContinuousDictationFailure.startFailed
        case .rollover: ContinuousDictationFailure.rolloverFailed
        case .stop: ContinuousDictationFailure.stopFailed
        }
    }

    private static func dictationFailure(
        for failure: ContinuousDictationFailure
    ) -> DictationFailure {
        switch failure {
        case .daemonStopped: .daemonStopped
        case .stopTimedOut: .commandTimedOut
        case .stopFailed, .rolloverFailed: .transcriptionFailed
        case .shortcutConflict, .configurationFailed, .voxTypeUnavailable, .startFailed:
            .voxTypeUnavailable
        }
    }
}
