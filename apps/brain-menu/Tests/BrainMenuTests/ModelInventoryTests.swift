import Foundation
import Testing
@testable import BrainMenu

struct ModelInventoryTests {
    private let executable = URL(fileURLWithPath: "/safe/bin/voxtype")
    private let workingDirectory = URL(fileURLWithPath: "/safe/Brain/VoxTypeProcess")

    @Test
    func catalogContainsEveryApprovedModelWithExplicitCapabilities() throws {
        #expect(SpeechEngineCatalog.models.map(\.id) == [
            "parakeet-tdt-0.6b-v3",
            "parakeet-unified-en-0.6b",
            "small.en",
            "medium.en",
            "large-v3",
            "large-v3-turbo",
        ])
        #expect(SpeechEngineCatalog.engines.map(\.id) == [.parakeet, .whisper])
        #expect(SpeechEngineCatalog.models.allSatisfy { model in
            model.supportsBatch && model.supportsPreview && model.diskSizeMB > 0
        })

        let tdt = try #require(SpeechEngineCatalog.model(id: "parakeet-tdt-0.6b-v3"))
        #expect(tdt.engine == .parakeet)
        #expect(tdt.languageSupport == .englishOnly)
        #expect(tdt.timestampSupport == .token)
        #expect(tdt.previewSupport == .chunked)
        #expect(tdt.diskSizeMB == 2_600)

        let unified = try #require(
            SpeechEngineCatalog.model(id: "parakeet-unified-en-0.6b")
        )
        #expect(unified.supportsStreamingPreview)
        #expect(unified.diskSizeMB == 2_660)

        let expectedWhisper: [String: (SpeechLanguageSupport, Int)] = [
            "small.en": (.englishOnly, 466),
            "medium.en": (.englishOnly, 1_500),
            "large-v3": (.multilingual, 3_100),
            "large-v3-turbo": (.multilingual, 1_600),
        ]
        for (id, expected) in expectedWhisper {
            let model = try #require(SpeechEngineCatalog.model(id: id))
            #expect(model.engine == .whisper)
            #expect(model.languageSupport == expected.0)
            #expect(model.timestampSupport == .segment)
            #expect(model.previewSupport == .chunked)
            #expect(model.diskSizeMB == expected.1)
        }
    }

    @Test
    func dictationAndMeetingSelectionsPersistIndependently() throws {
        let persistence = MemorySpeechSelectionPersistence()
        let store = SpeechSelectionStore(persistence: persistence, namespace: "test.speech")
        let inventory = snapshot(
            ready: ["small.en", "parakeet-tdt-0.6b-v3", "large-v3-turbo"]
        )
        let dictation = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        let meetings = SpeechEngineSelection(
            engine: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )

        #expect(try store.select(dictation, for: .dictation, inventory: inventory)
            == .activated(dictation))
        #expect(try store.select(meetings, for: .meetings, inventory: inventory)
            == .activated(meetings))

        let changedDictation = SpeechEngineSelection(
            engine: .whisper,
            modelID: "large-v3-turbo"
        )
        _ = try store.select(changedDictation, for: .dictation, inventory: inventory)

        let restored = SpeechSelectionStore(
            persistence: persistence,
            namespace: "test.speech"
        )
        #expect(restored.selection(for: .dictation).active == changedDictation)
        #expect(restored.selection(for: .meetings).active == meetings)
    }

    @Test
    func onlyReadyModelsActivateWhileMissingAndIncompatibleChoicesStayPending() throws {
        let store = SpeechSelectionStore(
            persistence: MemorySpeechSelectionPersistence(),
            namespace: "test.pending"
        )
        let original = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        let missing = SpeechEngineSelection(engine: .whisper, modelID: "medium.en")
        let incompatible = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
        let inventory = ModelInventorySnapshot(availabilityByModelID: [
            original.modelID: .ready,
            missing.modelID: .missing,
            incompatible.modelID: .incompatible,
        ])

        _ = try store.select(original, for: .dictation, inventory: inventory)
        #expect(try store.select(missing, for: .dictation, inventory: inventory)
            == .pending(missing, .missing))
        #expect(store.selection(for: .dictation).active == original)
        #expect(store.selection(for: .dictation).pending == missing)

        #expect(try store.select(incompatible, for: .dictation, inventory: inventory)
            == .pending(incompatible, .incompatible))
        #expect(store.selection(for: .dictation).active == original)
        #expect(store.effectiveSelection(for: .dictation, inventory: inventory) == original)

        let staleInventory = inventory.replacing(.missing, for: original.modelID)
        #expect(store.effectiveSelection(for: .dictation, inventory: staleInventory) == nil)
    }

    @Test
    func parserReportsReadyMissingIncompatibleAndUnknownWithoutTrustingConfiguration() {
        let parsed = ModelInventory.parse(
            """
            Installed Whisper Models
            ========================

              small.en (466 MB) - Better accuracy
              medium.en (1500 MB) - Installed [incompatible]
              future-whisper (42 MB) - Unknown to Brain

            Installed Parakeet Models
            =========================

              parakeet-unified-en-0.6b (2660 MB) - Streaming-capable
            """
        )

        #expect(parsed.availability(for: "small.en") == .ready)
        #expect(parsed.availability(for: "medium.en") == .incompatible)
        #expect(parsed.availability(for: "large-v3") == .missing)
        #expect(parsed.availability(for: "parakeet-unified-en-0.6b") == .ready)
        #expect(parsed.availability(for: "parakeet-tdt-0.6b-v3") == .missing)
        #expect(parsed.availability(for: "future-whisper") == .unknown)

        let wrongSection = ModelInventory.parse(
            """
            Installed Whisper Models
            ========================
              parakeet-tdt-0.6b-v3 (2600 MB) - Wrong engine build
            """
        )
        #expect(wrongSection.availability(for: "parakeet-tdt-0.6b-v3") == .incompatible)

        let unrecognized = ModelInventory.parse("small.en=true\nmedium.en=true")
        #expect(SpeechEngineCatalog.models.allSatisfy {
            unrecognized.availability(for: $0.id) == .unknown
        })

        let changedKnownFormat = ModelInventory.parse(
            """
            Installed Whisper Models
            ========================
            small.en READY
            """
        )
        #expect(changedKnownFormat.availability(for: "small.en") == .unknown)

        let oversizedLine = String(repeating: "x", count: ModelInventory.maximumLineBytes + 1)
        let oversized = ModelInventory.parse("Installed Whisper Models\n\(oversizedLine)")
        #expect(oversized.availability(for: "small.en") == .unknown)
    }

    @Test
    func inventoryUsesOnlyFixedListAndCatalogInstallArgumentArrays() async throws {
        let runner = InventoryProcessRunner(outputs: [
            .success(VoxTypeProcessOutput(stdout: whisperList())),
            .success(VoxTypeProcessOutput(stdout: resolvedConfiguration())),
            .success(VoxTypeProcessOutput()),
            .success(VoxTypeProcessOutput(stdout: whisperList(installed: ["medium.en"]))),
            .success(VoxTypeProcessOutput(stdout: resolvedConfiguration())),
        ])
        let client = VoxTypeClient(
            executableURL: executable,
            runner: runner,
            workingDirectoryURL: workingDirectory,
            environment: ["HOME": "/Users/test", "VOXTYPE_TOKEN": "secret"]
        )
        let inventory = ModelInventory(client: client)

        let initial = await inventory.refresh()
        #expect(initial.availability(for: "parakeet-tdt-0.6b-v3") == .ready)
        let refreshed = try await inventory.install(modelID: "medium.en")
        #expect(refreshed.availability(for: "medium.en") == .ready)

        let requests = await runner.requests
        #expect(requests.map(\.arguments) == [
            ["setup", "model", "--list"],
            ["config"],
            ["setup", "--download", "--model", "medium.en", "--quiet"],
            ["setup", "model", "--list"],
            ["config"],
        ])
        #expect(requests.allSatisfy { request in
            request.executableURL == executable
                && request.currentDirectoryURL == workingDirectory
                && request.standardInput == nil
                && request.maximumOutputBytes == 1_048_576
                && request.environment["VOXTYPE_TOKEN"] == nil
        })
        #expect(requests.map(\.timeout) == [30, 30, 3_600, 30, 30])

        await #expect(throws: ModelInventoryError.unknownModel) {
            try await inventory.install(modelID: "small.en; touch /tmp/nope")
        }
        #expect(await runner.requests.count == 5)
    }

    @Test
    func successfulInstallReportsProgressRefreshesAndPromotesPendingChoice() async throws {
        let client = FakeInventoryClient(
            lists: [
                .output(whisperList()),
                .output(whisperList(installed: ["medium.en"])),
            ],
            installBehavior: .succeed
        )
        let inventory = ModelInventory(client: client)
        let initial = await inventory.refresh()
        let store = SpeechSelectionStore(
            persistence: MemorySpeechSelectionPersistence(),
            namespace: "test.success"
        )
        let original = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        let requested = SpeechEngineSelection(engine: .whisper, modelID: "medium.en")
        let initialWithOriginal = initial.replacing(.ready, for: original.modelID)
        _ = try store.select(original, for: .meetings, inventory: initialWithOriginal)
        _ = try store.select(requested, for: .meetings, inventory: initialWithOriginal)
        let progress = ProgressRecorder()

        let refreshed = try await inventory.install(modelID: requested.modelID) {
            progress.append($0)
        }
        store.reconcile(with: refreshed)

        #expect(await client.listCalls == 2)
        #expect(await client.installedIDs == [requested.modelID])
        #expect(progress.values == [
            .installing(requested.modelID),
            .refreshing(requested.modelID),
            .completed(requested.modelID, .ready),
        ])
        #expect(store.selection(for: .meetings).active == requested)
        #expect(store.selection(for: .meetings).pending == nil)
    }

    @Test
    func cancellationRestoresPriorInventoryAndReportsCancellation() async throws {
        let client = FakeInventoryClient(
            lists: [.output(whisperList(installed: ["small.en"]))],
            installBehavior: .waitForCancellation
        )
        let inventory = ModelInventory(client: client)
        let prior = await inventory.refresh()
        let progress = ProgressRecorder()
        let task = Task {
            try await inventory.install(modelID: "medium.en") {
                progress.append($0)
            }
        }

        await client.waitUntilInstallStarts()
        #expect(await inventory.currentSnapshot().availability(for: "medium.en") == .installing)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(await inventory.currentSnapshot() == prior)
        #expect(progress.values == [.installing("medium.en"), .cancelled("medium.en")])
        #expect(await client.listCalls == 1)
    }

    @Test
    func failedInstallKeepsPriorActiveSelectionAndDoesNotRefresh() async throws {
        let client = FakeInventoryClient(
            lists: [.output(whisperList(installed: ["small.en"]))],
            installBehavior: .fail
        )
        let inventory = ModelInventory(client: client)
        let prior = await inventory.refresh()
        let store = SpeechSelectionStore(
            persistence: MemorySpeechSelectionPersistence(),
            namespace: "test.failure"
        )
        let active = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        let pending = SpeechEngineSelection(engine: .whisper, modelID: "medium.en")
        _ = try store.select(active, for: .dictation, inventory: prior)
        _ = try store.select(pending, for: .dictation, inventory: prior)
        let progress = ProgressRecorder()

        await #expect(throws: ModelInventoryError.installFailed) {
            try await inventory.install(modelID: pending.modelID) {
                progress.append($0)
            }
        }

        #expect(store.selection(for: .dictation).active == active)
        #expect(store.selection(for: .dictation).pending == pending)
        #expect(await inventory.currentSnapshot() == prior)
        #expect(await client.listCalls == 1)
        #expect(progress.values == [.installing(pending.modelID), .failed(pending.modelID)])
    }

    private func snapshot(ready modelIDs: Set<String>) -> ModelInventorySnapshot {
        ModelInventorySnapshot(availabilityByModelID: Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map {
                ($0.id, modelIDs.contains($0.id) ? .ready : .missing)
            }
        ))
    }

    private static func whisperList(installed: [String] = []) -> String {
        let entries = installed.map { "  \($0) (100 MB) - Installed" }.joined(separator: "\n")
        return """
        Installed Whisper Models
        ========================
        \(entries.isEmpty ? "  No models installed." : entries)
        """
    }

    private func whisperList(installed: [String] = []) -> String {
        Self.whisperList(installed: installed)
    }

    private func resolvedConfiguration() -> String {
        """
        Current Configuration
        [parakeet]
          model = "parakeet-tdt-0.6b-v3"
          available models: parakeet-tdt-0.6b-v3
        [output]
          remote_api_key = "must-not-enter-inventory"
        """
    }
}

