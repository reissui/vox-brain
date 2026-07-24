import Foundation
import SwiftUI
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct AppIntegrationTests {
    @Test
    func dashboardKeepsPrimaryWorkflowsAndSettingsOwnsIntegratedUtilities() {
        #expect(DashboardSection.allCases == [
            .overview,
            .capture,
            .activity,
            .dictation,
            .meetings,
            .settings,
        ])

        #expect(SettingsSection.allCases == [
            .storage,
            .general,
            .captureShortcuts,
            .speech,
            .ai,
            .audioPrivacy,
            .gmail,
            .mcp,
            .knowledge,
            .chat,
            .actions,
            .macMini,
        ])
        #expect(SettingsSection.gmail.isDeferred)
        #expect(SettingsSection.allCases.filter(\.isDeferred) == [.gmail])
    }

    @Test
    func firstLaunchChoosesStorageModeAndSpeechReadinessNeverBlocksBrain() async throws {
        let incomplete = try AppOnboardingFixture(ready: false)
        defer { incomplete.remove() }
        let suite = "AppIntegration.StorageMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setupStore = BrainStore(client: nil, defaults: defaults)
        let incompleteGraph = makeGraph(
            store: setupStore,
            onboarding: incomplete.controller
        )
        #expect(incompleteGraph.launchDestination == .setup)

        await incomplete.makeReady()
        await incomplete.controller.refresh()
        #expect(incompleteGraph.launchDestination == .setup)

        setupStore.selectRemote(defaults: defaults)
        #expect(incompleteGraph.launchDestination == .dashboard)
        #expect(setupStore.runtimeIdentity == "remote:none")

        let completed = try AppOnboardingFixture(ready: true, persistedCompletion: true)
        defer { completed.remove() }
        let remote = AppRemoteStatusAPI()
        let remoteStore = BrainStore(client: remote)
        let completedGraph = makeGraph(store: remoteStore, onboarding: completed.controller)

        #expect(completedGraph.launchDestination == .dashboard)
        #expect(completedGraph.store.isPaired)

        await completed.permissions.set(.denied, for: .microphone)
        await completed.controller.refresh()

        #expect(!completed.controller.isComplete)
        #expect(completedGraph.launchDestination == .dashboard)
        #expect(completedGraph.store === remoteStore)
    }

    @Test
    func appLaunchAndReopenPresentDashboardAndRemoteSetupCanGoBack() throws {
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/BrainMenuApp.swift"
            ),
            encoding: .utf8
        )
        #expect(appSource.contains("@NSApplicationDelegateAdaptor"))
        #expect(appSource.contains("applicationShouldHandleReopen"))
        #expect(appSource.contains("openWindow(id: BrainMenuApp.dashboardWindowID)"))
        #expect(appSource.contains("activate(ignoringOtherApps: true)"))

        let dashboardSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Views/DashboardView.swift"
            ),
            encoding: .utf8
        )
        #expect(dashboardSource.contains("Back to setup choices"))
        #expect(dashboardSource.contains("store.returnToSetup()"))
        #expect(dashboardSource.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test
    func menuActivityIgnoresStandaloneDictationAndTracksOnlyBrainMeetings() async {
        let voxType = AppVoxType()
        let dictation = DictationController(
            voxType: voxType,
            sleep: { _ in }
        )
        let recorder = AppMeetingRecorder()
        let meeting = MeetingController(
            detector: MeetingDetector(),
            recorder: recorder,
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        let graph = makeGraph(meeting: meeting)

        #expect(graph.activity == .remote)

        dictation.handle(.start)
        #expect(graph.activity == .remote)
        dictation.handle(.stop)
        #expect(graph.activity == .remote)
        await dictation.waitForPendingWork()

        await graph.toggleMeeting()
        #expect(meeting.state == .recording)
        #expect(graph.activity == .recording("Recording meeting"))
        guard case .meeting(let islandMeeting) = graph.recordingIsland.presentation else {
            Issue.record("Expected the shared island to present the active meeting")
            return
        }
        #expect(islandMeeting.phase == .recording)

        recorder.suspendStop = true
        let stopping = Task { await graph.toggleMeeting() }
        await recorder.waitUntilStopSuspends()
        #expect(meeting.state == .finalizing)
        #expect(graph.activity == .transcribing("Finalizing meeting"))
        guard case .meeting(let finalizingIsland) = graph.recordingIsland.presentation else {
            Issue.record("The first Stop click must immediately show meeting finalization")
            return
        }
        #expect(finalizingIsland.phase == .finalizing)
        #expect(graph.recordingIsland.controls.isEmpty)
        recorder.releaseStop()
        await stopping.value
        #expect(meeting.state == .completed)
        #expect(graph.activity == .remote)
        #expect(graph.recordingIsland.presentation == .hidden)
    }

    @Test
    func productionGraphTurnsReceivedMeetingFramesIntoVisibleAudioConfirmation() async {
        let audioMonitor = MeetingAudioMonitor()
        let meeting = MeetingController(
            detector: MeetingDetector(),
            recorder: AppMeetingRecorder(),
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3",
            audioMonitor: audioMonitor
        )
        let graph = makeGraph(meeting: meeting)
        graph.start()
        defer { graph.stop() }

        await graph.toggleMeeting()
        guard case .meeting(let waiting) = graph.recordingIsland.presentation else {
            Issue.record("Expected the meeting recording island")
            return
        }
        #expect(waiting.audioStatusText == "Waiting for audio…")

        audioMonitor.receive(MeetingAudioLevel(
            source: .microphone,
            timestampMilliseconds: 100,
            rms: 0,
            isClipping: false
        ))

        await eventually {
            guard case .meeting(let quiet) = graph.recordingIsland.presentation else {
                return false
            }
            return quiet.audioStatusText == "Connected — waiting for sound…"
                && !quiet.isReceivingAudio
        }

        audioMonitor.receive(MeetingAudioLevel(
            source: .microphone,
            timestampMilliseconds: 200,
            rms: 0.2,
            isClipping: false
        ))

        await eventually {
            guard case .meeting(let receiving) = graph.recordingIsland.presentation else {
                return false
            }
            return receiving.audioStatusText == "Receiving microphone audio…"
                && receiving.isReceivingAudio
        }
    }

    @Test
    func savedMeetingAppearsNewAtTopAndConfiguredAnalysisRefinesItsAutomaticTitle() async throws {
        let recorder = AppMeetingRecorder()
        let meeting = MeetingController(
            detector: MeetingDetector(),
            recorder: recorder,
            speechEngine: "parakeet",
            speechModel: "model"
        )
        let library = AppMeetingLibrary()
        let meetings = MeetingsController(
            store: library,
            analysisStore: AppEmptyAnalysisStore()
        )
        let analyzer = AppMeetingAnalyzer()
        let graph = makeGraph(
            meeting: meeting,
            meetings: meetings,
            meetingAnalysisFactory: { analyzer }
        )

        await graph.toggleMeeting()
        let active = try #require(meeting.currentMeeting)
        let utterance = try MeetingUtterance(
            source: .microphone,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "We need to review meeting capture reliability.",
            baseSpeakerID: "you"
        )
        var saved = active
        saved.title = "Review Meeting Capture Reliability"
        saved.titleSource = .transcript
        saved.endedAt = active.startedAt.addingTimeInterval(60)
        saved.lifecycleState = .completed
        saved.transcriptionState = .completed
        library.save(saved, utterances: [utterance])
        recorder.completion = saved

        await graph.toggleMeeting()
        await eventually {
            graph.meeting.currentMeeting?.title == "Meeting Capture Reliability Review"
        }

        #expect(analyzer.analysisCalls == 1)
        #expect(graph.meetingSavedNotice?.title == "Meeting Capture Reliability Review")
        #expect(meetings.rows.first?.id == saved.id)
        #expect(meetings.rows.first?.isUnread == true)
        #expect(library.values[saved.id]?.meeting.analysisState == .completed)
    }

    @Test
    func scenesBorrowOneControllerGraphAndStartingTwiceDoesNotDuplicateLongRunningOwners() {
        let captureRegistrar = AppCaptureHotkeyRegistrar()
        let regionRegistrar = AppCaptureHotkeyRegistrar()
        let graph = makeGraph(
            captureRegistrar: captureRegistrar,
            regionRegistrar: regionRegistrar
        )
        defer { graph.stop() }

        let firstWindow = DashboardView(store: graph.store, graph: graph)
        let reopenedWindow = DashboardView(store: graph.store, graph: graph)
        #expect(firstWindow.graph === graph)
        #expect(reopenedWindow.graph === graph)
        #expect(firstWindow.graph?.capture === reopenedWindow.graph?.capture)
        #expect(firstWindow.graph?.dictationHistory === reopenedWindow.graph?.dictationHistory)
        #expect(firstWindow.graph?.meeting === reopenedWindow.graph?.meeting)
        #expect(firstWindow.graph?.recordingIsland === reopenedWindow.graph?.recordingIsland)

        graph.start()
        graph.start()

        #expect(graph.startCount == 1)
        #expect(captureRegistrar.registerCalls == 1)
        #expect(captureRegistrar.registeredHotkeys == [.controlOptionB])
        #expect(regionRegistrar.registerCalls == 1)
        #expect(regionRegistrar.registeredHotkeys == [.controlOptionZ])
    }

    @Test
    func appLaunchNeverResumesResourceIntensiveMeetingTranscription() throws {
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/BrainMenuApp.swift"
            ),
            encoding: .utf8
        )

        #expect(!source.contains("resumeInterruptedJobs()"))
    }

    @Test
    func brainNeverOffersToInstallItselfOnVoxTypesDictationOutputPath() throws {
        let onboardingSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Onboarding/OnboardingController.swift"
            ),
            encoding: .utf8
        )
        let configurationSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Speech/VoxTypeConfiguration.swift"
            ),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/BrainMenuApp.swift"
            ),
            encoding: .utf8
        )

        #expect(!onboardingSource.contains("enableDictationHistory"))
        #expect(!onboardingSource.contains("repairDictationHistory"))
        #expect(!onboardingSource.contains("configurePostProcess"))
        #expect(!configurationSource.contains("configurePostProcess"))
        #expect(!configurationSource.contains("removeBrainPostProcess"))
        #expect(!configurationSource.contains("VoxTypeLegacyIntegrationRemoving"))
        #expect(!appSource.contains("removeBrainPostProcess()"))
        #expect(appSource.contains("dictationHistory.startMonitoring()"))
        #expect(appSource.contains("dictationHistory.stopMonitoring()"))
    }

    @Test
    func standaloneVoxTypeStatusNeverDrivesBrainsRecordingIsland() async {
        let voxType = AppStreamingVoxType()
        _ = DictationController(voxType: voxType, sleep: { _ in })
        let meeting = MeetingController(
            detector: MeetingDetector(),
            recorder: AppMeetingRecorder(),
            speechEngine: "parakeet",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        let graph = makeGraph(meeting: meeting)

        graph.start()
        graph.start()
        await Task.yield()
        #expect(voxType.streamCount == 0)

        voxType.yield(appRuntimeStatus(.recording))
        await Task.yield()
        #expect(graph.recordingIsland.presentation == .hidden)
        voxType.yield(appRuntimeStatus(.transcribing))
        await Task.yield()
        #expect(graph.recordingIsland.presentation == .hidden)

        await graph.toggleMeeting()
        await eventually {
            guard case .meeting(let value) = graph.recordingIsland.presentation else {
                return false
            }
            return value.phase == .recording
        }
        voxType.yield(appRuntimeStatus(.idle))
        await Task.yield()
        guard case .meeting = graph.recordingIsland.presentation else {
            Issue.record("Dictation idle must not replace an active meeting")
            return
        }

        await graph.toggleMeeting()
        guard case .meeting(let saved) = graph.recordingIsland.presentation else {
            Issue.record("A completed meeting must show its saved notification")
            return
        }
        #expect(saved.phase == .saved)
        #expect(graph.meetingSavedNotice?.message.contains("top of the list") == true)

        voxType.yield(appRuntimeStatus(.recording))
        await Task.yield()
        switch graph.recordingIsland.presentation {
        case .hidden:
            break // The injected zero-delay auto-hide completed.
        case .meeting(let stillSaved):
            #expect(stillSaved.phase == .saved)
        case .dictation:
            Issue.record("Standalone VoxType must not replace the meeting-saved notification")
        }

        graph.stop()
        #expect(voxType.cancellationCount == 0)
        #expect(graph.recordingIsland.presentation == .hidden)
    }

    @Test
    func settingsKeepsPairedKnowledgeAskActionsMacMiniAndGmailRoots() {
        let remote = AppRemoteStatusAPI()
        let store = BrainStore(client: remote)
        let graph = makeGraph(store: store)
        let roots: [AnyView] = [
            AnyView(MenuBarView(graph: graph)),
            AnyView(DashboardView(store: store, graph: graph)),
            AnyView(KnowledgeView(store: RemoteKnowledgeStore())),
            AnyView(ChatView()),
            AnyView(ActionsView(store: store)),
            AnyView(MacMiniView(store: store)),
            AnyView(SettingsView(
                store: store,
                launchAtLogin: graph.launchAtLogin,
                gmail: graph.gmail,
                captureHotkey: graph.captureHotkey,
                speech: graph.speechSettings,
                ai: graph.aiSettings,
                audioRetention: graph.audioRetention,
                onboarding: graph.onboarding
            )),
        ]

        #expect(store.isPaired)
        #expect(roots.count == 7)
        #expect(graph.store === store)
        #expect(SettingsSection.knowledge.rawValue == "Knowledge")
        #expect(SettingsSection.chat.rawValue == "Ask Brain")
        #expect(SettingsSection.actions.rawValue == "Actions")
        #expect(SettingsSection.macMini.rawValue == "Remote Runner")
        #expect(SettingsSection.gmail.rawValue == "Gmail")
    }

    @Test
    func permissionMetadataAndPackageHaveTheExactLeastPrivilegeContract() throws {
        let resources = packageRoot.appendingPathComponent("Resources", isDirectory: true)
        let infoData = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let info = try #require(
            PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any]
        )
        #expect(
            info["NSMicrophoneUsageDescription"] as? String
                == "Brain records your microphone for dictation and meetings."
        )
        #expect(
            info["NSScreenCaptureUsageDescription"] as? String
                == "Brain records system audio during meetings and captures only screenshots you explicitly select; it never records video."
        )
        for prohibited in [
            "NSCameraUsageDescription",
            "NSContactsUsageDescription",
            "NSCalendarsUsageDescription",
            "NSAppleEventsUsageDescription",
        ] {
            #expect(info[prohibited] == nil)
        }

        let entitlementData = try Data(
            contentsOf: resources.appendingPathComponent("Brain.entitlements")
        )
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: entitlementData, format: nil)
                as? [String: Any]
        )
        #expect(Set(entitlements.keys) == ["com.apple.security.device.audio-input"])
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        for prohibited in [
            "com.apple.security.device.camera",
            "com.apple.security.personal-information.addressbook",
            "com.apple.security.personal-information.calendars",
            "com.apple.security.network.server",
            "com.apple.security.automation.apple-events",
        ] {
            #expect(entitlements[prohibited] == nil)
        }

        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains(".macOS(.v14)"))
        #expect(manifest.contains(".executable(name: \"BrainMenu\""))
        #expect(manifest.contains(".executable(name: \"BrainDictationObserver\""))
        #expect(!manifest.contains("BrainDictationBridge"))
        #expect(manifest.contains(".testTarget("))
        #expect(!manifest.contains("MacParakeetHook"))
        #expect(!manifest.contains("unsafeFlags"))
        #expect(!manifest.contains("_BrainMenuStartMacParakeetMeetingRuntime"))

        let menuSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Views/MenuBarView.swift"
            ),
            encoding: .utf8
        )
        for action in ["Open Brain", "Quick Capture", "Start Meeting", "Stop Meeting", "Quit"] {
            #expect(menuSource.contains(action))
        }
        #expect(menuSource.contains(".onAppear"))
        #expect(menuSource.contains("openDashboard()"))
        #expect(menuSource.contains("dismiss()"))

        let dashboardSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Views/DashboardView.swift"
            ),
            encoding: .utf8
        )
        #expect(dashboardSource.contains("BrainBuildInfo.current"))
        #expect(!dashboardSource.contains("BrainAppBuildIdentity"))
        #expect(dashboardSource.contains("CaptureActivityView"))
        for audioStatusContract in [
            "audioSignalStates[source]",
            "Needs attention",
            "Connecting…",
            "Waiting…",
            "Connected — waiting for sound…",
            "Live",
        ] {
            #expect(dashboardSource.contains(audioStatusContract))
        }

        let dictationHistorySource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/BrainMenu/Views/DictationHistoryView.swift"
            ),
            encoding: .utf8
        )
        for contract in [
            "No saved dictation",
            "textSelection(.enabled)",
            "keyboardShortcut(\"c\", modifiers: .command)",
            "Copy",
            "Delete",
            "Clear All",
            "confirmationDialog",
        ] {
            #expect(dictationHistorySource.contains(contract))
        }
    }

    @Test
    func repairedFlowsExposeOneStableAccessibilityAndFocusContract() throws {
        let views = packageRoot.appendingPathComponent("Sources/BrainMenu/Views", isDirectory: true)
        let namedViews = [
            "OnboardingView.swift",
            "QuickCapturePanel.swift",
            "RecordingIslandView.swift",
            "SpeechSettingsView.swift",
            "DictationHistoryView.swift",
            "MeetingLiveView.swift",
            "AISettingsView.swift",
            "CaptureView.swift",
            "MacMiniView.swift",
            "KnowledgeView.swift",
            "ChatView.swift",
        ]

        for filename in namedViews {
            let source = try String(
                contentsOf: views.appendingPathComponent(filename),
                encoding: .utf8
            )
            #expect(
                source.contains("accessibilityLabel") || source.contains("brainAccessibleStatus"),
                "\(filename) must expose stable spoken labels"
            )
        }

        for filename in [
            "OnboardingView.swift",
            "QuickCapturePanel.swift",
            "SpeechSettingsView.swift",
            "DictationHistoryView.swift",
            "MeetingLiveView.swift",
            "AISettingsView.swift",
            "CaptureView.swift",
            "MacMiniView.swift",
            "KnowledgeView.swift",
            "ChatView.swift",
        ] {
            let source = try String(
                contentsOf: views.appendingPathComponent(filename),
                encoding: .utf8
            )
            #expect(source.contains("accessibilityFocused"), "\(filename) must manage focus")
        }

        let combined = try namedViews.map {
            try String(contentsOf: views.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for contract in [
            "keyboardShortcut(.defaultAction)",
            "keyboardShortcut(.cancelAction)",
            "keyboardShortcut(\"c\", modifiers: .command)",
            "confirmationDialog",
            "accessibilityReduceMotion",
            "fixedSize(horizontal: false, vertical: true)",
        ] {
            #expect(combined.contains(contract), "Missing accessibility contract: \(contract)")
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeGraph(
        store: BrainStore = BrainStore(client: nil),
        onboarding: OnboardingController? = nil,
        meeting: MeetingController? = nil,
        meetings: MeetingsController? = nil,
        meetingAnalysisFactory: @escaping @MainActor () -> (any MeetingDetailAnalysisControlling)? = { nil },
        captureRegistrar: AppCaptureHotkeyRegistrar = AppCaptureHotkeyRegistrar(),
        regionRegistrar: AppCaptureHotkeyRegistrar = AppCaptureHotkeyRegistrar()
    ) -> BrainAppControllerGraph {
        let onboarding = onboarding ?? AppOnboardingFixture.fallbackController()
        return BrainAppControllerGraph(
            store: store,
            onboarding: onboarding,
            capture: CaptureController(apiProvider: { nil }, sleep: { _ in }),
            meeting: meeting,
            dictationHistory: DictationHistoryStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("AppIntegrationDictation-\(UUID().uuidString)")
                    .appendingPathComponent("Dictation")
            ),
            recordingIsland: appTestIsland(),
            meetings: meetings ?? MeetingsController(
                store: AppEmptyMeetingStore(),
                analysisStore: AppEmptyAnalysisStore()
            ),
            captureHotkeyRegistrar: captureRegistrar,
            regionHotkeyRegistrar: regionRegistrar,
            frontmostApplications: AppFrontmostApplications(),
            speechSettings: SpeechSettingsController(
                voxType: nil,
                inventory: AppSpeechInventory(),
                selections: SpeechSelectionStore(
                    persistence: AppSpeechPersistence(),
                    namespace: "AppIntegration.\(UUID().uuidString)"
                )
            ),
            aiSettings: AISettingsController(settings: AppAISettings()),
            audioRetention: AudioRetentionController(),
            meetingAnalysisFactory: meetingAnalysisFactory
        )
    }

    private func appTestIsland() -> RecordingIslandController {
        RecordingIslandController(
            defaults: UserDefaults.standard,
            displaysProvider: { [] },
            mainDisplayIDProvider: { nil },
            frontmostProcessProvider: { nil },
            announcementHandler: { _ in },
            reduceMotionProvider: { true },
            sleep: { _ in }
        )
    }

    private func eventually(
        attempts: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}

private final class AppCaptureHotkeyRegistrar: CaptureHotkeyRegistering {
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var registeredHotkeys: [CaptureHotkey] = []

    func register(_ hotkey: CaptureHotkey, action: @escaping @MainActor () -> Void) throws {
        registerCalls += 1
        registeredHotkeys.append(hotkey)
    }

    func unregister() {
        unregisterCalls += 1
    }
}

private final class AppFrontmostApplications: FrontmostApplicationProviding {
    var frontmostApplication: QuickCaptureApplicationIdentity? { nil }
}

private actor AppVoxType: VoxTypeControlling {
    func version() async throws -> VoxTypeVersion {
        VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
    }

    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
    }

    func status() async -> VoxTypeStatus {
        .available(VoxTypeStatusSnapshot(state: .idle, model: nil, device: nil, backend: nil))
    }

    func startRecordingForPaste() async throws {}
    func stopRecordingForPaste() async throws {}
    func cancelRecording() async throws {}
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }
}

