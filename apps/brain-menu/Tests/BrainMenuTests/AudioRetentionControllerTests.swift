import AVFoundation
import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct AudioRetentionControllerTests {
    @Test
    func alwaysRetainsRecordingAndCleansTemporaryAudioOnlyAfterPersistence() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let summary = try fixture.makeAudio()
        let temporaryURLs = summary.tracks.map(\.fileURL) + [fixture.manifestURL]

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        #expect(completed.retainedAudio != nil)
        #expect(try fixture.store.load(fixture.meeting.id).meeting == completed)
        #expect(temporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
    }

    @Test
    func transcriptPersistenceFailurePreservesEveryTemporaryAudioFile() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let failingStore = MeetingStore(rootURL: fixture.rootURL) { event in
            if event == .beforeAtomicReplacement(.transcript) {
                throw InjectedAudioRetentionFailure()
            }
        }
        let controller = fixture.controller(store: failingStore)

        #expect(throws: AudioRetentionControllerError.transcriptPersistenceFailed) {
            try controller.finalize(
                meeting: fixture.meeting,
                utterances: fixture.utterances,
                audio: summary
            )
        }

        for track in summary.tracks {
            #expect(FileManager.default.fileExists(atPath: track.fileURL.path))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))

        let recordingFixture = try AudioRetentionFixture()
        let recordingSummary = try recordingFixture.makeAudio()
        let recordingFailure = FailingAudioRetentionFileSystem(failure: .permissions)
        let recordingController = recordingFixture.controller(fileSystem: recordingFailure)
        #expect(throws: AudioRetentionControllerError.recordingPersistenceFailed) {
            try recordingController.finalize(
                meeting: recordingFixture.meeting,
                utterances: recordingFixture.utterances,
                audio: recordingSummary
            )
        }
        for track in recordingSummary.tracks {
            #expect(FileManager.default.fileExists(atPath: track.fileURL.path))
        }
        #expect(FileManager.default.fileExists(atPath: recordingFixture.manifestURL.path))
        #expect(!FileManager.default.fileExists(atPath: recordingFixture.recordingURL.path))
        #expect(try recordingFixture.store.load(
            recordingFixture.meeting.id
        ).meeting.retainedAudio == nil)
    }

    @Test
    func writesVerifiedPrivateCAFWithMicrophoneThenSystemChannels() throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let summary = try fixture.makeAudio(
            microphone: [Float](repeating: 0.25, count: 160),
            system: [Float](repeating: -0.5, count: 160)
        )

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )
        let metadata = try #require(completed.retainedAudio)

        #expect(metadata.filename == AudioRetentionController.retainedFilename)
        #expect(metadata.format == AudioRetentionController.retainedFormat)
        #expect(metadata.channelCount == 2)
        #expect(metadata.durationMilliseconds == 10)
        #expect(metadata.sizeBytes > 0)
        #expect(try permissions(of: fixture.recordingURL) == 0o600)
        #expect(try permissions(of: fixture.meetingDirectory) == 0o700)
        #expect(summary.tracks.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        let files = try FileManager.default.contentsOfDirectory(
            atPath: fixture.meetingDirectory.path
        ).sorted()
        #expect(files == [
            MeetingStore.meetingFilename,
            MeetingStore.transcriptFilename,
            AudioRetentionController.retainedFilename,
        ].sorted())
        #expect(try fixture.store.load(fixture.meeting.id).meeting == completed)

        let caf = try AVAudioFile(
            forReading: fixture.recordingURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        #expect(caf.fileFormat.channelCount == 2)
        #expect(Int(caf.fileFormat.sampleRate.rounded()) == MeetingAudioWriter.sampleRate)
        #expect(caf.length == 160)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: caf.processingFormat,
            frameCapacity: AVAudioFrameCount(caf.length)
        ))
        try caf.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        #expect(abs(channels[AudioRetentionController.microphoneChannel - 1][0] - 0.25) < 0.000_01)
        #expect(abs(channels[AudioRetentionController.systemAudioChannel - 1][0] + 0.5) < 0.000_01)
        #expect(abs(channels[0][159] - 0.25) < 0.000_01)
        #expect(abs(channels[1][159] + 0.5) < 0.000_01)
    }

    @Test
    func disposableCleanupFailureDoesNotDowngradePersistedTranscript() throws {
        let fixture = try AudioRetentionFixture()
        let summary = try fixture.makeAudio()
        let microphoneURL = try #require(
            summary.tracks.first(where: { $0.source == .microphone })?.fileURL
        )
        let systemURL = try #require(
            summary.tracks.first(where: { $0.source == .system })?.fileURL
        )
        let controller = fixture.controller(
            fileSystem: SelectiveCleanupFailureAudioRetentionFileSystem(
                failingFilename: microphoneURL.lastPathComponent
            )
        )

        let completed = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )
        let stored = try fixture.store.load(fixture.meeting.id)

        #expect(completed.transcriptionState == .completed)
        #expect(stored.meeting == completed)
        #expect(stored.utterances == fixture.utterances)
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
        #expect(completed.retainedAudio != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
    }

    @Test
    func revealExportAndConfirmedDeleteAreFailureSafe() throws {
        let fixture = try AudioRetentionFixture()
        let revealer = RecordingRevealerSpy()
        let controller = fixture.controller(revealer: revealer)
        let summary = try fixture.makeAudio()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        try controller.revealRecording(for: fixture.meeting.id)
        #expect(revealer.revealedURLs == [fixture.recordingURL])

        let cancelled = try controller.exportRecording(for: fixture.meeting.id, to: nil)
        #expect(cancelled == nil)
        let exportURL = fixture.rootURL.appendingPathComponent("Selected export.caf")
        #expect(try controller.exportRecording(
            for: fixture.meeting.id,
            to: exportURL
        ) == exportURL)
        #expect(try Data(contentsOf: exportURL) == Data(contentsOf: fixture.recordingURL))

        let failedExportURL = fixture.rootURL.appendingPathComponent("Failed export.caf")
        let exportFailure = FailingAudioRetentionFileSystem(failure: .copy)
        let exportFailingController = fixture.controller(fileSystem: exportFailure)
        #expect(throws: AudioRetentionControllerError.exportFailed) {
            try exportFailingController.exportRecording(
                for: fixture.meeting.id,
                to: failedExportURL
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(!FileManager.default.fileExists(atPath: failedExportURL.path))

        #expect(throws: AudioRetentionControllerError.deletionRequiresConfirmation) {
            try controller.deleteRecording(for: fixture.meeting.id, confirmed: false)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(try fixture.store.load(fixture.meeting.id).meeting.retainedAudio != nil)

        let deleteFailure = FailingAudioRetentionFileSystem(failure: .deleteRemoval)
        let deleteFailingController = fixture.controller(fileSystem: deleteFailure)
        #expect(throws: AudioRetentionControllerError.deleteFailed) {
            try deleteFailingController.deleteRecording(for: fixture.meeting.id, confirmed: true)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(try fixture.store.load(fixture.meeting.id).meeting.retainedAudio != nil)

        let deleted = try controller.deleteRecording(for: fixture.meeting.id, confirmed: true)
        #expect(deleted.retainedAudio == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.recordingURL.path))
        #expect(try fixture.store.load(fixture.meeting.id).meeting.retainedAudio == nil)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
    }

    @Test
    func retainedAudioNeverEntersCaptureRequestOrUploadSpy() async throws {
        let fixture = try AudioRetentionFixture()
        let controller = fixture.controller()
        let summary = try fixture.makeAudio()
        _ = try controller.finalize(
            meeting: fixture.meeting,
            utterances: fixture.utterances,
            audio: summary
        )

        let transcript = fixture.utterances.map(\.text).joined(separator: "\n")
        let request = BrainCaptureRequest(
            type: .transcript,
            source: "Brain.app",
            transcript: transcript,
            title: fixture.meeting.title
        )
        let spy = AudioRetentionCaptureSpy()
        _ = try await spy.capture(request, idempotencyKey: fixture.meeting.id)
        let captured = try #require(await spy.requests.first)
        let encoded = try JSONEncoder().encode(captured)
        let body = String(decoding: encoded, as: UTF8.self)

        #expect(captured == request)
        #expect(!body.contains(AudioRetentionController.retainedFilename))
        #expect(!body.contains(fixture.meetingDirectory.path))
        #expect(!body.contains("f32le.pcm"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["audio"] == nil)
        #expect(object["audio_url"] == nil)
        #expect(object["audio_path"] == nil)

        let controllerSource = try String(
            contentsOf: fixture.packageRoot
                .appendingPathComponent("Sources/BrainMenu/Meetings/AudioRetentionController.swift"),
            encoding: .utf8
        )
        #expect(!controllerSource.contains("BrainCaptureRequest"))
        #expect(!controllerSource.contains("MeetingUploadController"))
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }
}

