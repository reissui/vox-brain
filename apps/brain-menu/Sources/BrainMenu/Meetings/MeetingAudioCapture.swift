import AppKit
import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct MeetingMicrophoneDevice: Equatable, Identifiable, Sendable {
    /// Core Audio's persistent device UID, not the process-local AudioDeviceID.
    let id: String
    let name: String
    let coreAudioID: AudioDeviceID
    let isSystemDefault: Bool
}

enum MeetingMicrophoneSelection: Equatable, Hashable, Sendable {
    case systemDefault
    case device(uid: String)

    var persistedValue: String? {
        if case .device(let uid) = self { return uid }
        return nil
    }
}

struct MeetingMicrophoneInventorySnapshot: Equatable, Sendable {
    let devices: [MeetingMicrophoneDevice]
    let defaultDeviceUID: String?

    func deviceID(for selection: MeetingMicrophoneSelection) throws -> AudioDeviceID? {
        switch selection {
        case .systemDefault:
            guard let defaultDeviceUID,
                  let device = devices.first(where: { $0.id == defaultDeviceUID }) else {
                throw NativeMeetingAudioSourceError.unavailable
            }
            return device.coreAudioID
        case .device(let uid):
            guard let device = devices.first(where: { $0.id == uid }) else {
                throw NativeMeetingAudioSourceError.unavailable
            }
            return device.coreAudioID
        }
    }
}

protocol MeetingMicrophoneInventoryProviding: Sendable {
    func snapshot() throws -> MeetingMicrophoneInventorySnapshot
}

struct CoreAudioMeetingMicrophoneInventory: MeetingMicrophoneInventoryProviding {
    func snapshot() throws -> MeetingMicrophoneInventorySnapshot {
        let deviceIDs: [AudioDeviceID] = try Self.arrayProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let defaultID: AudioDeviceID? = try? Self.scalarProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let devices = deviceIDs.compactMap { deviceID -> MeetingMicrophoneDevice? in
            let streams: [AudioStreamID] = (try? Self.arrayProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput
            )) ?? []
            guard !streams.isEmpty else { return nil }
            guard let uid = try? Self.stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ), let name = try? Self.stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            ) else { return nil }
            return MeetingMicrophoneDevice(
                id: uid,
                name: name,
                coreAudioID: deviceID,
                isSystemDefault: deviceID == defaultID
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return MeetingMicrophoneInventorySnapshot(
            devices: devices,
            defaultDeviceUID: devices.first(where: \.isSystemDefault)?.id
        )
    }

    private static func scalarProperty<T: FixedWidthInteger>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        return value
    }

    private static func arrayProperty<T: FixedWidthInteger>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        guard size > 0 else { return [] }
        var values = [T](repeating: 0, count: Int(size) / MemoryLayout<T>.size)
        guard values.withUnsafeMutableBytes({ bytes in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bytes.baseAddress!)
        }) == noErr else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        return values
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        guard let value else { throw NativeMeetingAudioSourceError.configurationFailed }
        return value.takeUnretainedValue() as String
    }
}