private final class AppStreamingVoxType: VoxTypeControlling, VoxTypeStatusObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VoxTypeStatus>.Continuation?
    private var recordedStreams = 0
    private var recordedCancellations = 0

    var streamCount: Int { lock.withLock { recordedStreams } }
    var cancellationCount: Int { lock.withLock { recordedCancellations } }

    func version() async throws -> VoxTypeVersion {
        VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil)
    }

    func hotkeyConfiguration() async throws -> VoxTypeHotkeyConfiguration {
        VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
    }

    func status() async -> VoxTypeStatus { appRuntimeStatus(.idle) }
    func startRecordingForPaste() async throws {}
    func stopRecordingForPaste() async throws {}
    func cancelRecording() async throws {}
    func transcribe(wavURL: URL, engine: String) async throws -> String { "" }

    func statusEvents() -> AsyncStream<VoxTypeStatus> {
        AsyncStream { continuation in
            lock.withLock {
                recordedStreams += 1
                self.continuation = continuation
            }
            continuation.onTermination = { @Sendable [weak self] reason in
                guard case .cancelled = reason, let self else { return }
                self.lock.withLock { self.recordedCancellations += 1 }
            }
        }
    }

    func yield(_ status: VoxTypeStatus) {
        lock.withLock { continuation }?.yield(status)
    }
}