private final class AudioRetentionFixture {
    let rootURL: URL
    let store: MeetingStore
    let meeting: MeetingRecord
    let utterances: [MeetingUtterance]

    var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var meetingDirectory: URL { store.directoryURL(for: meeting.id) }
    var manifestURL: URL {
        meetingDirectory.appendingPathComponent(MeetingAudioWriter.manifestFilename)
    }
    var recordingURL: URL {
        meetingDirectory.appendingPathComponent(AudioRetentionController.retainedFilename)
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrainAudioRetentionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = MeetingStore(rootURL: rootURL)
        meeting = MeetingRecord(
            title: "Private planning",
            detectedApplication: "com.example.meeting",
            startedAt: Date(timeIntervalSince1970: 1_784_112_400),
            endedAt: Date(timeIntervalSince1970: 1_784_112_401),
            lifecycleState: .completed,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        utterances = [try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 10,
            text: "Transcript text only.",
            baseSpeakerID: "you"
        )]
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func controller(
        store selectedStore: (any AudioRetentionMeetingStoring)? = nil,
        fileSystem: any AudioRetentionFileSystem = LocalAudioRetentionFileSystem(),
        revealer: any MeetingAudioRevealing = RecordingRevealerSpy()
    ) -> AudioRetentionController {
        AudioRetentionController(
            store: selectedStore ?? store,
            fileSystem: fileSystem,
            revealer: revealer
        )
    }

    func makeAudio(
        microphone: [Float] = [Float](repeating: 0.25, count: 160),
        system: [Float] = [Float](repeating: -0.5, count: 160)
    ) throws -> MeetingAudioCaptureSummary {
        let writer = try MeetingAudioWriter(
            meetingDirectory: meetingDirectory,
            origin: meeting.startedAt
        )
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .system,
            sourceTimestamp: 90,
            hostTimestamp: 10,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: system
        ))
        _ = try writer.append(MeetingAudioSampleBuffer(
            source: .microphone,
            sourceTimestamp: 900,
            hostTimestamp: 10,
            sampleRate: 16_000,
            channelCount: 1,
            interleavedSamples: microphone
        ))
        return try writer.finalize()
    }
}

