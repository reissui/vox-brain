import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct MeetingLiveCaptionsTests {
    @Test
    func freshInstallLeavesLiveCaptionsOff() throws {
        let defaults = try liveCaptionsDefaults("fresh")
        let store = MeetingLiveCaptionsStore(defaults: defaults)

        #expect(store.isEnabled == false)
        #expect(SpeechEngineCatalog.livePreviewModelID == "small.en")
        #expect(SpeechEngineCatalog.model(id: SpeechEngineCatalog.livePreviewModelID)?.engine
            == .whisper)
    }

    @Test
    func captionsChoicePersistsIndependentlyOfTheSpeechModel() throws {
        let defaults = try liveCaptionsDefaults("persist")
        let store = MeetingLiveCaptionsStore(defaults: defaults)
        store.setEnabled(true)

        #expect(MeetingLiveCaptionsStore(defaults: defaults).isEnabled)
        store.setEnabled(false)
        #expect(MeetingLiveCaptionsStore(defaults: defaults).isEnabled == false)
    }

    @Test
    @MainActor
    func emptyLiveTranscriptExplainsRecordFirstWhenCaptionsAreOff() {
        let meeting = MeetingRecord(
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 100),
            lifecycleState: .recording,
            speechEngine: "whisper",
            speechModel: "large-v3"
        )
        let off = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: meeting,
            lifecycleState: .recording,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [.microphone: 0.4],
            signalStates: [.microphone: .active],
            now: Date(timeIntervalSince1970: 130),
            liveCaptionsEnabled: false
        ))
        #expect(off.isReceivingAudio)
        #expect(off.liveCaptionsEnabled == false)
        #expect(off.emptyTranscriptTitle == "Recording without live captions")
        #expect(off.emptyTranscriptDescription.contains("after you stop"))
        #expect(!off.emptyTranscriptDescription.contains("preview appears"))

        let on = MeetingLiveViewModel(snapshot: MeetingLiveSnapshot(
            meeting: meeting,
            lifecycleState: .recording,
            utterances: [],
            previewLag: .current,
            transcriptFailures: [],
            controllerFailure: nil,
            levels: [.microphone: 0.4],
            signalStates: [.microphone: .active],
            now: Date(timeIntervalSince1970: 130),
            liveCaptionsEnabled: true
        ))
        #expect(on.liveCaptionsEnabled)
        #expect(on.emptyTranscriptTitle == "Audio is being received")
        #expect(on.emptyTranscriptDescription.contains("preview appears"))
    }

    private func liveCaptionsDefaults(_ label: String) throws -> UserDefaults {
        let suite = "MeetingLiveCaptionsTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