private func appRuntimeStatus(_ state: VoxTypeRuntimeState) -> VoxTypeStatus {
    .available(VoxTypeStatusSnapshot(
        state: state,
        model: "small.en",
        device: "default",
        backend: "whisper"
    ))
}

@MainActor
private final class AppMeetingRecorder: MeetingRecording {
    var suspendStop = false
    var completion: MeetingRecord?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start(_ request: MeetingRecordingRequest) async throws {}
    func pause(at date: Date) async throws {}
    func resume(with discontinuity: MeetingRecordingDiscontinuity) async throws {}

    func stop(at date: Date) async throws -> MeetingRecord? {
        if suspendStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
        return completion
    }

    func preserveForRecovery(at date: Date, reason: MeetingRecoveryReason) async {}

    func waitUntilStopSuspends() async {
        while stopContinuation == nil { await Task.yield() }
    }

    func releaseStop() {
        suspendStop = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private final class AppMeetingLibrary: MeetingLibraryStoring, @unchecked Sendable {
    private(set) var values: [UUID: StoredMeeting] = [:]

    func list() throws -> [MeetingListEntry] {
        values.values
            .map(\.meeting)
            .sorted { $0.startedAt > $1.startedAt }
            .map(MeetingListEntry.available)
    }

    func load(_ id: UUID) throws -> StoredMeeting {
        guard let value = values[id] else { throw MeetingStoreError.meetingNotFound(id) }
        return value
    }

    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) {
        values[meeting.id] = StoredMeeting(meeting: meeting, utterances: utterances)
    }

    func delete(_ id: UUID, confirmed: Bool) throws {
        values.removeValue(forKey: id)
    }
}

private final class AppMeetingAnalyzer: MeetingDetailAnalysisControlling, @unchecked Sendable {
    private(set) var analysisCalls = 0

