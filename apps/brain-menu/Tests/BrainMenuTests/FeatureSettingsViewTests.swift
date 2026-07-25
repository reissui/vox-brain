import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct FeatureSettingsViewTests {
    @Test
    func freshSpeechSettingsUseABundledCompatibleWhisperDefaultForBothWorkflows() throws {
        let controller = speechController(snapshot: readySnapshot())
        let expected = SpeechEngineSelection(
            engine: .whisper,
            modelID: "small.en"
        )

        #expect(SpeechEngineCatalog.englishDefaultModelID == "small.en")
        #expect(controller.selection(for: .dictation) == expected)
        #expect(controller.selection(for: .meetings) == expected)
        #expect(OnboardingController.defaultDictationModelID == expected.modelID)
        #expect(OnboardingController.defaultMeetingModelID == expected.modelID)

        let recommended = try #require(
            SpeechEngineCatalog.model(id: SpeechEngineCatalog.englishDefaultModelID)
        )
        let multilingual = try #require(
            SpeechEngineCatalog.model(id: SpeechEngineCatalog.multilingualFallbackModelID)
        )
        #expect(recommended.recommendation?.title == "Recommended")
        #expect(recommended.engine == .whisper)
        #expect(recommended.recommendation?.detail.contains("bundled") == true)
        #expect(multilingual.recommendation?.title == "Multilingual fallback")
        #expect(SpeechEngineCatalog.modelGuideURL.absoluteString
            == "https://voxtype.io/docs/MODEL_SELECTION_GUIDE")
    }

    @Test
    func firstReadyRefreshAppliesAndPersistsBundledCompatibleDefaultForBothWorkflows() async {
        let snapshot = readySnapshot()
        let activator = FeatureModelActivator()
        let controller = SpeechSettingsController(
            voxType: FeatureVoxTypeController(
                version: VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil),
                status: .available(VoxTypeStatusSnapshot(
                    state: .idle,
                    model: "small.en",
                    device: nil,
                    backend: nil
                ))
            ),
            inventory: FeatureInventory(snapshot: snapshot),
            selections: featureSpeechStore(namespace: "feature.fresh-runtime"),
            modelActivator: activator
        )

        await controller.refresh()
        await controller.waitForPendingModelApplication()

        let expected = SpeechEngineSelection(
            engine: .whisper,
            modelID: SpeechEngineCatalog.englishDefaultModelID
        )
        #expect(activator.applied == [expected])
        #expect(controller.activeSelection(for: .dictation) == expected)
        #expect(controller.activeSelection(for: .meetings) == expected)
    }

    @Test
    func refreshRepairsTheShippedParakeetSelectionBeforePushToTalkIsUsed() async {
        let snapshot = ModelInventorySnapshot(availabilityByModelID: [
            "parakeet-tdt-0.6b-v3": .ready,
            SpeechEngineCatalog.englishDefaultModelID: .missing,
        ])
        let inventory = FeatureInventory(snapshot: snapshot)
        let activator = FeatureModelActivator()
        let controller = SpeechSettingsController(
            voxType: FeatureVoxTypeController(
                version: SpeechSettingsController.parakeetIncompatibleBundledVersion,
                status: .available(VoxTypeStatusSnapshot(
                    state: .idle,
                    model: "parakeet-tdt-0.6b-v3",
                    device: nil,
                    backend: nil
                ))
            ),
            inventory: inventory,
            selections: featureSpeechStore(namespace: "feature.repair"),
            modelActivator: activator
        )

        await controller.refresh()

        let repaired = SpeechEngineSelection(
            engine: .whisper,
            modelID: SpeechEngineCatalog.englishDefaultModelID
        )
        #expect(await inventory.installedModelIDs == [repaired.modelID])
        #expect(activator.applied == [repaired])
        #expect(controller.activeSelection(for: .dictation) == repaired)
        #expect(controller.activeSelection(for: .meetings) == repaired)
    }

    @Test
    func speechRowsExposeEveryReadinessStateCapabilitiesAndAccessibilityText() {
        let snapshot = ModelInventorySnapshot(availabilityByModelID: [
            "parakeet-tdt-0.6b-v3": .ready,
            "parakeet-unified-en-0.6b": .missing,
            "small.en": .installing,
            "medium.en": .incompatible,
            "large-v3": .unknown,
        ])
        let controller = speechController(snapshot: snapshot)
        let rows = Dictionary(uniqueKeysWithValues: controller.modelRows.map { ($0.id, $0) })

        #expect(rows["parakeet-tdt-0.6b-v3"]?.stateTitle == "Ready")
        #expect(rows["parakeet-unified-en-0.6b"]?.stateTitle == "Not installed")
        #expect(rows["small.en"]?.stateTitle == "Installing")
        #expect(rows["medium.en"]?.stateTitle == "Incompatible")
        #expect(rows["large-v3"]?.stateTitle == "Availability unknown")
        #expect(rows["parakeet-unified-en-0.6b"]?.canInstall == true)
        #expect(rows["medium.en"]?.canInstall == true)
        #expect(rows["large-v3"]?.canInstall == false)
        #expect(rows["large-v3"]?.stateTitle != "Ready")

        let streaming = rows["parakeet-unified-en-0.6b"]
        #expect(streaming?.capabilities.map(\.title).contains("Streaming preview") == true)
        #expect(streaming?.capabilities.map(\.title).contains("Batch") == true)
        #expect(streaming?.accessibilityLabel.contains("model state: Not installed") == true)
        #expect(rows["medium.en"]?.accessibilityLabel.contains("Incompatible") == true)
    }

    @Test
    func missingAndIncompatibleChoicesStayPendingUntilGuidedInstallCompletes() async throws {
        let original = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        let missing = SpeechEngineSelection(engine: .whisper, modelID: "medium.en")
        let incompatible = SpeechEngineSelection(engine: .whisper, modelID: "large-v3")
        let snapshot = ModelInventorySnapshot(availabilityByModelID: [
            original.modelID: .ready,
            missing.modelID: .missing,
            incompatible.modelID: .incompatible,
        ])
        let persistence = MemoryFeatureSpeechPersistence()
        let selections = SpeechSelectionStore(
            persistence: persistence,
            namespace: "feature.pending"
        )
        _ = try selections.select(original, for: .dictation, inventory: snapshot)
        let inventory = FeatureInventory(snapshot: snapshot)
        let controller = SpeechSettingsController(
            voxType: nil,
            inventory: inventory,
            selections: selections,
            initialSnapshot: snapshot
        )

        controller.selectModel(missing.modelID, for: .dictation)
        #expect(controller.activeSelection(for: .dictation) == original)
        #expect(controller.selection(for: .dictation) == missing)

        controller.selectModel(incompatible.modelID, for: .meetings)
        #expect(controller.activeSelection(for: .meetings) == nil)
        #expect(controller.selection(for: .meetings) == incompatible)

        await controller.installModel(missing.modelID)
        #expect(await inventory.installedModelIDs == [missing.modelID])
        #expect(controller.activeSelection(for: .dictation) == missing)
        #expect(controller.inventorySnapshot.availability(for: missing.modelID) == .ready)

        await controller.installModel(incompatible.modelID)
        #expect(await inventory.installedModelIDs == [missing.modelID, incompatible.modelID])
        #expect(controller.activeSelection(for: .meetings) == incompatible)
    }

    @Test
    func dictationAndMeetingsSelectorsRemainIndependent() {
        let snapshot = readySnapshot()
        let controller = speechController(snapshot: snapshot)

        controller.selectModel("medium.en", for: .dictation)
        controller.selectModel("parakeet-unified-en-0.6b", for: .meetings)

        #expect(controller.selection(for: .dictation)
            == SpeechEngineSelection(engine: .whisper, modelID: "medium.en"))
        #expect(controller.selection(for: .meetings)
            == SpeechEngineSelection(engine: .parakeet, modelID: "parakeet-unified-en-0.6b"))
    }

    @Test
    func readySelectionStaysApplyingUntilConfirmedAndRapidChoiceCancelsStaleWork() async throws {
        let snapshot = readySnapshot()
        let persistence = MemoryFeatureSpeechPersistence()
        let selections = SpeechSelectionStore(
            persistence: persistence,
            namespace: "feature.apply"
        )
        let original = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        try selections.activate(original, for: .dictation)
        let activator = FeatureModelActivator(blockedModelID: "medium.en")
        let controller = SpeechSettingsController(
            voxType: nil,
            inventory: FeatureInventory(snapshot: snapshot),
            selections: selections,
            modelActivator: activator,
            initialSnapshot: snapshot
        )

        controller.selectModel("medium.en", for: .dictation)
        #expect(controller.modelApplicationState(for: .dictation)
            == .applying(SpeechEngineSelection(engine: .whisper, modelID: "medium.en")))
        #expect(controller.activeSelection(for: .dictation) == original)
        await featureEventually { activator.applied.count == 1 }

        let newest = SpeechEngineSelection(engine: .whisper, modelID: "large-v3-turbo")
        controller.selectModel(newest.modelID, for: .dictation)
        await controller.waitForPendingModelApplication()

        #expect(activator.applied == [
            SpeechEngineSelection(engine: .whisper, modelID: "medium.en"),
            newest,
        ])
        #expect(activator.cancelledModelIDs == ["medium.en"])
        #expect(controller.activeSelection(for: .dictation) == newest)
        #expect(controller.modelApplicationState(for: .dictation) == .applied(newest))
    }

    @Test
    func applyFailureKeepsPreviousSelectionAndShowsActionableRollbackState() async throws {
        let snapshot = readySnapshot()
        let selections = featureSpeechStore(namespace: "feature.rollback")
        let original = SpeechEngineSelection(engine: .whisper, modelID: "small.en")
        try selections.activate(original, for: .meetings)
        let activator = FeatureModelActivator(failure: .timedOut)
        let controller = SpeechSettingsController(
            voxType: nil,
            inventory: FeatureInventory(snapshot: snapshot),
            selections: selections,
            modelActivator: activator,
            initialSnapshot: snapshot
        )
        let requested = SpeechEngineSelection(
            engine: .parakeet,
            modelID: "parakeet-tdt-0.6b-v3"
        )

        controller.selectModel(requested.modelID, for: .meetings)
        await controller.waitForPendingModelApplication()

        #expect(controller.activeSelection(for: .meetings) == original)
        #expect(controller.modelApplicationState(for: .meetings)
            == .failed(requested, VoxTypeModelApplyError.timedOut.localizedDescription))
        #expect(controller.errorMessage?.contains("15 seconds") == true)
    }

    @Test
    func speechRefreshShowsInstallationVersionDaemonAndFailsUnknownInventoryClosed() async {
        let inventory = FeatureInventory(snapshot: .unknown)
        let voxType = FeatureVoxTypeController(
            version: VoxTypeVersion(major: 2, minor: 4, patch: 1, prerelease: nil),
            status: .available(VoxTypeStatusSnapshot(
                state: .idle,
                model: "small.en",
                device: "Default Microphone",
                backend: "CPU"
            ))
        )
        let controller = SpeechSettingsController(
            voxType: voxType,
            inventory: inventory,
            selections: featureSpeechStore(namespace: "feature.refresh")
        )

        await controller.refresh()

        #expect(controller.installationState
            == .installed(VoxTypeVersion(major: 2, minor: 4, patch: 1, prerelease: nil)))
        #expect(controller.installationState.accessibilityLabel.contains("2.4.1"))
        #expect(controller.daemonState == .running(.idle))
        #expect(controller.daemonState.accessibilityLabel.contains("Running"))
        #expect(controller.hotkeyState == .configured(
            VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
        ))
        #expect(controller.hotkeyState.detail.contains("only displays"))
        #expect(controller.modelRows.allSatisfy { $0.availability == .unknown })
        #expect(controller.modelRows.allSatisfy { $0.stateTitle != "Ready" })
    }

    @Test
    func speechHardwareActionsUseInjectedHandler() async {
        let actions = FeatureSpeechActions()
        let controller = speechController(
            snapshot: readySnapshot(),
            actions: actions
        )

        await controller.testMicrophone()
        await controller.testSystemAudio()

        #expect(controller.microphoneTest == .ready("Input level detected"))
        #expect(controller.systemAudioTest == .failed("Permission required"))
        #expect(await actions.microphoneTests == 1)
        #expect(await actions.systemAudioTests == 1)
    }

    @Test
    func microphoneInventoryPersistsPinnedUIDAndFiveSecondTestPublishesLiveLevel() async throws {
        let suite = "FeatureSettingsViewTests.Microphone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FeatureMicrophoneService()
        let selectionStore = MeetingMicrophoneSelectionStore(defaults: defaults)
        let controller = SpeechSettingsController(
            voxType: nil,
            inventory: FeatureInventory(snapshot: readySnapshot()),
            selections: featureSpeechStore(namespace: "feature.microphone"),
            microphoneService: service,
            microphoneSelectionStore: selectionStore,
            initialSnapshot: readySnapshot()
        )

        await controller.refresh()
        #expect(controller.microphoneInventory.devices.map(\.id) == ["built-in", "usb-desk"])
        #expect(controller.selectedMicrophoneDetail.contains("Built-in Microphone"))

        controller.selectMicrophone(.device(uid: "usb-desk"))
        #expect(MeetingMicrophoneSelectionStore(defaults: defaults).selection == .device(uid: "usb-desk"))
        #expect(controller.selectedMicrophoneDetail.contains("Pinned"))
        await controller.testMicrophone()

        #expect(controller.microphoneTest == .ready("Voice detected"))
        #expect(controller.microphoneTestLevel == 0.42)
        #expect(await service.selections == [.device(uid: "usb-desk")])
        #expect(await service.durations == [.seconds(5)])
    }

    @Test
    func aiOffersEveryProviderAndReadyTestUnlocksOnlyTheExactConfiguration() async {
        let settings = FeatureAISettings()
        let controller = AISettingsController(
            settings: settings,
            providerFactory: FeatureAIProviderFactory(state: .ready),
            executableResolver: FeatureExecutableResolver(paths: [
                .codex: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            ])
        )

        #expect(AIProvider.allCases.map(\.displayName) == [
            "Disabled", "Codex CLI", "Claude CLI", "Custom Command",
        ])
        #expect(controller.canSave == false)
        controller.selectProvider(.codex)
        #expect(controller.usesPreset)
        #expect(controller.exposesManualConfiguration == false)
        #expect(controller.resolvedExecutablePath == "/opt/homebrew/bin/codex")
        #expect(controller.commandPreview == "/opt/homebrew/bin/codex exec --skip-git-repo-check --ephemeral --sandbox read-only --ignore-user-config --ignore-rules --output-schema <Brain schema> -")
        #expect(controller.configuration.executableURL == nil)
        #expect(controller.configuration.arguments.isEmpty)
        #expect(controller.configuration.model == nil)
        controller.model = "gpt-5.4-mini"
        #expect(controller.configuration.model == "gpt-5.4-mini")
        #expect(controller.commandPreview?.contains("--model gpt-5.4-mini -") == true)
        controller.configuration.timeout = 450
        controller.configuration.contextChoice = .plain
        #expect(controller.providerHelp.contains("Codex CLI sign-in"))
        #expect(controller.canSave == false)

        await controller.testConnection()
        #expect(controller.testState == .result(.ready))
        #expect(controller.testState.accessibilityLabel.contains("state: Ready"))
        #expect(controller.canSave)
        controller.save()
        #expect(settings.savedConfigurations == [controller.configuration])

        controller.configuration.timeout = 451
        #expect(controller.testState == .untested)
        #expect(controller.canSave == false)

        controller.selectProvider(.claude)
        #expect(controller.providerHelp.contains("Claude CLI sign-in"))
        controller.selectProvider(.advanced)
        #expect(controller.exposesManualConfiguration)
        controller.customCommand = "codex exec --skip-git-repo-check --model gpt-5.4-mini -"
        #expect(controller.configuration.executableURL?.path == "/opt/homebrew/bin/codex")
        #expect(controller.configuration.arguments == [
            "exec", "--skip-git-repo-check", "--model", "gpt-5.4-mini", "-",
        ])
        #expect(controller.commandErrorMessage == nil)
        #expect(controller.providerHelp.contains("never through a shell"))
    }

    @Test
    func missingAuthAndInvalidModelRemainExplicitAndKeepSaveDisabled() async {
        let auth = AISettingsController(
            settings: FeatureAISettings(configuration: AIProviderConfiguration(provider: .codex)),
            providerFactory: FeatureAIProviderFactory(state: .unauthenticated)
        )
        await auth.testConnection()
        #expect(auth.testState == .result(.unauthenticated))
        #expect(auth.testState.title == "Sign-in required")
        #expect(auth.testDetail == "codex login --device-auth")
        #expect(auth.testAccessibilityLabel.contains("codex login --device-auth"))
        #expect(auth.canSave == false)

        let model = AISettingsController(
            settings: FeatureAISettings(configuration: AIProviderConfiguration(
                provider: .claude,
                model: "unavailable-model"
            )),
            providerFactory: FeatureAIProviderFactory(state: .invalidModel)
        )
        await model.testConnection()
        #expect(model.testState == .result(.invalidModel))
        #expect(model.testState.accessibilityLabel.contains("Invalid model"))
        #expect(model.canSave == false)

        let missing = AISettingsController(
            settings: FeatureAISettings(configuration: AIProviderConfiguration(provider: .codex)),
            providerFactory: FeatureAIProviderFactory(state: .missingExecutable)
        )
        await missing.testConnection()
        #expect(missing.testDetail == "Codex CLI was not found. Install Codex or ChatGPT, then test again.")

        let invalidResponse = AISettingsController(
            settings: FeatureAISettings(configuration: AIProviderConfiguration(provider: .codex)),
            providerFactory: FeatureAIProviderFactory(state: .schemaFailure)
        )
        await invalidResponse.testConnection()
        #expect(invalidResponse.testState.title == "Invalid response")
    }

    @Test
    func clearRemovesOnlyAISettingsAndDoesNotTouchCredentialLikeDefaults() async throws {
        let suite = "FeatureSettingsViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existing-cli-login-marker", forKey: "provider.cli.credentials")
        let store = AISettingsStore(defaults: defaults)
        try store.save(AIProviderConfiguration(provider: .codex, model: "gpt-5.4-mini"))
        let controller = AISettingsController(
            settings: store,
            providerFactory: FeatureAIProviderFactory(state: .ready)
        )

        controller.clear()

        #expect(store.load().provider == .disabled)
        #expect(defaults.string(forKey: "provider.cli.credentials") == "existing-cli-login-marker")
        #expect(controller.savedMessage?.contains("credentials were not changed") == true)
        #expect(controller.canSave == false)
    }

    @Test
    func successfullyTestedAndSavedAISettingsRemainReadyAfterReopening() async throws {
        let suite = "FeatureSettings.ValidatedAI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AISettingsStore(defaults: defaults)
        let controller = AISettingsController(
            settings: store,
            providerFactory: FeatureAIProviderFactory(state: .ready)
        )
        controller.selectProvider(.codex)
        await controller.testConnection()
        controller.save()

        let reopened = AISettingsController(settings: store)

        #expect(reopened.configuration.provider == .codex)
        #expect(reopened.testState == .result(.ready))
        #expect(reopened.canSave)
    }

    @Test
    func settingsViewsContainNoDirectSubprocessBoundary() throws {
        let views = sourceRoot.appendingPathComponent("Views", isDirectory: true)
        for name in ["SpeechSettingsView.swift", "AISettingsView.swift"] {
            let source = try String(
                contentsOf: views.appendingPathComponent(name),
                encoding: .utf8
            )
            #expect(!source.contains("Process()"))
            #expect(!source.contains("/bin/sh"))
            #expect(!source.contains("LocalCLIProcessRunner"))
            #expect(!source.contains("ProcessVoxTypeRunner"))
        }

        let aiSource = try String(
            contentsOf: views.appendingPathComponent("AISettingsView.swift"),
            encoding: .utf8
        )
        #expect(aiSource.contains("if controller.usesPreset"))
        #expect(aiSource.contains("controller.customCommand"))
        #expect(aiSource.contains("AI Setup"))
        #expect(aiSource.contains("Current choice"))
        #expect(aiSource.contains("CLI Tool"))
        #expect(aiSource.contains("controller.commandPreview"))
    }

    @Test
    func speechAndAISettingsExposeApplyingMissingMicrophoneAndErrorFocus() throws {
        let speech = try String(
            contentsOf: sourceRoot.appendingPathComponent("Views/SpeechSettingsView.swift"),
            encoding: .utf8
        )
        let ai = try String(
            contentsOf: sourceRoot.appendingPathComponent("Views/AISettingsView.swift"),
            encoding: .utf8
        )

        #expect(speech.contains("brainAccessibleStatus(\n                    .applyingModel"))
        #expect(speech.contains("BrainWorkflowAccessibilityState.microphoneMissing"))
        #expect(speech.contains("accessibilityFocused($errorIsFocused)"))
        #expect(speech.contains("accessibilityValue(controller.selectedMicrophoneDetail)"))
        #expect(ai.contains("accessibilityFocused($accessibilityFocus, equals: .primaryField)"))
        #expect(ai.contains("accessibilityFocused($accessibilityFocus, equals: .errorSummary)"))
        #expect(ai.contains("accessibilityHint(\"Removes Brain's provider settings"))
    }

    private func speechController(
        snapshot: ModelInventorySnapshot,
        actions: any SpeechSettingsActionHandling = UnavailableSpeechSettingsActions()
    ) -> SpeechSettingsController {
        SpeechSettingsController(
            voxType: nil,
            inventory: FeatureInventory(snapshot: snapshot),
            selections: featureSpeechStore(namespace: "feature.\(UUID().uuidString)"),
            actions: actions,
            initialSnapshot: snapshot
        )
    }

    private func readySnapshot() -> ModelInventorySnapshot {
        ModelInventorySnapshot(availabilityByModelID: Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map { ($0.id, .ready) }
        ))
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu", isDirectory: true)
    }
}

