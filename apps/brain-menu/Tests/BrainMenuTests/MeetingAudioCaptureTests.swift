import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingAudioCaptureTests {
    @Test
    func validSystemPresentationTimeUsesTheHostClockInsteadOfCallbackArrival() {
        let presentationTime = CMTime(seconds: 73, preferredTimescale: 48_000)
        let convertedHostTime = CMTime(seconds: 100, preferredTimescale: 1_000_000)

        let promptCallback = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
            presentationTime: presentationTime,
            callbackHostTimestamp: 100.25,
            duration: 0.25,
            convertToHostTime: { _ in convertedHostTime }
        )
        let delayedCallback = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
            presentationTime: presentationTime,
            callbackHostTimestamp: 104.25,
            duration: 0.25,
            convertToHostTime: { _ in convertedHostTime }
        )

        #expect(promptCallback == 100)
        #expect(delayedCallback == 100)
    }

    @Test
    func invalidOrUnavailableSystemPresentationTimeUsesCallbackStartFallback() {
        let callbackHostTimestamp = 42.5
        let duration = 0.25
        let validPresentationTime = CMTime(seconds: 73, preferredTimescale: 48_000)

        let invalidPresentationTime = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
            presentationTime: .invalid,
            callbackHostTimestamp: callbackHostTimestamp,
            duration: duration,
            convertToHostTime: { _ in CMTime(seconds: 100, preferredTimescale: 1_000) }
        )
        let unavailableConversion = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
            presentationTime: validPresentationTime,
            callbackHostTimestamp: callbackHostTimestamp,
            duration: duration,
            convertToHostTime: { _ in nil }
        )
        let invalidConversion = ScreenCaptureKitAudioClockAlignment.hostTimestamp(
            presentationTime: validPresentationTime,
            callbackHostTimestamp: callbackHostTimestamp,
            duration: duration,
            convertToHostTime: { _ in .invalid }
        )
        let invalidSourceTimestamp = ScreenCaptureKitAudioClockAlignment.sourceTimestamp(
            presentationTime: .invalid,
            fallbackHostTimestamp: invalidPresentationTime
        )
        let validSourceTimestamp = ScreenCaptureKitAudioClockAlignment.sourceTimestamp(
            presentationTime: validPresentationTime,
            fallbackHostTimestamp: invalidPresentationTime
        )

        #expect(invalidPresentationTime == 42.25)
        #expect(unavailableConversion == 42.25)
        #expect(invalidConversion == 42.25)
        #expect(invalidSourceTimestamp == 42.25)
        #expect(validSourceTimestamp == 73)
    }

    @Test
    func normalizesMismatchedRatesAndClocksIntoOrderedSeparateTracks() throws {
        let temp = try MeetingAudioTestDirectory()
        let meetingDirectory = temp.url.appendingPathComponent(UUID().uuidString)
        let origin = Date(timeIntervalSince1970: 1_784_201_000.25)
        let writer = try MeetingAudioWriter(meetingDirectory: meetingDirectory, origin: origin)

        let systemResult = try writer.append(MeetingAudioSampleBuffer(
            source: .system,
            sourceTimestamp: 3.5,
            hostTimestamp: 50.050,
            sampleRate: 8_000,
            channelCount: 1,
            interleavedSamples: (0..<80).map { $0.isMultiple(of: 2) ? -0.25 : 0.25 }
        ))
        let microphoneResult = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 9_000.0,
            hostTimestamp: 50.000,
            sampleRate: 48_000,
            channelCount: 2,
            interleavedSamples: (0..<480).flatMap { frame in
                let sample = Float(frame) / 480
                return [sample, -sample]
            }
        ))
        let summary = try writer.finalize()

        #expect(systemResult.frameCount == 160)
        #expect(microphoneResult.frameCount == 160)
        #expect(summary.origin == origin)
        #expect(summary.originHostTimestamp == 50)
        #expect(summary.chunks.map(\.source) == [.microphone, .system])
        #expect(summary.chunks.map(\.timestampMilliseconds) == [0, 50])
        #expect(summary.chunks.map(\.sourceTimestamp) == [9_000, 3.5])
        #expect(summary.tracks.map(\.source) == [.microphone, .system])
        #expect(summary.tracks.allSatisfy {
            $0.sampleRate == 16_000 && $0.channelCount == 1 && $0.frameCount == 160
        })
        #expect(summary.totalFrameCount == 320)

        let microphoneTrack = try #require(summary.tracks.first { $0.source == .microphone })
        let systemTrack = try #require(summary.tracks.first { $0.source == .system })
        #expect(microphoneTrack.fileURL.deletingLastPathComponent().path == meetingDirectory.path)
        #expect(systemTrack.fileURL.deletingLastPathComponent().path == meetingDirectory.path)
        #expect(try Data(contentsOf: microphoneTrack.fileURL).count == 160 * 4)
        #expect(try Data(contentsOf: systemTrack.fileURL).count == 160 * 4)
        #expect(microphoneTrack.fileURL != systemTrack.fileURL)
        #expect((microphoneResult.level?.rms ?? 0) > 0.1)
        #expect(try floatSamples(at: microphoneTrack.fileURL).contains { abs($0) > 0.1 })
        #expect(try floatSamples(at: systemTrack.fileURL).contains { abs($0) > 0.1 })
    }

    @Test
    func levelUpdatesAreAtMostTenHertzAndReportRMSAndClipping() throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(meetingDirectory: temp.url.appendingPathComponent("level"))
        let first = try writer.append(buffer(
            source: .microphone,
            hostTimestamp: 100,
            samples: [1, -1, 0, 0]
        ))
        let throttled = try writer.append(buffer(
            source: .microphone,
            hostTimestamp: 100.050,
            samples: [0.5, 0.5, 0.5, 0.5]
        ))
        let next = try writer.append(buffer(
            source: .microphone,
            hostTimestamp: 100.101,
            samples: [0.5, 0.5, 0.5, 0.5]
        ))
        _ = try writer.append(buffer(
            source: .microphone,
            hostTimestamp: 100.080,
            samples: [0.25, 0.25]
        ))
        let summary = try writer.finalize()

        #expect(abs((first.level?.rms ?? 0) - Float(0.5.squareRoot())) < 0.000_1)
        #expect(first.level?.isClipping == true)
        #expect(throttled.level == nil)
        #expect(next.level?.timestampMilliseconds == 101)
        #expect(next.level?.isClipping == false)
        #expect(summary.discontinuities.map(\.reason) == [.timestampRegression])
    }

    @Test
    func injectedSourcesRecordDiscontinuitiesAndOneSourceErrorsExplicitly() async throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(meetingDirectory: temp.url.appendingPathComponent("events"))
        let events = MeetingAudioEventRecorder()
        let system = DeterministicMeetingAudioSource(source: .system, events: [
            .samples(buffer(source: .system, hostTimestamp: 10, samples: [0.1, 0.2])),
            .discontinuity(.init(
                reason: .sampleRateChanged,
                sourceTimestamp: 11,
                hostTimestamp: 10.2,
                detail: "48 kHz to 44.1 kHz"
            )),
            .discontinuity(.init(
                reason: .streamInterrupted,
                hostTimestamp: 10.3,
                detail: "display stream stopped"
            )),
            .failure(.init(
                reason: .interrupted,
                hostTimestamp: 10.3,
                message: "display stream stopped"
            )),
        ])
        let microphone = DeterministicMeetingAudioSource(source: .microphone, events: [
            .samples(buffer(source: .microphone, hostTimestamp: 10.05, samples: [0.2, 0.3])),
            .discontinuity(.init(
                reason: .deviceChanged,
                hostTimestamp: 10.4,
                detail: "USB microphone disconnected"
            )),
            .discontinuity(.init(reason: .systemSleep, hostTimestamp: 10.5)),
            .discontinuity(.init(reason: .systemWake, hostTimestamp: 11.5)),
            .failure(.init(
                reason: .permissionRevoked,
                hostTimestamp: 11.6,
                message: "microphone permission revoked"
            )),
        ])
        let capture = try MeetingAudioCapture(
            systemAudio: system,
            microphone: microphone,
            writer: writer,
            microphoneReadinessTimeout: nil,
            eventHandler: events.record
        )

        try await capture.start()
        let summary = try await capture.stop()

        #expect(summary.chunks.map(\.source) == [.system, .microphone])
        #expect(summary.discontinuities.map(\.reason).contains(.sampleRateChanged))
        #expect(summary.discontinuities.map(\.reason).contains(.streamInterrupted))
        #expect(summary.discontinuities.map(\.reason).contains(.deviceChanged))
        #expect(summary.discontinuities.map(\.reason).contains(.systemSleep))
        #expect(summary.discontinuities.map(\.reason).contains(.systemWake))
        #expect(summary.discontinuities.map(\.reason).contains(.permissionRevoked))
        #expect(summary.discontinuities.map(\.reason).contains(.sourceFailure))
        #expect(summary.failures.map(\.reason) == [.interrupted, .permissionRevoked])
        #expect(events.values.compactMap { event -> MeetingAudioFailure? in
            guard case .failure(let failure) = event else { return nil }
            return failure
        }.map(\.reason) == [.interrupted, .permissionRevoked])
        #expect(system.stopCount == 1)
        #expect(microphone.stopCount == 1)
    }

    @Test
    func anEmptyOrFailedCaptureCannotSilentlySucceed() async throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(meetingDirectory: temp.url.appendingPathComponent("empty"))
        let events = MeetingAudioEventRecorder()
        let system = DeterministicMeetingAudioSource(source: .system, events: [
            .failure(.init(
                reason: .interrupted,
                hostTimestamp: 1,
                message: "system source failed before samples"
            )),
        ])
        let microphone = DeterministicMeetingAudioSource(source: .microphone, events: [])
        let capture = try MeetingAudioCapture(
            systemAudio: system,
            microphone: microphone,
            writer: writer,
            microphoneReadinessTimeout: nil,
            eventHandler: events.record
        )

        try await capture.start()
        await #expect(throws: MeetingAudioCaptureError.emptyCapture) {
            try await capture.stop()
        }
        #expect(events.values.contains(.failure(MeetingAudioFailure(
            source: nil,
            timestampMilliseconds: 0,
            reason: .emptyCapture,
            message: MeetingAudioWriterError.emptyCapture.localizedDescription
        ))))
    }

    @Test
    func selectedStableDeviceUsesTheNativeTapFormatAfterSelection() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let engine = RecordingMicrophoneAudioEngine(format: format)
        let inventory = FixedMicrophoneInventory(devices: [
            MeetingMicrophoneDevice(
                id: "usb-microphone-uid",
                name: "USB Microphone",
                coreAudioID: 42,
                isSystemDefault: false
            ),
        ], defaultDeviceUID: nil)
        let source = AVAudioEngineMeetingAudioSource(
            selection: .device(uid: "usb-microphone-uid"),
            inventory: inventory,
            engine: engine,
            authorizationStatus: { .authorized }
        )

        try await source.start { _ in }

        #expect(engine.selectedDeviceIDs == [42])
        #expect(engine.installedFormats.count == 1)
        #expect(engine.installedFormats[0] == nil)
        #expect(engine.didSelectBeforeInstallingTap)
        await source.stop()
        #expect(engine.removeTapCount == 1)
        #expect(engine.stopCount == 1)
    }

    @Test
    func nondefaultDeviceWaitsForDelayedNativeFormatBeforeStarting() async throws {
        let transient = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        ))
        let settled = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let engine = RecordingMicrophoneAudioEngine(formats: [
            transient, transient,
            settled, settled, settled, settled,
        ])
        let inventory = FixedMicrophoneInventory(devices: [
            MeetingMicrophoneDevice(
                id: "nondefault-wireless-microphone",
                name: "Wireless microphone",
                coreAudioID: 42,
                isSystemDefault: false
            ),
        ], defaultDeviceUID: "built-in")
        let source = AVAudioEngineMeetingAudioSource(
            selection: .device(uid: "nondefault-wireless-microphone"),
            inventory: inventory,
            engine: engine,
            authorizationStatus: { .authorized }
        )

        try await source.start { _ in }

        #expect(engine.validatedSampleRates == [
            44_100, 44_100,
            48_000, 48_000, 48_000, 48_000,
        ])
        #expect(engine.isRunning)
        #expect(engine.installedFormats.count == 1)
        #expect(engine.installedFormats[0] == nil)
        await source.stop()
    }

    @Test
    func explicitlySelectedDeviceIsPinnedEvenWhenItMatchesTheSystemDefault() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let engine = RecordingMicrophoneAudioEngine(format: format)
        let inventory = FixedMicrophoneInventory(devices: [
            MeetingMicrophoneDevice(
                id: "default-wireless-microphone",
                name: "Wireless microphone",
                coreAudioID: 42,
                isSystemDefault: true
            ),
        ], defaultDeviceUID: "default-wireless-microphone")
        let source = AVAudioEngineMeetingAudioSource(
            selection: .device(uid: "default-wireless-microphone"),
            inventory: inventory,
            engine: engine,
            authorizationStatus: { .authorized }
        )

        try await source.start { _ in }

        #expect(engine.selectedDeviceIDs == [42])
        #expect(engine.didSelectBeforeInstallingTap)
        await source.stop()
    }

    @Test
    func runningEngineRecoversAfterADeviceConfigurationChange() async throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let engine = RecordingMicrophoneAudioEngine(format: format)
        let events = MeetingAudioSourceEventRecorder()
        let inventory = FixedMicrophoneInventory(devices: [
            MeetingMicrophoneDevice(
                id: "default-microphone",
                name: "Default microphone",
                coreAudioID: 42,
                isSystemDefault: true
            ),
        ], defaultDeviceUID: "default-microphone")
        let source = AVAudioEngineMeetingAudioSource(
            selection: .systemDefault,
            inventory: inventory,
            engine: engine,
            authorizationStatus: { .authorized }
        )
        try await source.start(eventHandler: events.record)

        #expect(engine.selectedDeviceIDs.isEmpty)
        engine.interruptForConfigurationChange()
        for _ in 0..<50 where engine.startCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(engine.startCount == 2)
        #expect(engine.isRunning)
        #expect(events.values.contains { event in
            guard case .discontinuity(let value) = event else { return false }
            return value.reason == .deviceChanged
        })
        #expect(!events.values.contains { event in
            if case .failure = event { return true }
            return false
        })
        await source.stop()
    }

    @Test
    func pinnedSelectionPersistsAndDoesNotFallBackWhenDeviceDisappears() throws {
        let suite = "MeetingAudioCaptureTests.Selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeetingMicrophoneSelectionStore(defaults: defaults)
        store.select(.device(uid: "desk-mic"))
        #expect(MeetingMicrophoneSelectionStore(defaults: defaults).selection == .device(uid: "desk-mic"))

        let snapshot = MeetingMicrophoneInventorySnapshot(
            devices: [MeetingMicrophoneDevice(
                id: "built-in",
                name: "Mac Microphone",
                coreAudioID: 7,
                isSystemDefault: true
            )],
            defaultDeviceUID: "built-in"
        )
        #expect(throws: NativeMeetingAudioSourceError.unavailable) {
            try snapshot.deviceID(for: store.selection)
        }
        #expect(try snapshot.deviceID(for: .systemDefault) == 7)
    }

    @Test
    func missingMicrophoneFramesWarnButKeepSystemAudioRecording() async throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(meetingDirectory: temp.url.appendingPathComponent("readiness"))
        let events = MeetingAudioEventRecorder()
        let system = DeterministicMeetingAudioSource(source: .system, events: [
            .samples(buffer(source: .system, hostTimestamp: 1, samples: [0.8, -0.8])),
        ])
        let microphone = DeterministicMeetingAudioSource(source: .microphone, events: [])
        let capture = try MeetingAudioCapture(
            systemAudio: system,
            microphone: microphone,
            writer: writer,
            microphoneReadinessTimeout: .milliseconds(40),
            eventHandler: events.record
        )

        try await capture.start()
        let summary = try await capture.stop()

        #expect(events.values.contains(.warning(MeetingAudioWarning(
            source: .microphone,
            message: "No microphone audio has arrived yet. Check the selected input and microphone permission; recording will continue while Brain listens for it."
        ))))
        #expect(summary.tracks.first(where: { $0.source == .system })?.frameCount == 2)
        #expect(summary.tracks.first(where: { $0.source == .microphone })?.frameCount == 0)
        #expect(system.stopCount == 1)
        #expect(microphone.stopCount == 1)
    }

    @Test
    func buffersContainingOnlyDigitalSilenceCannotFinalizeSuccessfully() throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(
            meetingDirectory: temp.url.appendingPathComponent("digital-silence")
        )
        _ = try writer.append(buffer(
            source: .system,
            hostTimestamp: 1,
            samples: [0, 0, 0, 0]
        ))
        _ = try writer.append(buffer(
            source: .microphone,
            hostTimestamp: 1,
            samples: [0, 0, 0, 0]
        ))

        #expect(throws: MeetingAudioWriterError.emptyCapture) {
            try writer.finalize()
        }
    }

    @Test
    func nonzeroInputThatResamplesToDigitalSilenceCannotFinalizeSuccessfully() throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(
            meetingDirectory: temp.url.appendingPathComponent("resampled-silence")
        )
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 0,
            hostTimestamp: 1,
            sampleRate: 48_000,
            channelCount: 1,
            interleavedSamples: [0, 1, 0]
        ))

        #expect(throws: MeetingAudioWriterError.emptyCapture) {
            try writer.finalize()
        }
    }

    @Test
    func flatMicrophoneFramesProduceGuidanceButRemainASeparateTrack() async throws {
        let temp = try MeetingAudioTestDirectory()
        let writer = try MeetingAudioWriter(meetingDirectory: temp.url.appendingPathComponent("flat"))
        let events = MeetingAudioEventRecorder()
        let system = DeterministicMeetingAudioSource(source: .system, events: [
            .samples(buffer(source: .system, hostTimestamp: 1, samples: [0.2, -0.2])),
        ])
        let microphone = DeterministicMeetingAudioSource(source: .microphone, events: [
            .samples(buffer(source: .microphone, hostTimestamp: 1, samples: [0, 0, 0, 0])),
        ])
        let capture = try MeetingAudioCapture(
            systemAudio: system,
            microphone: microphone,
            writer: writer,
            microphoneReadinessTimeout: .milliseconds(40),
            eventHandler: events.record
        )

        try await capture.start()
        let summary = try await capture.stop()

        #expect(events.values.contains(.warning(MeetingAudioWarning(
            source: .microphone,
            message: "No usable microphone signal was detected yet. Check the selected input and its input level; recording will continue while Brain listens for it."
        ))))
        #expect(Set(summary.tracks.map(\.source)) == Set(MeetingAudioSource.allCases))
        #expect(summary.tracks.first(where: { $0.source == .microphone })?.frameCount == 4)
    }

    @Test
    func audioFilesAndManifestAreOwnerOnlyAndCaptureRequestsHaveNoAudioOrVideoFields() throws {
        let temp = try MeetingAudioTestDirectory()
        let meetingDirectory = temp.url.appendingPathComponent("private")
        let writer = try MeetingAudioWriter(meetingDirectory: meetingDirectory)
        _ = try writer.append(buffer(source: .microphone, hostTimestamp: 1, samples: [0.1]))
        let summary = try writer.finalize()

        #expect(try permissions(of: meetingDirectory) == 0o700)
        for track in summary.tracks {
            #expect(try permissions(of: track.fileURL) == 0o600)
        }
        #expect(try permissions(of: meetingDirectory.appendingPathComponent(
            MeetingAudioWriter.manifestFilename
        )) == 0o600)

        let request = BrainCaptureRequest(
            type: .transcript,
            source: "Brain.app",
            transcript: "Only the completed transcript crosses the capture boundary."
        )
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any])
        #expect(object["audio"] == nil)
        #expect(object["video"] == nil)
        #expect(object["audio_url"] == nil)
        #expect(object["video_url"] == nil)
        #expect(object["transcript"] as? String == request.transcript)
    }

    private static func buffer(
        source: MeetingAudioSource,
        hostTimestamp: TimeInterval,
        samples: [Float]
    ) -> MeetingAudioSampleBuffer {
        MeetingAudioSampleBuffer(
            source: source,
            sourceTimestamp: hostTimestamp * 7 + (source == .system ? 500 : 50_000),
            hostTimestamp: hostTimestamp,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: samples
        )
    }

    private func buffer(
        source: MeetingAudioSource,
        hostTimestamp: TimeInterval,
        samples: [Float]
    ) -> MeetingAudioSampleBuffer {
        Self.buffer(source: source, hostTimestamp: hostTimestamp, samples: samples)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func floatSamples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return samples
    }
}