private final class MemorySpeechSelectionPersistence: SpeechSelectionPersisting {
    private var values: [String: String] = [:]

    func string(forKey defaultName: String) -> String? { values[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? String
    }

    func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}

private actor InventoryProcessRunner: VoxTypeProcessRunning {
    private var outputs: [Result<VoxTypeProcessOutput, Error>]
    private(set) var requests: [VoxTypeProcessRequest] = []

    init(outputs: [Result<VoxTypeProcessOutput, Error>]) {
        self.outputs = outputs
    }

    func run(_ request: VoxTypeProcessRequest) async throws -> VoxTypeProcessOutput {
        requests.append(request)
        guard !outputs.isEmpty else { throw VoxTypeProcessError.launchFailed }
        return try outputs.removeFirst().get()
    }
}

private enum FakeListResult: Sendable {
    case output(String)
    case failure
}

private enum FakeInstallBehavior: Sendable {
    case succeed
    case fail
    case waitForCancellation
}

private actor FakeInventoryClient: VoxTypeModelManaging {
    private var lists: [FakeListResult]
    private let installBehavior: FakeInstallBehavior
    private(set) var listCalls = 0
    private(set) var installedIDs: [String] = []
    private var installStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(lists: [FakeListResult], installBehavior: FakeInstallBehavior) {
        self.lists = lists
        self.installBehavior = installBehavior
    }

    func installedModelList() async throws -> String {
        listCalls += 1
        guard !lists.isEmpty else { throw VoxTypeProcessError.launchFailed }
        switch lists.removeFirst() {
        case .output(let output): return output
        case .failure: throw VoxTypeProcessError.launchFailed
        }
    }

    func installModel(id: String) async throws {
        installedIDs.append(id)
        let waiters = installStartWaiters
        installStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        switch installBehavior {
        case .succeed:
            return
        case .fail:
            throw VoxTypeProcessError.launchFailed
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    func waitUntilInstallStarts() async {
        if !installedIDs.isEmpty { return }
        await withCheckedContinuation { continuation in
            installStartWaiters.append(continuation)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [ModelInstallProgress] = []

    var values: [ModelInstallProgress] { lock.withLock { recordedValues } }

    func append(_ value: ModelInstallProgress) {
        lock.withLock { recordedValues.append(value) }
    }
}