@MainActor
private func featureEventually(
    attempts: Int = 200,
    _ condition: () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}

@MainActor
private final class FeatureModelActivator: VoxTypeModelApplying {
    let blockedModelID: String?
    let failure: VoxTypeModelApplyError?
    private(set) var applied: [SpeechEngineSelection] = []
    private(set) var cancelledModelIDs: [String] = []

    init(
        blockedModelID: String? = nil,
        failure: VoxTypeModelApplyError? = nil
    ) {
        self.blockedModelID = blockedModelID
        self.failure = failure
    }

    func apply(_ selection: SpeechEngineSelection) async throws {
        applied.append(selection)
        if selection.modelID == blockedModelID {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancelledModelIDs.append(selection.modelID)
                throw CancellationError()
            }
        }
        if let failure { throw failure }
    }
}

private func featureSpeechStore(namespace: String) -> SpeechSelectionStore {
    SpeechSelectionStore(
        persistence: MemoryFeatureSpeechPersistence(),
        namespace: namespace
    )
}

private final class MemoryFeatureSpeechPersistence: SpeechSelectionPersisting {
    private var values: [String: String] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? String
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

private actor FeatureInventory: SpeechModelInventoryControlling {
    private var snapshot: ModelInventorySnapshot
    private(set) var installedModelIDs: [String] = []

    init(snapshot: ModelInventorySnapshot) {
        self.snapshot = snapshot
    }

    func refresh() async -> ModelInventorySnapshot {
        snapshot
    }

    func install(
        modelID: String,
        progress: @Sendable (ModelInstallProgress) -> Void
    ) async throws -> ModelInventorySnapshot {
        guard SpeechEngineCatalog.model(id: modelID) != nil else {
            throw ModelInventoryError.unknownModel
        }
        installedModelIDs.append(modelID)
        progress(.installing(modelID))
        progress(.refreshing(modelID))
        snapshot = snapshot.replacing(.ready, for: modelID)
        progress(.completed(modelID, .ready))
        return snapshot
    }
}

private actor FeatureVoxTypeController: VoxTypeControlling {
    let configuredVersion: VoxTypeVersion
    let configuredStatus: VoxTypeStatus

    init(version: VoxTypeVersion, status: VoxTypeStatus) {
        configuredVersion = version
        configuredStatus = status
    }

    func version() async throws -> VoxTypeVersion { configuredVersion }
    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
    }
    func status() async -> VoxTypeStatus { configuredStatus }
    func startRecordingForPaste() async throws {}
    func stopRecordingForPaste() async throws {}
    func cancelRecording() async throws {}
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }
}