private final class DeterministicMeetingAudioSource: MeetingAudioSourceCapturing,
    @unchecked Sendable
{
    let source: MeetingAudioSource
    private let events: [MeetingAudioSourceEvent]
    private let lock = NSLock()
    private var recordedStopCount = 0

    var stopCount: Int { lock.withLock { recordedStopCount } }

    init(source: MeetingAudioSource, events: [MeetingAudioSourceEvent]) {
        self.source = source
        self.events = events
    }

    func start(
        eventHandler: @escaping @Sendable (MeetingAudioSourceEvent) -> Void
    ) async throws {
        for event in events { eventHandler(event) }
    }

    func stop() async {
        lock.withLock { recordedStopCount += 1 }
    }
}

private final class MeetingAudioEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [MeetingAudioCaptureEvent] = []

    var values: [MeetingAudioCaptureEvent] { lock.withLock { recordedValues } }

    func record(_ event: MeetingAudioCaptureEvent) {
        lock.withLock { recordedValues.append(event) }
    }
}

private struct FixedMicrophoneInventory: MeetingMicrophoneInventoryProviding {
    let devices: [MeetingMicrophoneDevice]
    let defaultDeviceUID: String?

    func snapshot() throws -> MeetingMicrophoneInventorySnapshot {
        MeetingMicrophoneInventorySnapshot(
            devices: devices,
            defaultDeviceUID: defaultDeviceUID
        )
    }
}

