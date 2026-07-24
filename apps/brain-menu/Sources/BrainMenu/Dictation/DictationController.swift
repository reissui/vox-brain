import Foundation
import Observation

enum DictationUnavailableReason: Equatable, Sendable {
    case meetingOwnsAudioCapture

    var title: String {
        switch self {
        case .meetingOwnsAudioCapture:
            "Dictation unavailable during a meeting"
        }
    }

    var detail: String {
        switch self {
        case .meetingOwnsAudioCapture:
            "Stop the meeting recording before starting dictation."
        }
    }
}

enum DictationFailure: Error, Equatable, Sendable {
    case voxTypeUnavailable
    case daemonStopped
    case permissionRevoked
    case modelMissing
    case commandTimedOut
    case transcriptionFailed

    var isRetryable: Bool { true }

    var title: String {
        switch self {
        case .voxTypeUnavailable:
            "VoxType unavailable"
        case .daemonStopped:
            "VoxType is stopped"
        case .permissionRevoked:
            "Permission required"
        case .modelMissing:
            "Dictation model missing"
        case .commandTimedOut:
            "VoxType timed out"
        case .transcriptionFailed:
            "Transcription failed"
        }
    }

    var detail: String {
        switch self {
        case .voxTypeUnavailable:
            "Install or select VoxType, then retry."
        case .daemonStopped:
            "Start the VoxType daemon, then retry."
        case .permissionRevoked:
            "Restore microphone permission, then retry."
        case .modelMissing:
            "Install the selected dictation model, then retry."
        case .commandTimedOut:
            "VoxType did not respond in time. Retry the dictation."
        case .transcriptionFailed:
            "VoxType could not finish this dictation. Retry when ready."
        }
    }
}

enum DictationState: Equatable, Sendable {
    case idle
    case listening
    case locked
    case transcribing
    case unavailable(DictationUnavailableReason)
    case failed(DictationFailure)

    var canRetry: Bool {
        switch self {
        case .unavailable, .failed:
            true
        case .idle, .listening, .locked, .transcribing:
            false
        }
    }
}

/// The meeting runtime is the source of truth for exclusive microphone
/// ownership. The dictation controller never attempts to open audio itself.
protocol DictationAudioCaptureChecking: Sendable {
    var meetingOwnsAudioCapture: Bool { get }
}

struct NoMeetingAudioCapture: DictationAudioCaptureChecking {
    let meetingOwnsAudioCapture = false
}

/// Semantic actions may be driven by explicit Brain controls. VoxType owns its
/// configured keyboard shortcut; Brain never observes or changes that shortcut.
enum DictationAction: Equatable, Sendable {
    case start
    case locked
    case stop
    case cancel
}

/// Owns only ephemeral session state. VoxType owns recording and its `--paste`
/// result; this type has no audio, text, pasteboard, or foreground-app API.
@MainActor
@Observable
final class DictationController {
    static let statusPollInterval: Duration = .milliseconds(100)
    static let reconnectDelays: [Duration] = [
        .milliseconds(250),
        .seconds(1),
        .seconds(5),
    ]

    private(set) var state: DictationState = .idle
    private(set) var shortcutDescription: String?

    @ObservationIgnored private let voxType: (any VoxTypeControlling)?
    @ObservationIgnored private let audioCapture: any DictationAudioCaptureChecking
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var terminalTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var stoppedMonitoringTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringGeneration: UInt64 = 0
    @ObservationIgnored private var continuousModeIsLocked = false

    var canRetry: Bool { state.canRetry && terminalTask == nil }