    func analyzeAfterFinalTranscription(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        analysisCalls += 1
        var analyzed = meeting
        analyzed.title = "Meeting Capture Reliability Review"
        analyzed.titleSource = .analysis
        analyzed.analysisState = .completed
        return MeetingAnalysisRunResult(
            meeting: analyzed,
            utterances: utterances,
            speakerState: speakerState,
            analysis: nil,
            failure: nil
        )
    }

    func reanalyze(
        meeting: MeetingRecord,
        utterances: [MeetingUtterance],
        speakerState: SpeakerEditingState
    ) async -> MeetingAnalysisRunResult {
        await analyzeAfterFinalTranscription(
            meeting: meeting,
            utterances: utterances,
            speakerState: speakerState
        )
    }

    func acceptSpeakerSuggestion(
        meetingID: UUID,
        utteranceID: UUID,
        editor: inout SpeakerEditor
    ) throws -> Bool { false }
}

private actor AppRemoteStatusAPI: BrainStatusAPI {
    nonisolated let pairedInstance: BrainInstanceMetadata? = BrainInstanceMetadata(
        baseURL: URL(string: "https://brain.example.test")!,
        instanceID: "app-integration",
        deviceID: "test-mac",
        deviceName: "Test Mac",
        scopes: [.capture, .read, .control]
    )

    func status() async throws -> BrainStatusReport {
        let date = Date(timeIntervalSince1970: 1_784_193_000)
        return BrainStatusReport(
            schemaVersion: 1,
            generatedAt: date,
            vault: BrainVaultStatus(path: "remote", state: .clean, dirtyPaths: 0),
            counts: BrainContentCounts(inbox: 0, sources: 0, notes: 0, people: 0, projects: 0),
            lastRun: BrainLastRun(at: date, commit: "test", summary: "healthy"),
            services: [],
            freshness: .fresh
        )
    }

    func health() async throws -> BrainHealthReport {
        BrainHealthReport(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_784_193_000),
            overall: .healthy,
            counts: BrainHealthCounts(pass: 1, activity: 0, warning: 0, failure: 0),
            checks: [],
            freshness: .fresh
        )
    }
}