final class MeetingMicrophoneSelectionStore: @unchecked Sendable {
    static let defaultsKey = "meeting.microphone.deviceUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selection: MeetingMicrophoneSelection {
        guard let uid = defaults.string(forKey: Self.defaultsKey), !uid.isEmpty else {
            return .systemDefault
        }
        return .device(uid: uid)
    }

    func select(_ selection: MeetingMicrophoneSelection) {
        if let value = selection.persistedValue {
            defaults.set(value, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

protocol MeetingMicrophoneSettingsServing: Sendable {
    func inventory() async throws -> MeetingMicrophoneInventorySnapshot
    func test(
        selection: MeetingMicrophoneSelection,
        duration: Duration,
        levelHandler: @escaping @Sendable (Float) -> Void
    ) async -> SpeechHardwareTestResult
}

struct SystemMeetingMicrophoneService: MeetingMicrophoneSettingsServing {
    private let inventoryProvider: any MeetingMicrophoneInventoryProviding

    init(
        inventoryProvider: any MeetingMicrophoneInventoryProviding = CoreAudioMeetingMicrophoneInventory()
    ) {
        self.inventoryProvider = inventoryProvider
    }

    func inventory() async throws -> MeetingMicrophoneInventorySnapshot {
        try inventoryProvider.snapshot()
    }

    func test(
        selection: MeetingMicrophoneSelection,
        duration: Duration,
        levelHandler: @escaping @Sendable (Float) -> Void
    ) async -> SpeechHardwareTestResult {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        guard granted else {
            return .failed("Microphone access is off. Allow Brain in System Settings → Privacy & Security → Microphone, then test again.")
        }

        let observation = MeetingMicrophoneTestObservation(levelHandler: levelHandler)
        let source = AVAudioEngineMeetingAudioSource(
            selection: selection,
            inventory: inventoryProvider
        )
        do {
            try await source.start { event in observation.receive(event) }
            do {
                try await Task.sleep(for: duration)
            } catch {
                await source.stop()
                return .failed("Microphone test was cancelled.")
            }
            await source.stop()
        } catch {
            await source.stop()
            return .failed(error.localizedDescription)
        }

        if let failure = observation.failure {
            return .failed(failure)
        }
        guard observation.receivedFrames else {
            return .failed("No microphone frames arrived. Check the selected input device, reconnect it if needed, and test again.")
        }
        guard observation.maximumRMS >= MeetingMicrophoneReadiness.audibleRMS else {
            return .failed("Microphone frames arrived but no voice signal was detected. Check the input level and selected device, then test again.")
        }
        return .ready("Voice detected on the selected microphone during the five-second test.")
    }
}

private final class MeetingMicrophoneTestObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let levelHandler: @Sendable (Float) -> Void
    private var state = State()

    init(levelHandler: @escaping @Sendable (Float) -> Void) {
        self.levelHandler = levelHandler
    }

    var receivedFrames: Bool { lock.withLock { state.receivedFrames } }
    var maximumRMS: Float { lock.withLock { state.maximumRMS } }
    var failure: String? { lock.withLock { state.failure } }

    func receive(_ event: MeetingAudioSourceEvent) {
        switch event {
        case .samples(let buffer):
            guard !buffer.interleavedSamples.isEmpty else { return }
            let squareSum = buffer.interleavedSamples.reduce(0.0) {
                $0 + Double($1) * Double($1)
            }
            let rms = Float(sqrt(squareSum / Double(buffer.interleavedSamples.count)))
            lock.withLock {
                state.receivedFrames = true
                state.maximumRMS = max(state.maximumRMS, rms)
            }
            levelHandler(min(max(rms, 0), 1))
        case .failure(let value):
            lock.withLock { state.failure = value.message }
        case .discontinuity:
            break
        }
    }

    private struct State {
        var receivedFrames = false
        var maximumRMS: Float = 0
        var failure: String?
    }
}

struct MeetingAudioSourceDiscontinuity: Equatable, Sendable {
    let reason: MeetingAudioDiscontinuityReason
    let sourceTimestamp: TimeInterval?
    let hostTimestamp: TimeInterval
    let detail: String?

    init(
        reason: MeetingAudioDiscontinuityReason,
        sourceTimestamp: TimeInterval? = nil,
        hostTimestamp: TimeInterval,
        detail: String? = nil
    ) {
        self.reason = reason
        self.sourceTimestamp = sourceTimestamp
        self.hostTimestamp = hostTimestamp
        self.detail = detail
    }
}

struct MeetingAudioSourceFailure: Equatable, Sendable {
    let reason: MeetingAudioFailureReason
    let hostTimestamp: TimeInterval
    let message: String
}

enum MeetingAudioSourceEvent: Equatable, Sendable {
    case samples(MeetingAudioSampleBuffer)
    case discontinuity(MeetingAudioSourceDiscontinuity)
    case failure(MeetingAudioSourceFailure)
}

protocol MeetingAudioSourceCapturing: Sendable {
    var source: MeetingAudioSource { get }

    func start(
        eventHandler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void
    ) async throws
    func stop() async
}

enum MeetingAudioCaptureEvent: Equatable, Sendable {
    case level(MeetingAudioLevel)
    case warning(MeetingAudioWarning)
    case discontinuity(MeetingAudioDiscontinuity)
    case failure(MeetingAudioFailure)
}

struct MeetingAudioWarning: Equatable, Sendable {
    let source: MeetingAudioSource
    let message: String
}

enum MeetingAudioCaptureError: Error, Equatable, LocalizedError, Sendable {
    case invalidSources
    case sourceStartFailed(MeetingAudioSource, MeetingAudioFailureReason)
    case microphoneNotReady
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .invalidSources:
            "Meeting capture requires one microphone source and one system-audio source."
        case .sourceStartFailed(let source, _):
            "The \(source.rawValue) audio source could not start."
        case .microphoneNotReady:
            "No microphone audio arrived within three seconds. Check the selected input device and microphone permission, then try again."
        case .emptyCapture:
            "The meeting ended without any microphone or system audio."
        }
    }
}

/// Coordinates two injected sources. Native adapters are used in the app;
/// deterministic sources can exercise the exact same path without hardware.
final class MeetingAudioCapture: @unchecked Sendable {
    private let systemAudio: any MeetingAudioSourceCapturing
    private let microphone: any MeetingAudioSourceCapturing
    private let writer: MeetingAudioWriter
    private let eventHandler: @Sendable (MeetingAudioCaptureEvent) -> Void
    private let microphoneReadinessTimeout: Duration?
    private let microphoneReadiness = MeetingMicrophoneReadiness()