private final class RecordingMicrophoneAudioEngine: MeetingMicrophoneAudioEngine,
    @unchecked Sendable
{
    private let formats: [AVAudioFormat]
    private var nextFormatIndex = 0
    let notificationObject: AnyObject = NSObject()
    private(set) var selectedDeviceIDs: [AudioDeviceID] = []
    private(set) var installedFormats: [AVAudioFormat?] = []
    private(set) var validatedSampleRates: [Double] = []
    private(set) var removeTapCount = 0
    private(set) var stopCount = 0
    private(set) var startCount = 0
    private(set) var isRunning = false
    private(set) var didSelectBeforeInstallingTap = false

    init(format: AVAudioFormat) { formats = [format] }

    init(formats: [AVAudioFormat]) {
        precondition(!formats.isEmpty)
        self.formats = formats
    }

    func selectDevice(_ deviceID: AudioDeviceID) throws {
        selectedDeviceIDs.append(deviceID)
    }

    func validatedInputFormat() throws -> AVAudioFormat {
        let format = formats[min(nextFormatIndex, formats.count - 1)]
        nextFormatIndex += 1
        validatedSampleRates.append(format.sampleRate)
        return format
    }

    func installTap(
        format: AVAudioFormat?,
        handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        didSelectBeforeInstallingTap = !selectedDeviceIDs.isEmpty
        installedFormats.append(format)
    }

    func removeTap() { removeTapCount += 1 }
    func prepare() {}
    func start() throws {
        startCount += 1
        isRunning = true
    }
    func stop() {
        isRunning = false
        stopCount += 1
    }

    func interruptForConfigurationChange() {
        isRunning = false
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: notificationObject
        )
    }
}

private final class MeetingAudioSourceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [MeetingAudioSourceEvent] = []

    var values: [MeetingAudioSourceEvent] { lock.withLock { recordedValues } }

    func record(_ event: MeetingAudioSourceEvent) {
        lock.withLock { recordedValues.append(event) }
    }
}

private final class MeetingAudioTestDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-meeting-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