@MainActor
private final class AppOnboardingFixture {
    let defaults: UserDefaults
    let permissions: AppOnboardingPermissions
    let models: AppOnboardingModels
    let voxType: AppOnboardingVoxType
    let controller: OnboardingController
    private let suite: String

    init(ready: Bool, persistedCompletion: Bool = false) throws {
        suite = "AppIntegration.Onboarding.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if persistedCompletion {
            defaults.set(OnboardingController.schemaVersion, forKey: OnboardingController.schemaVersionKey)
            defaults.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: OnboardingController.completionDateKey)
        }
        permissions = AppOnboardingPermissions(authorized: ready)
        models = AppOnboardingModels(ready: ready)
        voxType = AppOnboardingVoxType(ready: ready)
        controller = OnboardingController(
            voxType: voxType,
            models: models,
            permissions: permissions,
            opener: AppOnboardingOpener(),
            defaults: defaults
        )
    }

    func makeReady() async {
        await voxType.makeReady()
        await permissions.authorizeAll()
        await models.makeReady()
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }

    static func fallbackController() -> OnboardingController {
        let defaults = UserDefaults(suiteName: "AppIntegration.Fallback.\(UUID().uuidString)")!
        return OnboardingController(
            voxType: AppOnboardingVoxType(ready: false),
            models: AppOnboardingModels(ready: false),
            permissions: AppOnboardingPermissions(authorized: false),
            opener: AppOnboardingOpener(),
            defaults: defaults
        )
    }
}