    init(
        voxType: (any VoxTypeControlling)? = try? VoxTypeClient.discover(),
        audioCapture: any DictationAudioCaptureChecking = NoMeetingAudioCapture(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.voxType = voxType
        self.audioCapture = audioCapture
        self.sleep = sleep
    }

    /// State changes are synchronous so the menu can show listening or
    /// transcribing before a VoxType process has returned.
    func handle(_ action: DictationAction) {
        switch action {
        case .start:
            beginSession()
        case .locked:
            guard state == .listening else { return }
            state = .locked
        case .stop:
            finishSession(shouldPaste: true)
        case .cancel:
            finishSession(shouldPaste: false)
        }
    }

    func retry() {
        guard canRetry else { return }
        beginSession()
    }

    func beginContinuousSession() {
        continuousModeIsLocked = false
        state = audioCapture.meetingOwnsAudioCapture
            ? .unavailable(.meetingOwnsAudioCapture)
            : .listening
    }

    func lockContinuousSession() {
        continuousModeIsLocked = true
        state = .locked
    }

    func beginContinuousStop() {
        continuousModeIsLocked = false
        state = .transcribing
    }

    func finishContinuousSession() {
        continuousModeIsLocked = false
        state = .idle
    }

    func failContinuousSession(_ failure: DictationFailure) {
        continuousModeIsLocked = false
        state = .failed(failure)
    }

    func failContinuousSession(_ reason: DictationUnavailableReason) {
        continuousModeIsLocked = false
        state = .unavailable(reason)
    }

    /// Starts one app-lifetime status observer. VoxType remains the exclusive
    /// owner of its configured keyboard shortcut and recording state.
    func startMonitoring() {
        guard monitoringTask == nil,
              let observer = voxType as? any VoxTypeStatusObserving else { return }

        monitoringGeneration &+= 1
        let observerGeneration = monitoringGeneration
        monitoringTask = Task { @MainActor [weak self, observer] in
            guard let self else { return }
            await self.monitor(observer, generation: observerGeneration)
        }
    }

    func stopMonitoring() {
        monitoringGeneration &+= 1
        let task = monitoringTask
        monitoringTask = nil
        stoppedMonitoringTask = task
        task?.cancel()
    }

    func waitForMonitoringToStop() async {
        await stoppedMonitoringTask?.value
        stoppedMonitoringTask = nil
    }

    /// Test and shutdown coordination point. It exposes no session content.
    func waitForPendingWork() async {
        while true {
            if let terminalTask {
                await terminalTask.value
                continue
            }
            if let startTask {
                _ = await startTask.value
                continue
            }
            return
        }
    }

    private func beginSession() {
        guard terminalTask == nil else { return }
        switch state {
        case .idle, .unavailable, .failed:
            break
        case .listening, .locked, .transcribing:
            return
        }

        guard !audioCapture.meetingOwnsAudioCapture else {
            state = .unavailable(.meetingOwnsAudioCapture)
            return
        }
        guard let voxType else {
            state = .failed(.voxTypeUnavailable)
            return
        }

        generation &+= 1
        let session = generation
        state = .listening
        startTask = Task { @MainActor [weak self, voxType] in
            do {
                try await voxType.startRecordingForPaste()
                guard let self, self.generation == session else { return false }
                self.startTask = nil
                return true
            } catch {
                guard let self, self.generation == session else { return false }
                self.startTask = nil
                self.state = .failed(Self.failure(for: error, phase: .start))
                return false
            }
        }
    }

    private func finishSession(shouldPaste: Bool) {
        guard terminalTask == nil else { return }
        guard state == .listening || state == .locked else { return }
        guard let voxType else {
            state = .failed(.voxTypeUnavailable)
            return
        }

        let session = generation
        let pendingStart = startTask
        state = shouldPaste ? .transcribing : .idle

        terminalTask = Task { @MainActor [weak self, voxType] in
            guard let self else { return }
            let didStart = await pendingStart?.value ?? true
            guard self.generation == session else { return }
            guard didStart else {
                self.terminalTask = nil
                return
            }

            do {
                if shouldPaste {
                    try await voxType.stopRecordingForPaste()
                    if self.monitoringTask == nil {
                        try await self.waitForVoxTypeToBecomeIdle(voxType)
                    }
                } else {
                    try await voxType.cancelRecording()
                    self.state = .idle
                }
            } catch is CancellationError {
                self.state = .failed(.voxTypeUnavailable)
            } catch {
                self.state = .failed(Self.failure(
                    for: error,
                    phase: shouldPaste ? .stop : .cancel
                ))
            }
            self.terminalTask = nil
        }
    }

    private func monitor(
        _ observer: any VoxTypeStatusObserving,
        generation observerGeneration: UInt64
    ) async {
        let shortcutTask = Task { @MainActor [weak self, voxType] in
            guard let configuration = try? await voxType?.hotkeyConfiguration(),
                  !Task.isCancelled,
                  let self,
                  self.monitoringGeneration == observerGeneration else { return }
            self.shortcutDescription = configuration.shortcutDescription
        }
        defer { shortcutTask.cancel() }

        var reconnectAttempt = 0
        while !Task.isCancelled, monitoringGeneration == observerGeneration {
            for await status in observer.statusEvents() {
                guard !Task.isCancelled,
                      monitoringGeneration == observerGeneration else { return }
                apply(status)
            }
            guard !Task.isCancelled,
                  monitoringGeneration == observerGeneration else { return }

            let delay = Self.reconnectDelays[min(
                reconnectAttempt,
                Self.reconnectDelays.count - 1
            )]
            reconnectAttempt = min(reconnectAttempt + 1, Self.reconnectDelays.count - 1)
            do {
                try await sleep(delay)
            } catch {
                return
            }
        }
    }

    private func apply(_ status: VoxTypeStatus) {
        // Meeting owns presentation and audio. Ignore concurrent VoxType noise;
        // the next event after the meeting resumes normal dictation display.
        guard !audioCapture.meetingOwnsAudioCapture else { return }

        switch status {
        case .available(let snapshot):
            if continuousModeIsLocked, snapshot.state != .stopped {
                state = .locked
                return
            }
            switch snapshot.state {
            case .idle:
                state = .idle
            case .recording, .streaming:
                state = .listening
            case .transcribing:
                state = .transcribing
            case .stopped:
                state = .failed(.daemonStopped)
            }
        case .unavailable(let reason):
            state = .failed(Self.failure(for: reason))
        }
    }

    private func waitForVoxTypeToBecomeIdle(
        _ voxType: any VoxTypeControlling
    ) async throws {
        while true {
            switch await voxType.status() {
            case .available(let snapshot):
                switch snapshot.state {
                case .idle:
                    state = .idle
                    return
                case .recording, .streaming, .transcribing:
                    try await sleep(Self.statusPollInterval)
                case .stopped:
                    throw DictationFailure.daemonStopped
                }
            case .unavailable(let reason):
                throw Self.failure(for: reason)
            }
        }
    }

    private enum CommandPhase {
        case start
        case stop
        case cancel
    }

    private static func failure(
        for error: Error,
        phase: CommandPhase
    ) -> DictationFailure {
        if let failure = error as? DictationFailure { return failure }
        if let clientError = error as? VoxTypeClientError {
            switch clientError {
            case .daemonUnavailable(let reason):
                return failure(for: reason)
            case .timedOut:
                return .commandTimedOut
            case .invalidModel:
                return .modelMissing
            case .commandFailed(let command, _):
                if command == .recordStop || phase == .stop {
                    return .transcriptionFailed
                }
                return .voxTypeUnavailable
            case .launchFailed, .invalidVersion, .invalidConfiguration, .outputTooLarge,
                 .invalidEngine, .invalidAudioFile, .invalidTranscript,
                 .invalidModelInventory, .cancelled:
                return .voxTypeUnavailable
            }
        }
        return phase == .stop ? .transcriptionFailed : .voxTypeUnavailable
    }

    private static func failure(
        for reason: VoxTypeUnavailableReason
    ) -> DictationFailure {
        switch reason {
        case .daemonNotRunning:
            .daemonStopped
        case .timedOut:
            .commandTimedOut
        case .launchFailed:
            .voxTypeUnavailable
        case .malformedStatus, .outputTooLarge:
            .transcriptionFailed
        }
    }
}