private final class RecordingRevealerSpy: MeetingAudioRevealing, @unchecked Sendable {
    private(set) var revealedURLs: [URL] = []

    func revealFile(_ url: URL) throws {
        revealedURLs.append(url)
    }
}

private final class FailingAudioRetentionFileSystem: AudioRetentionFileSystem, @unchecked Sendable {
    enum Failure {
        case copy
        case deleteRemoval
        case permissions
    }

    let failure: Failure
    private let base = LocalAudioRetentionFileSystem()

    init(failure: Failure) {
        self.failure = failure
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        if failure == .copy { throw InjectedAudioRetentionFailure() }
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        if failure == .deleteRemoval, url.lastPathComponent.hasSuffix(".deleting") {
            throw InjectedAudioRetentionFailure()
        }
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        if failure == .permissions { throw InjectedAudioRetentionFailure() }
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private final class SelectiveCleanupFailureAudioRetentionFileSystem:
    AudioRetentionFileSystem,
    @unchecked Sendable
{
    private let failingFilename: String
    private let base = LocalAudioRetentionFileSystem()

    init(failingFilename: String) {
        self.failingFilename = failingFilename
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try base.attributes(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingFilename {
            throw InjectedAudioRetentionFailure()
        }
        try base.removeItem(at: url)
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try base.setOwnerOnlyPermissions(at: url)
    }
}

private actor AudioRetentionCaptureSpy: BrainCaptureAPI {
    private(set) var requests: [BrainCaptureRequest] = []

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        requests.append(capture)
        return BrainCaptureReceipt(id: idempotencyKey.uuidString, state: "queued")
    }
}

private struct InjectedAudioRetentionFailure: Error {}