    init(
        systemAudio: any MeetingAudioSourceCapturing,
        microphone: any MeetingAudioSourceCapturing,
        writer: MeetingAudioWriter,
        microphoneReadinessTimeout: Duration? = .seconds(3),
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void = { _ in }
    ) throws {
        guard systemAudio.source == .system, microphone.source == .microphone else {
            throw MeetingAudioCaptureError.invalidSources
        }
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.writer = writer
        self.microphoneReadinessTimeout = microphoneReadinessTimeout
        self.eventHandler = eventHandler
    }

    func start() async throws {
        do {
            try await systemAudio.start { [weak self] event in
                self?.receive(event, from: .system)
            }
        } catch {
            let reason = Self.failureReason(for: error)
            reportStartFailure(source: .system, reason: reason, error: error)
            throw MeetingAudioCaptureError.sourceStartFailed(.system, reason)
        }

        do {
            try await microphone.start { [weak self] event in
                self?.receive(event, from: .microphone)
            }
        } catch {
            await systemAudio.stop()
            let reason = Self.failureReason(for: error)
            reportStartFailure(source: .microphone, reason: reason, error: error)
            throw MeetingAudioCaptureError.sourceStartFailed(.microphone, reason)
        }

        guard let microphoneReadinessTimeout else { return }
        do {
            let result = try await microphoneReadiness.wait(timeout: microphoneReadinessTimeout)
            switch result {
            case .signalDetected:
                break
            case .flatSignal:
                eventHandler(.warning(MeetingAudioWarning(
                    source: .microphone,
                    message: "No usable microphone signal was detected yet. Check the selected input and its input level; recording will continue while Brain listens for it."
                )))
            case .noFrames:
                eventHandler(.warning(MeetingAudioWarning(
                    source: .microphone,
                    message: "No microphone audio has arrived yet. Check the selected input and microphone permission; recording will continue while Brain listens for it."
                )))
            }
        } catch {
            await microphone.stop()
            await systemAudio.stop()
            reportStartFailure(source: .microphone, reason: .sourceUnavailable, error: error)
            throw error
        }
    }

    func stop() async throws -> MeetingAudioCaptureSummary {
        await microphone.stop()
        await systemAudio.stop()
        do {
            return try writer.finalize()
        } catch MeetingAudioWriterError.emptyCapture {
            let failure = MeetingAudioFailure(
                source: nil,
                timestampMilliseconds: 0,
                reason: .emptyCapture,
                message: MeetingAudioWriterError.emptyCapture.localizedDescription
            )
            eventHandler(.failure(failure))
            throw MeetingAudioCaptureError.emptyCapture
        }
    }

    private func receive(_ event: MeetingAudioSourceEvent, from source: MeetingAudioSource) {
        switch event {
        case .samples(let buffer):
            guard buffer.source == source else {
                reportFailure(
                    source: source,
                    reason: .sourceFailed,
                    hostTimestamp: buffer.hostTimestamp,
                    message: "The source emitted audio with the wrong source identifier."
                )
                return
            }
            if source == .microphone { microphoneReadiness.receive(buffer) }
            do {
                if let level = try writer.append(buffer).level {
                    eventHandler(.level(level))
                }
            } catch {
                reportFailure(
                    source: source,
                    reason: .writerFailed,
                    hostTimestamp: buffer.hostTimestamp,
                    message: error.localizedDescription
                )
            }

        case .discontinuity(let signal):
            do {
                let discontinuity = try writer.recordDiscontinuity(
                    source: source,
                    reason: signal.reason,
                    sourceTimestamp: signal.sourceTimestamp,
                    hostTimestamp: signal.hostTimestamp,
                    detail: signal.detail
                )
                eventHandler(.discontinuity(discontinuity))
            } catch {
                reportFailure(
                    source: source,
                    reason: .writerFailed,
                    hostTimestamp: signal.hostTimestamp,
                    message: error.localizedDescription
                )
            }

        case .failure(let signal):
            if source == .microphone {
                microphoneReadiness.fail(reason: signal.reason, message: signal.message)
            }
            _ = try? writer.recordDiscontinuity(
                source: source,
                reason: signal.reason == .permissionRevoked ? .permissionRevoked : .sourceFailure,
                hostTimestamp: signal.hostTimestamp,
                detail: signal.message
            )
            reportFailure(
                source: source,
                reason: signal.reason,
                hostTimestamp: signal.hostTimestamp,
                message: signal.message
            )
        }
    }

    private func reportStartFailure(
        source: MeetingAudioSource,
        reason: MeetingAudioFailureReason,
        error: Error
    ) {
        reportFailure(
            source: source,
            reason: reason,
            hostTimestamp: ProcessInfo.processInfo.systemUptime,
            message: error.localizedDescription
        )
    }

    private func reportFailure(
        source: MeetingAudioSource?,
        reason: MeetingAudioFailureReason,
        hostTimestamp: TimeInterval,
        message: String
    ) {
        let failure = (try? writer.recordFailure(
            source: source,
            reason: reason,
            hostTimestamp: hostTimestamp,
            message: message
        )) ?? MeetingAudioFailure(
            source: source,
            timestampMilliseconds: 0,
            reason: reason,
            message: message
        )
        eventHandler(.failure(failure))
    }

