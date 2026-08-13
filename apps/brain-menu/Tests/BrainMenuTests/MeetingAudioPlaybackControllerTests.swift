import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct MeetingAudioPlaybackControllerTests {
    @Test func controlsClampSeekAndReplayAfterCompletion() throws {
        let fixture = try PlaybackFixture()
        let engine = FakePlaybackEngine(duration: 1_000)
        let controller = MeetingAudioPlaybackController(retention: fixture.retention, engine: engine)
        controller.load(meetingID: fixture.meeting.id)
        #expect(controller.state == .ready)
        controller.play()
        #expect(controller.state == .playing)
        controller.seek(to: 5_000)
        #expect(engine.seeks.last == 1_000)
        #expect(controller.state == .ended)
        engine.finish()
        controller.play()
        #expect(engine.seeks.last == 0)
        #expect(controller.state == .playing)
        controller.pause()
        controller.seek(to: -2)
        #expect(engine.seeks.last == 0)
        #expect(controller.state == .paused)
    }

    @Test func replacementAndFailureClearObserversAndStopPriorPlayback() throws {
        let fixture = try PlaybackFixture()
        let engine = FakePlaybackEngine(duration: 100)
        let controller = MeetingAudioPlaybackController(retention: fixture.retention, engine: engine)
        controller.load(meetingID: fixture.meeting.id)
        controller.load(meetingID: fixture.meeting.id)
        #expect(engine.stopCount == 2)
        #expect(engine.onProgress != nil)
        fixture.deleteAudio()
        controller.load(meetingID: fixture.meeting.id)
        #expect(controller.state == .failed("The retained meeting recording is not available on this Mac."))
        #expect(engine.onProgress == nil)
        #expect(engine.onCompletion == nil)
    }
}

@MainActor private final class FakePlaybackEngine: MeetingAudioPlaying {
    var durationMilliseconds: Int64
    var elapsedMilliseconds: Int64 = 0
    var onProgress: (@MainActor (Int64) -> Void)?
    var onCompletion: (@MainActor () -> Void)?
    private(set) var seeks: [Int64] = []
    private(set) var stopCount = 0
    init(duration: Int64) { durationMilliseconds = duration }
    func load(url: URL) throws { elapsedMilliseconds = 0 }
    func play() throws {}
    func pause() {}
    func stop() { stopCount += 1 }
    func seek(to milliseconds: Int64) throws { seeks.append(milliseconds); elapsedMilliseconds = milliseconds }
    func finish() { onCompletion?() }
}

private final class PlaybackFixture {
    let root: URL
    let store: MeetingStore
    let meeting: MeetingRecord
    let retention: AudioRetentionController
    let audioURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingStore(rootURL: root)
        var record = MeetingRecord(title: "Local", startedAt: .now, lifecycleState: .completed, speechEngine: "test", speechModel: "test")
        let directory = store.directoryURL(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audioURL = directory.appendingPathComponent(AudioRetentionController.retainedFilename)
        try Data([1, 2, 3]).write(to: audioURL)
        record.retainedAudio = RetainedAudioMetadata(filename: AudioRetentionController.retainedFilename, format: AudioRetentionController.retainedFormat, sizeBytes: 3, durationMilliseconds: 1_000)
        record.audioRetentionState = .retained
        try store.save(record, utterances: [])
        meeting = record
        retention = AudioRetentionController(store: store)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func deleteAudio() { try? FileManager.default.removeItem(at: audioURL) }
}
