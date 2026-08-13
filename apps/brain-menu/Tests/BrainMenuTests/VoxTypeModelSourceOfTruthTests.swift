import Foundation
import Testing
@testable import BrainMenu

@MainActor
@Suite(.serialized)
struct VoxTypeModelSourceOfTruthTests {
    @Test
    func migrationUsesReportedThenMeetingThenDictationThenLargeV3() throws {
        let ready = ModelInventorySnapshot(availabilityByModelID: [
            "large-v3": .ready,
            "medium.en": .ready,
            "small.en": .ready,
        ])

        let reportedPersistence = ModelTruthPersistence()
        let reportedLegacy = SpeechSelectionStore(
            persistence: reportedPersistence,
            namespace: "legacy"
        )
        try reportedLegacy.activate(.init(engine: .whisper, modelID: "medium.en"), for: .meetings)
        try reportedLegacy.activate(.init(engine: .whisper, modelID: "small.en"), for: .dictation)
        let reported = VoxTypeModelSourceOfTruth(
            persistence: reportedPersistence,
            namespace: "global",
            legacySelections: reportedLegacy
        )
        #expect(try reported.migrateIfNeeded(
            status: status("large-v3"),
            inventory: ready
        ) == .init(engine: .whisper, modelID: "large-v3"))

        let legacyPersistence = ModelTruthPersistence()
        let legacy = SpeechSelectionStore(persistence: legacyPersistence, namespace: "legacy")
        try legacy.activate(.init(engine: .whisper, modelID: "medium.en"), for: .meetings)
        try legacy.activate(.init(engine: .whisper, modelID: "small.en"), for: .dictation)
        let meeting = VoxTypeModelSourceOfTruth(
            persistence: legacyPersistence,
            namespace: "global",
            legacySelections: legacy
        )
        #expect(try meeting.migrateIfNeeded(
            status: status("not-in-catalog"),
            inventory: ready
        ) == .init(engine: .whisper, modelID: "medium.en"))
    }

    @Test
    func freshMigrationDefaultsToLargeV3() throws {
        let persistence = ModelTruthPersistence()
        let source = VoxTypeModelSourceOfTruth(
            persistence: persistence,
            namespace: "fresh",
            legacySelections: SpeechSelectionStore(
                persistence: persistence,
                namespace: "legacy"
            )
        )
        let selection = try source.migrateIfNeeded(
            status: .unavailable(.daemonNotRunning),
            inventory: ModelInventorySnapshot(availabilityByModelID: ["large-v3": .ready])
        )
        #expect(selection == .init(engine: .whisper, modelID: "large-v3"))
        #expect(source.selection == selection)
    }

    @Test
    func activationPersistsOnlyAfterExactStatusAttestation() async throws {
        let persistence = ModelTruthPersistence()
        let activator = ModelTruthActivator()
        let voxType = ModelTruthVoxType(model: "large-v3")
        let verifiedAt = Date(timeIntervalSince1970: 42)
        let source = VoxTypeModelSourceOfTruth(
            persistence: persistence,
            namespace: "active",
            activator: activator,
            voxType: voxType,
            now: { verifiedAt }
        )
        let requested = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
        let attestation = try await source.activate(requested)

        #expect(source.selection == requested)
        #expect(attestation.requestedSelection == requested)
        #expect(attestation.effectiveSelection == requested)
        #expect(attestation.verifiedAt == verifiedAt)
        #expect(attestation.voxTypeVersion.description == "0.7.5")
        #expect(activator.values == [requested])
    }

    @Test
    func mismatchDoesNotReplacePriorGlobalSelection() async throws {
        let persistence = ModelTruthPersistence()
        let original = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
        persistence.set(original.engine.rawValue, forKey: "active.engine")
        persistence.set(original.modelID, forKey: "active.model")
        let source = VoxTypeModelSourceOfTruth(
            persistence: persistence,
            namespace: "active",
            activator: ModelTruthActivator(),
            voxType: ModelTruthVoxType(model: "small.en")
        )
        let requested = SpeechEngineSelection(engine: .whisper, modelID: "medium.en")

        await #expect(throws: VoxTypeModelAttestationError.modelMismatch(
            requested: "medium.en",
            effective: "small.en"
        )) {
            try await source.activate(requested)
        }
        #expect(source.selection == original)
    }

    @Test
    func legacyMeetingDecodesOldSpeechFieldsAsUnverified() throws {
        let legacy = MeetingRecord(
            title: "Legacy",
            startedAt: Date(timeIntervalSince1970: 1),
            lifecycleState: .completed,
            speechEngine: "whisper",
            speechModel: "small.en"
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "requestedSpeechSelection",
            "effectiveSpeechSelection",
            "speechVerificationState",
            "speechVerifiedAt",
            "voxTypeVersion",
        ] {
            object[key] = nil
        }
        let decoded = try JSONDecoder().decode(
            MeetingRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        let legacySelection = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        #expect(decoded.requestedSpeechSelection == legacySelection)
        #expect(decoded.effectiveSpeechSelection == legacySelection)
        #expect(decoded.speechVerificationState == .unverifiedLegacy)
        #expect(decoded.speechVerifiedAt == nil)
        #expect(decoded.voxTypeVersion == nil)
    }

    private func status(_ model: String) -> VoxTypeStatus {
        .available(.init(state: .idle, model: model, device: nil, backend: nil))
    }
}

private final class ModelTruthPersistence: SpeechSelectionPersisting {
    private var values: [String: String] = [:]
    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

@MainActor
private final class ModelTruthActivator: VoxTypeModelApplying {
    private(set) var values: [SpeechEngineSelection] = []
    func apply(_ selection: SpeechEngineSelection) async throws { values.append(selection) }
}

private actor ModelTruthVoxType: VoxTypeControlling {
    let model: String
    init(model: String) { self.model = model }
    func version() async throws -> VoxTypeVersion {
        .init(major: 0, minor: 7, patch: 5, prerelease: nil)
    }
    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        .init(key: "FN", modifiers: [], mode: "PushToTalk")
    }
    func status() async -> VoxTypeStatus {
        .available(.init(state: .idle, model: model, device: nil, backend: nil))
    }
    func startRecordingForPaste() async throws {}
    func stopRecordingForPaste() async throws {}
    func cancelRecording() async throws {}
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }
}