private actor FeatureSpeechActions: SpeechSettingsActionHandling {
    private(set) var microphoneTests = 0
    private(set) var systemAudioTests = 0

    func testMicrophone() async -> SpeechHardwareTestResult {
        microphoneTests += 1
        return .ready("Input level detected")
    }

    func testSystemAudio() async -> SpeechHardwareTestResult {
        systemAudioTests += 1
        return .failed("Permission required")
    }

}

private actor FeatureMicrophoneService: MeetingMicrophoneSettingsServing {
    private(set) var selections: [MeetingMicrophoneSelection] = []
    private(set) var durations: [Duration] = []

    func inventory() async throws -> MeetingMicrophoneInventorySnapshot {
        MeetingMicrophoneInventorySnapshot(
            devices: [
                MeetingMicrophoneDevice(
                    id: "built-in",
                    name: "Built-in Microphone",
                    coreAudioID: 1,
                    isSystemDefault: true
                ),
                MeetingMicrophoneDevice(
                    id: "usb-desk",
                    name: "USB Desk Mic",
                    coreAudioID: 2,
                    isSystemDefault: false
                ),
            ],
            defaultDeviceUID: "built-in"
        )
    }

    func test(
        selection: MeetingMicrophoneSelection,
        duration: Duration,
        levelHandler: @escaping @Sendable (Float) -> Void
    ) async -> SpeechHardwareTestResult {
        selections.append(selection)
        durations.append(duration)
        levelHandler(0.42)
        await Task.yield()
        return .ready("Voice detected")
    }
}