    private static func failureReason(for error: Error) -> MeetingAudioFailureReason {
        guard let native = error as? NativeMeetingAudioSourceError else {
            return .sourceFailed
        }
        return switch native {
        case .permissionDenied: MeetingAudioFailureReason.permissionDenied
        case .unavailable: MeetingAudioFailureReason.sourceUnavailable
        case .configurationFailed, .startFailed: MeetingAudioFailureReason.sourceFailed
        }
    }
}

enum MeetingMicrophoneReadinessResult: Equatable, Sendable {
    case signalDetected
    case flatSignal
    case noFrames
}

/// The system stream cannot satisfy this gate. Microphone frames and signal
/// level are tracked independently so a working speaker feed never masks a
/// missing local voice track.
final class MeetingMicrophoneReadiness: @unchecked Sendable {
    static let audibleRMS: Float = 0.001

    private let lock = NSLock()
    private var receivedFrames = false
    private var maximumRMS: Float = 0
    private var failure: MeetingAudioCaptureError?

    func receive(_ buffer: MeetingAudioSampleBuffer) {
        guard buffer.source == .microphone, !buffer.interleavedSamples.isEmpty else { return }
        let squareSum = buffer.interleavedSamples.reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        let rms = Float(sqrt(squareSum / Double(buffer.interleavedSamples.count)))
        lock.withLock {
            receivedFrames = true
            maximumRMS = max(maximumRMS, rms)
        }
    }

    func fail(reason: MeetingAudioFailureReason, message _: String) {
        lock.withLock {
            failure = .sourceStartFailed(.microphone, reason)
        }
    }

    func wait(timeout: Duration) async throws -> MeetingMicrophoneReadinessResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let state = lock.withLock { (receivedFrames, maximumRMS, failure) }
            if let failure = state.2 { throw failure }
            if state.0, state.1 >= Self.audibleRMS { return .signalDetected }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = lock.withLock { (receivedFrames, maximumRMS, failure) }
        if let failure = state.2 { throw failure }
        guard state.0 else { return .noFrames }
        return state.1 >= Self.audibleRMS ? .signalDetected : .flatSignal
    }
}

enum NativeMeetingAudioSourceError: Error, LocalizedError, Sendable {
    case permissionDenied
    case unavailable
    case configurationFailed
    case startFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "macOS has not granted the required audio-recording permission."
        case .unavailable:
            "The requested audio source is unavailable."
        case .configurationFailed:
            "The audio source could not be configured."
        case .startFailed:
            "The audio source could not start."
        }
    }
}

enum ScreenCaptureKitAudioClockAlignment {
    static func sourceTimestamp(
        presentationTime: CMTime,
        fallbackHostTimestamp: TimeInterval
    ) -> TimeInterval {
        let fallback = fallbackHostTimestamp.isFinite ? max(0, fallbackHostTimestamp) : 0
        guard presentationTime.isValid,
              presentationTime.isNumeric,
              presentationTime.seconds.isFinite,
              presentationTime.seconds >= 0 else {
            return fallback
        }
        return presentationTime.seconds
    }

    static func hostTimestamp(
        presentationTime: CMTime,
        callbackHostTimestamp: TimeInterval,
        duration: TimeInterval,
        convertToHostTime: (CMTime) -> CMTime?
    ) -> TimeInterval {
        let safeCallbackTimestamp = callbackHostTimestamp.isFinite
            ? max(0, callbackHostTimestamp)
            : 0
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let fallback = max(0, safeCallbackTimestamp - safeDuration)

        guard presentationTime.isValid,
              presentationTime.isNumeric,
              presentationTime.seconds.isFinite,
              presentationTime.seconds >= 0,
              let converted = convertToHostTime(presentationTime),
              converted.isValid,
              converted.isNumeric,
              converted.seconds.isFinite,
              converted.seconds >= 0 else {
            return fallback
        }
        return converted.seconds
    }
}