private actor AppOnboardingVoxType: OnboardingVoxTypeInspecting {
    private var ready: Bool
    init(ready: Bool) { self.ready = ready }

    func inspect() async -> OnboardingVoxTypeInspection {
        OnboardingVoxTypeInspection(
            executableURL: ready ? URL(fileURLWithPath: "/opt/homebrew/bin/voxtype") : nil,
            version: ready ? VoxTypeVersion(major: 0, minor: 7, patch: 5, prerelease: nil) : nil,
            status: ready
                ? .available(VoxTypeStatusSnapshot(state: .idle, model: nil, device: nil, backend: nil))
                : .unavailable(.launchFailed),
            hotkeyConfiguration: ready
                ? VoxTypeHotkeyConfiguration(key: "FN", modifiers: [], mode: "PushToTalk")
                : nil
        )
    }

    func makeReady() { ready = true }
}

private actor AppOnboardingModels: OnboardingModelManaging {
    private var ready: Bool
    init(ready: Bool) { self.ready = ready }

    func refresh() async -> ModelInventorySnapshot {
        snapshot
    }

    func installCatalogModel(id: String) async throws -> ModelInventorySnapshot {
        ready = true
        return snapshot
    }

    func makeReady() { ready = true }

    private var snapshot: ModelInventorySnapshot {
        ModelInventorySnapshot(availabilityByModelID: Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map {
                ($0.id, ready ? .ready : .missing)
            }
        ))
    }
}