private final class FeatureAISettings: AISettingsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: AIProviderConfiguration
    private var saved: [AIProviderConfiguration] = []

    init(configuration: AIProviderConfiguration = AIProviderConfiguration()) {
        storedConfiguration = configuration
    }

    var savedConfigurations: [AIProviderConfiguration] {
        lock.withLock { saved }
    }

    func load() -> AIProviderConfiguration {
        lock.withLock { storedConfiguration }
    }

    func save(_ configuration: AIProviderConfiguration) throws {
        lock.withLock {
            storedConfiguration = configuration
            saved.append(configuration)
        }
    }

    func clear() {
        lock.withLock {
            storedConfiguration = AIProviderConfiguration()
        }
    }
}

private struct FeatureAIProviderFactory: AIProviderMaking {
    let state: AIConnectionState

    func makeProvider(configuration: AIProviderConfiguration) -> any AIProviding {
        FeatureAIProvider(state: state)
    }
}

private struct FeatureAIProvider: AIProviding {
    let state: AIConnectionState

    func run(prompt: String, jsonSchema: Data) async throws -> Data {
        Data()
    }

    func testConnection() async -> AIConnectionState {
        state
    }
}

private struct FeatureExecutableResolver: AIExecutableResolving {
    let paths: [AIProvider: URL]

    func resolveExecutable(for provider: AIProvider) -> URL? {
        paths[provider]
    }
}