/// Captures the complete display audio mix. No `.screen` output is installed,
/// and Brain is excluded both in the content filter and stream configuration.
final class ScreenCaptureKitMeetingAudioSource: NSObject,
    MeetingAudioSourceCapturing,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    let source: MeetingAudioSource = .system

    private let queue = DispatchQueue(label: "app.brain.meeting-audio.system")
    private let lock = NSLock()
    private var stream: SCStream?
    private var eventHandler: (@Sendable (MeetingAudioSourceEvent) -> Void)?
    private var lastSampleRate: Double?
    private var environmentObservers: MeetingAudioEnvironmentObservers?

    func start(
        eventHandler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void
    ) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw NativeMeetingAudioSourceError.permissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw NativeMeetingAudioSourceError.permissionDenied
        }
        guard let display = content.displays.first else {
            throw NativeMeetingAudioSourceError.unavailable
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter {
            $0.processID == getpid()
                || (ownBundleIdentifier != nil && $0.bundleIdentifier == ownBundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = false
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        } catch {
            throw NativeMeetingAudioSourceError.configurationFailed
        }

        let observers = MeetingAudioEnvironmentObservers(source: .system, handler: eventHandler)
        lock.withLock {
            self.eventHandler = eventHandler
            self.stream = stream
            environmentObservers = observers
        }
        observers.start()

        do {
            try await stream.startCapture()
        } catch {
            observers.stop()
            lock.withLock {
                self.stream = nil
                self.eventHandler = nil
                environmentObservers = nil
            }
            throw NativeMeetingAudioSourceError.startFailed
        }
    }

    func stop() async {
        let values = lock.withLock { () -> (SCStream?, MeetingAudioEnvironmentObservers?) in
            let values = (stream, environmentObservers)
            stream = nil
            eventHandler = nil
            environmentObservers = nil
            lastSampleRate = nil
            return values
        }
        values.1?.stop()
        try? await values.0?.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let callbackHostTimestamp = ProcessInfo.processInfo.systemUptime
        do {
            let extracted = try Self.extract(sampleBuffer)
            let presentationTime = sampleBuffer.presentationTimeStamp
            let duration = Double(extracted.samples.count / extracted.channelCount)
                / extracted.sampleRate
            let hostTimestamp = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
                presentationTime: presentationTime,
                callbackHostTimestamp: callbackHostTimestamp,
                duration: duration
            ) { presentationTime in
                guard let synchronizationClock = stream.synchronizationClock else { return nil }
                return CMSyncConvertTime(
                    presentationTime,
                    from: synchronizationClock,
                    to: CMClockGetHostTimeClock()
                )
            }
            let sourceTimestamp = ScreenCaptureKitAudioClockAlignment.sourceTimestamp(
                presentationTime: presentationTime,
                fallbackHostTimestamp: hostTimestamp
            )

            let priorRate = lock.withLock { () -> Double? in
                defer { lastSampleRate = extracted.sampleRate }
                return lastSampleRate
            }
            if let priorRate, abs(priorRate - extracted.sampleRate) > 0.001 {
                emit(.discontinuity(MeetingAudioSourceDiscontinuity(
                    reason: .sampleRateChanged,
                    sourceTimestamp: sourceTimestamp,
                    hostTimestamp: hostTimestamp,
                    detail: "System audio changed from \(priorRate) Hz to \(extracted.sampleRate) Hz."
                )))
            }
            emit(.samples(MeetingAudioSampleBuffer(
                source: .system,
                sourceTimestamp: sourceTimestamp,
                hostTimestamp: hostTimestamp,
                sampleRate: extracted.sampleRate,
                channelCount: extracted.channelCount,
                interleavedSamples: extracted.samples
            )))
        } catch {
            emit(.failure(MeetingAudioSourceFailure(
                reason: .sourceFailed,
                hostTimestamp: ProcessInfo.processInfo.systemUptime,
                message: error.localizedDescription
            )))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let revoked = !CGPreflightScreenCaptureAccess()
        let hostTimestamp = ProcessInfo.processInfo.systemUptime
        if revoked {
            emit(.discontinuity(MeetingAudioSourceDiscontinuity(
                reason: .permissionRevoked,
                hostTimestamp: hostTimestamp,
                detail: error.localizedDescription
            )))
        } else {
            emit(.discontinuity(MeetingAudioSourceDiscontinuity(
                reason: .streamInterrupted,
                hostTimestamp: hostTimestamp,
                detail: error.localizedDescription
            )))
        }
        emit(.failure(MeetingAudioSourceFailure(
            reason: revoked ? .permissionRevoked : .interrupted,
            hostTimestamp: hostTimestamp,
            message: error.localizedDescription
        )))
    }

    private func emit(_ event: MeetingAudioSourceEvent) {
        lock.withLock { eventHandler }?(event)
    }

    private static func extract(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> (samples: [Float], sampleRate: Double, channelCount: Int) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { throw NativeMeetingAudioSourceError.configurationFailed }
        let samples = try interleavedSamples(from: pcm)
        return (samples, format.sampleRate, Int(format.channelCount))
    }

    fileprivate static func interleavedSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0, let channels = buffer.floatChannelData else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
        if buffer.format.isInterleaved {
            return Array(UnsafeBufferPointer(
                start: channels[0],
                count: frameCount * channelCount
            ))
        }
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = channels[channel][frame]
            }
        }
        return samples
    }
}

/// AVAudioEngine uses the selected input device when supplied and otherwise
/// follows the current default. It uses shared Core Audio input, so it does not
/// claim exclusive microphone ownership from meeting applications.
protocol MeetingMicrophoneAudioEngine: AnyObject {
    var isRunning: Bool { get }
    var notificationObject: AnyObject { get }