private actor AppOnboardingPermissions: OnboardingPermissionProviding {
    private var values: [OnboardingPermission: OnboardingAuthorizationStatus]

    init(authorized: Bool) {
        values = Dictionary(uniqueKeysWithValues: OnboardingPermission.allCases.map {
            ($0, authorized ? .authorized : .notDetermined)
        })
    }

    func status(for permission: OnboardingPermission) async -> OnboardingAuthorizationStatus {
        values[permission] ?? .notDetermined
    }

    func request(_ permission: OnboardingPermission) async -> OnboardingAuthorizationStatus {
        values[permission] ?? .notDetermined
    }

    func set(_ value: OnboardingAuthorizationStatus, for permission: OnboardingPermission) {
        values[permission] = value
    }

    func authorizeAll() {
        for permission in OnboardingPermission.allCases { values[permission] = .authorized }
    }
}

@MainActor
private final class AppOnboardingOpener: OnboardingURLOpening {
    func open(_ url: URL) -> Bool { true }
}

private actor AppSpeechInventory: SpeechModelInventoryControlling {
    func refresh() async -> ModelInventorySnapshot { .unknown }
    func install(
        modelID: String,
        progress: @Sendable (ModelInstallProgress) -> Void
    ) async throws -> ModelInventorySnapshot {
        throw ModelInventoryError.installFailed
    }
}

private final class AppSpeechPersistence: SpeechSelectionPersisting {
    private var values: [String: String] = [:]
    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? String }
    func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

private final class AppAISettings: AISettingsPersisting, @unchecked Sendable {
    private var configuration = AIProviderConfiguration()
    func load() -> AIProviderConfiguration { configuration }
    func save(_ configuration: AIProviderConfiguration) throws { self.configuration = configuration }
    func clear() { configuration = AIProviderConfiguration() }
}

private struct AppEmptyMeetingStore: MeetingLibraryStoring {
    func list() throws -> [MeetingListEntry] { [] }
    func load(_ id: UUID) throws -> StoredMeeting { throw MeetingStoreError.meetingNotFound(id) }
    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws {}
    func delete(_ id: UUID, confirmed: Bool) throws {}
}

private struct AppEmptyAnalysisStore: MeetingAnalysisStoring {
    func load(meetingID: UUID) throws -> StoredMeetingAnalysis? { nil }
    func replace(_ value: StoredMeetingAnalysis, meetingID: UUID) throws {}
}
