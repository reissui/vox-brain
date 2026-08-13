import AVFoundation
import Foundation
import Observation

@MainActor
protocol MeetingAudioPlaying: AnyObject {
    var durationMilliseconds: Int64 { get }
    var elapsedMilliseconds: Int64 { get }
    var onProgress: (@MainActor (Int64) -> Void)? { get set }
    var onCompletion: (@MainActor () -> Void)? { get set }
    func load(url: URL) throws
    func play() throws
    func pause()
    func stop()
    func seek(to milliseconds: Int64) throws
}

enum MeetingAudioPlaybackState: Equatable, Sendable {
    case idle, loading, ready, playing, paused, ended, failed(String)
}

@MainActor
@Observable
final class MeetingAudioPlaybackController {
    private(set) var state: MeetingAudioPlaybackState = .idle
    private(set) var elapsedMilliseconds: Int64 = 0
    private(set) var durationMilliseconds: Int64 = 0
    private(set) var meetingID: UUID?

    @ObservationIgnored private let retention: AudioRetentionController
    @ObservationIgnored private let engine: any MeetingAudioPlaying

    init(retention: AudioRetentionController = AudioRetentionController(), engine: any MeetingAudioPlaying) {
        self.retention = retention
        self.engine = engine
    }

    func load(meetingID: UUID) {
        release()
        self.meetingID = meetingID
        state = .loading
        do {
            let url = try retention.playableRecordingURL(for: meetingID)
            engine.onProgress = { [weak self] milliseconds in self?.updateProgress(milliseconds) }
            engine.onCompletion = { [weak self] in self?.complete() }
            try engine.load(url: url)
            durationMilliseconds = max(0, engine.durationMilliseconds)
            elapsedMilliseconds = min(max(0, engine.elapsedMilliseconds), durationMilliseconds)
            state = .ready
        } catch {
            engine.onProgress = nil
            engine.onCompletion = nil
            self.meetingID = nil
            state = .failed("The retained meeting recording is not available on this Mac.")
        }
    }

    func release() {
        engine.onProgress = nil
        engine.onCompletion = nil
        engine.stop()
        meetingID = nil
        elapsedMilliseconds = 0
        durationMilliseconds = 0
        state = .idle
    }

    func play() {
        guard meetingID != nil else { return }
        do {
            if state == .ended { try engine.seek(to: 0); elapsedMilliseconds = 0 }
            try engine.play()
            state = .playing
        } catch { fail() }
    }

    func pause() {
        guard state == .playing else { return }
        engine.pause()
        elapsedMilliseconds = clamped(engine.elapsedMilliseconds)
        state = .paused
    }

    func toggle() { state == .playing ? pause() : play() }

    func seek(to milliseconds: Int64) {
        guard meetingID != nil else { return }
        let shouldResume = state == .playing
        do {
            let target = clamped(milliseconds)
            try engine.seek(to: target)
            elapsedMilliseconds = target
            if target >= durationMilliseconds, durationMilliseconds > 0 {
                state = .ended
            } else if shouldResume {
                try engine.play()
                state = .playing
            } else {
                state = .paused
            }
        } catch { fail() }
    }

    private func updateProgress(_ milliseconds: Int64) {
        guard meetingID != nil else { return }
        elapsedMilliseconds = clamped(milliseconds)
    }

    private func complete() {
        guard meetingID != nil else { return }
        elapsedMilliseconds = durationMilliseconds
        state = .ended
    }

    private func clamped(_ milliseconds: Int64) -> Int64 {
        min(max(0, milliseconds), durationMilliseconds)
    }

    private func fail() {
        engine.pause()
        state = .failed("The retained meeting recording could not be played.")
    }
}