    func selectDevice(_ deviceID: AudioDeviceID) throws
    func validatedInputFormat() throws -> AVAudioFormat
    func installTap(
        format: AVAudioFormat?,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    func removeTap()
    func prepare()
    func start() throws
    func stop()
}

private final class NativeMeetingMicrophoneAudioEngine: MeetingMicrophoneAudioEngine {
    let engine: AVAudioEngine

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var isRunning: Bool { engine.isRunning }
    var notificationObject: AnyObject { engine }

    func selectDevice(_ deviceID: AudioDeviceID) throws {
        var mutableDeviceID = deviceID
        guard let audioUnit = engine.inputNode.audioUnit,
              AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
              ) == noErr else {
            throw NativeMeetingAudioSourceError.configurationFailed
        }
    }

    func validatedInputFormat() throws -> AVAudioFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NativeMeetingAudioSourceError.unavailable
        }
        return format
    }

    func installTap(
        format: AVAudioFormat?,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: handler
        )
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

final class AVAudioEngineMeetingAudioSource: MeetingAudioSourceCapturing, @unchecked Sendable {
    let source: MeetingAudioSource = .microphone

    /// Core Audio can reject the first graph start while a device or another
    /// client is still settling. Rebuild the graph between attempts instead of
    /// making the user stop and start the whole recording again.
    private static let startupRetryDelays: [Duration] = [
        .milliseconds(120),
        .milliseconds(300),
        .milliseconds(650),
    ]

    private let selection: MeetingMicrophoneSelection
    private let inventory: any MeetingMicrophoneInventoryProviding
    private let engine: any MeetingMicrophoneAudioEngine
    private let authorizationStatus: @Sendable () -> AVAuthorizationStatus
    private let lock = NSLock()
    private let engineLifecycleLock = NSLock()
    private var eventHandler: (@Sendable (MeetingAudioSourceEvent) -> Void)?
    private var lastSampleRate: Double?
    private var configurationObserver: NSObjectProtocol?
    private var environmentObservers: MeetingAudioEnvironmentObservers?
    private var healthTimer: DispatchSourceTimer?
    private var terminalFailureReported = false
    private var tapIsInstalled = false
    private var engineStartCompleted = false
    private var lifecycleGeneration: UInt64 = 0
    private var configurationRecoveryTask: Task<Void, Never>?

    init(
        selection: MeetingMicrophoneSelection = .systemDefault,
        inventory: any MeetingMicrophoneInventoryProviding = CoreAudioMeetingMicrophoneInventory(),
        authorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }
    ) {
        self.selection = selection
        self.inventory = inventory
        self.engine = NativeMeetingMicrophoneAudioEngine()
        self.authorizationStatus = authorizationStatus
    }

    init(
        selection: MeetingMicrophoneSelection,
        inventory: any MeetingMicrophoneInventoryProviding,
        engine: any MeetingMicrophoneAudioEngine,
        authorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus
    ) {
        self.selection = selection
        self.inventory = inventory
        self.engine = engine
        self.authorizationStatus = authorizationStatus
    }

    func start(
        eventHandler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void
    ) async throws {
        guard authorizationStatus() == .authorized else {
            throw NativeMeetingAudioSourceError.permissionDenied
        }
        let (generation, previousRecoveryTask) = lock.withLock {
            lifecycleGeneration &+= 1
            let previousRecoveryTask = configurationRecoveryTask
            configurationRecoveryTask = nil
            self.eventHandler = eventHandler
            lastSampleRate = nil
            terminalFailureReported = false
            engineStartCompleted = false
            return (lifecycleGeneration, previousRecoveryTask)
        }
        previousRecoveryTask?.cancel()
        await previousRecoveryTask?.value

        let environmentObservers = MeetingAudioEnvironmentObservers(
            source: .microphone,
            handler: eventHandler
        )
        environmentObservers.start()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.notificationObject,
            queue: nil
        ) { [weak self] _ in
            self?.configurationChanged()
        }
        lock.withLock {
            self.environmentObservers = environmentObservers
            configurationObserver = observer
        }

        do {
            try await startEngineWithRetries(generation: generation)
            try ensureSessionIsActive(generation)
            lock.withLock { engineStartCompleted = true }
            scheduleConfigurationRecoveryIfNeeded()
            let timer = makeHealthTimer()
            lock.withLock { healthTimer = timer }
            timer.resume()
        } catch {
            resetEngineGraph()
            environmentObservers.stop()
            NotificationCenter.default.removeObserver(observer)
            lock.withLock {
                self.eventHandler = nil
                self.environmentObservers = nil
                configurationObserver = nil
                healthTimer = nil
                engineStartCompleted = false
            }
            if let nativeError = error as? NativeMeetingAudioSourceError {
                throw nativeError
            }
            throw NativeMeetingAudioSourceError.startFailed
        }
    }

    func stop() async {
        let values = lock.withLock {
            lifecycleGeneration &+= 1
            let values = (
                configurationObserver,
                environmentObservers,
                healthTimer,
                configurationRecoveryTask
            )
            configurationObserver = nil
            environmentObservers = nil
            healthTimer = nil
            configurationRecoveryTask = nil
            eventHandler = nil
            lastSampleRate = nil
            engineStartCompleted = false
            return values
        }
        values.2?.cancel()
        if let observer = values.0 { NotificationCenter.default.removeObserver(observer) }
        values.1?.stop()
        values.3?.cancel()
        await values.3?.value
        engineLifecycleLock.withLock {
            if tapIsInstalled { engine.removeTap() }
            tapIsInstalled = false
            engine.stop()
        }
    }

    private func receive(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard authorizationStatus() == .authorized else {
            reportTerminalFailure(reason: .permissionRevoked, message: "Microphone access was revoked.")
            return
        }
        do {
            let samples = try ScreenCaptureKitMeetingAudioSource.interleavedSamples(from: buffer)
            let sourceTimestamp: TimeInterval
            if time.isSampleTimeValid {
                sourceTimestamp = Double(time.sampleTime) / buffer.format.sampleRate
            } else {
                sourceTimestamp = 0
            }
            let hostTimestamp = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            emit(.samples(MeetingAudioSampleBuffer(
                source: .microphone,
                sourceTimestamp: sourceTimestamp,
                hostTimestamp: hostTimestamp,
                sampleRate: buffer.format.sampleRate,
                channelCount: Int(buffer.format.channelCount),
                interleavedSamples: samples
            )))
        } catch {
            emit(.failure(MeetingAudioSourceFailure(
                reason: .sourceFailed,
                hostTimestamp: ProcessInfo.processInfo.systemUptime,
                message: error.localizedDescription
            )))
        }
    }

    private func configurationChanged() {
        let rate = (try? engineLifecycleLock.withLock {
            try engine.validatedInputFormat().sampleRate
        }) ?? 0
        let priorRate = lock.withLock { () -> Double? in
            defer { lastSampleRate = rate }
            return lastSampleRate
        }
        let hostTimestamp = ProcessInfo.processInfo.systemUptime
        emit(.discontinuity(MeetingAudioSourceDiscontinuity(
            reason: .deviceChanged,
            hostTimestamp: hostTimestamp,
            detail: "The microphone device configuration changed."
        )))
        if let priorRate, abs(priorRate - rate) > 0.001 {
            emit(.discontinuity(MeetingAudioSourceDiscontinuity(
                reason: .sampleRateChanged,
                hostTimestamp: hostTimestamp,
                detail: "Microphone audio changed from \(priorRate) Hz to \(rate) Hz."
            )))
        }
        scheduleConfigurationRecoveryIfNeeded()
    }

    /// Core Audio applies CurrentDevice asynchronously. Require several
    /// consecutive native-format observations before constructing the graph so
    /// a transient 44.1 kHz value cannot race a device settling at 48 kHz.
    private func settledInputFormat(generation: UInt64) async throws -> AVAudioFormat {
        let maximumAttempts = 20
        let requiredStableSamples = 4
        var priorSampleRate: Double?
        var priorChannelCount: AVAudioChannelCount?
        var stableSamples = 0

        for attempt in 0..<maximumAttempts {
            try ensureSessionIsActive(generation)
            let format = try engineLifecycleLock.withLock {
                try engine.validatedInputFormat()
            }
            if let priorSampleRate,
               let priorChannelCount,
               abs(priorSampleRate - format.sampleRate) < 0.001,
               priorChannelCount == format.channelCount {
                stableSamples += 1
            } else {
                priorSampleRate = format.sampleRate
                priorChannelCount = format.channelCount
                stableSamples = 1
            }
            if stableSamples >= requiredStableSamples { return format }
            if attempt < maximumAttempts - 1 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw NativeMeetingAudioSourceError.configurationFailed
    }

    private func scheduleConfigurationRecoveryIfNeeded() {
        let engineIsRunning = engineLifecycleLock.withLock { engine.isRunning }
        lock.withLock {
            guard engineStartCompleted,
                  configurationRecoveryTask == nil,
                  !engineIsRunning else { return }
            let generation = lifecycleGeneration
            configurationRecoveryTask = Task { [weak self] in
                await self?.recoverFromConfigurationChange(generation: generation)
            }
        }
    }

    private func recoverFromConfigurationChange(generation: UInt64) async {
        defer {
            lock.withLock {
                if lifecycleGeneration == generation {
                    configurationRecoveryTask = nil
                }
            }
        }
        guard lock.withLock({
            lifecycleGeneration == generation && engineStartCompleted
        }) else { return }
        do {
            try ensureSessionIsActive(generation)
            resetEngineGraph()
            try await startEngineWithRetries(generation: generation)
            try ensureSessionIsActive(generation)
            if !engineLifecycleLock.withLock({ engine.isRunning }) {
                throw NativeMeetingAudioSourceError.startFailed
            }
        } catch is CancellationError {
            return
        } catch {
            guard lock.withLock({
                lifecycleGeneration == generation && engineStartCompleted
            }) else { return }
            reportTerminalFailure(
                reason: .interrupted,
                message: "The microphone stream could not recover after its device format changed."
            )
        }
    }

    private func startEngineWithRetries(generation: UInt64) async throws {
        for attempt in 0...Self.startupRetryDelays.count {
            try ensureSessionIsActive(generation)
            if attempt > 0 {
                try await Task.sleep(for: Self.startupRetryDelays[attempt - 1])
                try ensureSessionIsActive(generation)
            }

            do {
                let inventorySnapshot = try inventory.snapshot()
                guard let deviceID = try inventorySnapshot.deviceID(for: selection) else {
                    throw NativeMeetingAudioSourceError.unavailable
                }
                let format: AVAudioFormat
                if case .device = selection {
                    try engineLifecycleLock.withLock {
                        try engine.selectDevice(deviceID)
                    }
                    format = try await settledInputFormat(generation: generation)
                } else {
                    format = try engineLifecycleLock.withLock {
                        try engine.validatedInputFormat()
                    }
                }
                try ensureSessionIsActive(generation)
                lock.withLock { lastSampleRate = format.sampleRate }

                // A non-nil tap format is applied to the input bus. External
                // devices can finish switching sample rates asynchronously,
                // which makes a just-read explicit format stale. Follow the
                // native bus format and rebuild the tap for every retry.
                try engineLifecycleLock.withLock {
                    try ensureSessionIsActive(generation)
                    engine.installTap(format: nil) { [weak self] buffer, time in
                        self?.receive(buffer: buffer, time: time)
                    }
                    tapIsInstalled = true
                    engine.prepare()
                    try engine.start()
                }
                return
            } catch {
                resetEngineGraph()
                if error is CancellationError { throw error }
                try ensureSessionIsActive(generation)
                guard attempt < Self.startupRetryDelays.count else { throw error }
            }
        }
    }

    private func resetEngineGraph() {
        engineLifecycleLock.withLock {
            if tapIsInstalled { engine.removeTap() }
            if tapIsInstalled || engine.isRunning { engine.stop() }
            tapIsInstalled = false
        }
    }

    private func ensureSessionIsActive(_ generation: UInt64) throws {
        guard !Task.isCancelled,
              lock.withLock({
                  lifecycleGeneration == generation && eventHandler != nil
              }) else {
            throw CancellationError()
        }
    }

    private func makeHealthTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "app.brain.meeting-audio.microphone-health")
        )
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if authorizationStatus() != .authorized {
                reportTerminalFailure(
                    reason: .permissionRevoked,
                    message: "Microphone access was revoked."
                )
            } else if case .device(let uid) = selection,
                      !((try? inventory.snapshot().devices.contains { $0.id == uid }) ?? false) {
                reportTerminalFailure(
                    reason: .sourceUnavailable,
                    message: "The selected microphone is no longer available. Reconnect it or choose another input in Speech settings."
                )
            } else {
                // The recovery scheduler rechecks both lifecycle state and the
                // live engine state while it claims the single recovery slot.
                // Avoid making a terminal decision from two stale timer reads.
                scheduleConfigurationRecoveryIfNeeded()
            }
        }
        return timer
    }

    private func reportTerminalFailure(reason: MeetingAudioFailureReason, message: String) {
        let shouldReport = lock.withLock {
            guard !terminalFailureReported else { return false }
            terminalFailureReported = true
            engineStartCompleted = false
            return true
        }
        guard shouldReport else { return }
        emit(.failure(MeetingAudioSourceFailure(
            reason: reason,
            hostTimestamp: ProcessInfo.processInfo.systemUptime,
            message: message
        )))
    }

    private func emit(_ event: MeetingAudioSourceEvent) {
        lock.withLock { eventHandler }?(event)
    }
}

private final class MeetingAudioEnvironmentObservers: @unchecked Sendable {
    private let handler: @Sendable (MeetingAudioSourceEvent) -> Void
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(
        source _: MeetingAudioSource,
        handler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void
    ) {
        self.handler = handler
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.emit(reason: .systemSleep, detail: "The Mac is going to sleep.")
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.emit(reason: .systemWake, detail: "The Mac woke from sleep.")
        }
        lock.withLock { tokens = [sleep, wake] }
    }

    func stop() {
        let stored = lock.withLock {
            defer { tokens = [] }
            return tokens
        }
        let center = NSWorkspace.shared.notificationCenter
        for token in stored { center.removeObserver(token) }
    }

    private func emit(reason: MeetingAudioDiscontinuityReason, detail: String) {
        handler(.discontinuity(MeetingAudioSourceDiscontinuity(
            reason: reason,
            hostTimestamp: ProcessInfo.processInfo.systemUptime,
            detail: detail
        )))
    }
}
