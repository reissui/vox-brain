import Foundation
import SwiftUI
import Testing
@testable import BrainMenu

/// Remote-first acceptance at the app-scene and controller boundaries. Every
/// home, API, and launch-service fixture is temporary or in-memory.
@Suite(.serialized)
@MainActor
struct EndToEndAcceptanceTests {
    @Test
    func cloudFirstBrainCoversEveryRepairedOwnerFlow() async throws {
        try await temporaryHomeWithoutVaultOrCLIInitializesEveryTopLevelScene()
        try await pairedRemoteClientReadsKnowledgeChatsAndInitializesJobControls()
        try await nativeMeetingTranscriptAndGmailStayOnPairedRemoteBoundaries()

        let onboarding = OnboardingControllerTests()
        try await onboarding.accessibilityIsRequestedAloneAndInputMonitoringIsAbsent()

        let voice = VoiceMeetingAcceptanceTests()
        try await voice.externalVoxTypeCompletesOnboardingWithoutRequiringAMeetingModel()
        try await voice.quickCaptureUsesAdaptiveShortcutExplicitClipboardPickerAndDeliveredStatus()
        try await voice.detectedAndManualMeetingsUseDualFixturesRollTranscriptAndRequireExplicitStop()

        let speech = FeatureSettingsViewTests()
        await speech.firstReadyRefreshAppliesAndPersistsOneParakeetDefaultForBothWorkflows()
        speech.speechRowsExposeEveryReadinessStateCapabilitiesAndAccessibilityText()

        // The exact three-rollover regression is executed independently by the
        // Swift suite. Keep the named end-to-end gate compile-coupled to its
        // implementation without nesting its timing-sensitive AsyncStream
        // fixture inside a second test runtime.
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let continuousSource = try String(
            contentsOf: testsURL.appendingPathComponent("ContinuousDictationControllerTests.swift"),
            encoding: .utf8
        )
        for entryPoint in [
            "fixedShortcutStartsLocksRollsThreeTimesAndStopsExactlyOncePerSegment",
            "for completedSegment in 1...3",
            ".start, .stop, .start, .stop, .start, .stop, .start, .stop",
        ] {
            #expect(continuousSource.contains(entryPoint))
        }

        let history = DictationHistoryStoreTests()
        try history.restartImportIsExactlyOnceAndKeepsNewestFiveHundred()

        try CLIProviderTests().codexPresetPersistsModelButNoExecutableArgumentsOrCredential()
        let dashboard = DashboardPresentationTests()
        dashboard.workflowStatesHaveUniqueSpokenLabelsAndNonColorSymbols()
        try dashboard.localActivityUsesObsidianAndDoesNotRenderRemoteSiteStatus()
    }

    @Test
    func temporaryHomeWithoutVaultOrCLIInitializesEveryTopLevelScene() async throws {
        let home = try AcceptanceHome()
        defer { home.remove() }
        let api = AcceptanceRemoteAPI()
        let store = BrainStore(
            client: api,
            now: { Date(timeIntervalSince1970: 1_784_112_400) }
        )
        let capture = CaptureController(api: api)

        #expect(!FileManager.default.fileExists(atPath: home.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: home.cliURL.path))

        await store.refresh()
        capture.draft.noteText = "remote-only acceptance capture"
        await capture.submit()

        let sceneRoots: [AnyView] = [
            AnyView(MenuBarView(store: store)),
            AnyView(DashboardView(store: store)),
            AnyView(CaptureView(controller: capture)),
        ]

        #expect(sceneRoots.count == 3)
        #expect(store.isPaired)
        #expect(store.snapshot?.health.overall == .healthy)
        #expect(store.privateSiteURL?.absoluteString == "https://brain-vault.example.pages.dev")
        #expect(capture.submissionState == .queued(id: "capture-1"))
        #expect(await api.captures.map(\.text) == ["remote-only acceptance capture"])
        #expect(!FileManager.default.fileExists(atPath: home.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: home.cliURL.path))
    }

    @Test
    func pairedRemoteClientReadsKnowledgeChatsAndInitializesJobControls() async throws {
        let api = AcceptanceRemoteAPI()
        let suiteName = "EndToEndAcceptanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BrainStore(client: api)
        let knowledge = RemoteKnowledgeStore(
            api: api,
            debounce: .zero,
            sleep: { _ in }
        )
        let chat = BrainChatController(
            client: api,
            defaults: defaults,
            pollInterval: .zero,
            sleep: { _ in }
        )
        let actions = RemoteBrainController(
            api: api,
            defaults: defaults,
            sleep: { _ in }
        )

        await store.refresh()
        knowledge.search("remote-only")
        await knowledge.waitForPendingSearch()
        let document = await knowledge.select(path: "notes/Remote Only.md")
        await chat.submit("What is remote-only?")
        await actions.refresh()

        let dashboardSections: [AnyView] = [
            AnyView(OverviewView(store: store)),
            AnyView(KnowledgeView(store: knowledge)),
            AnyView(ChatView(controller: chat)),
            AnyView(ActionsView(store: store, controller: actions)),
            AnyView(MacMiniView(store: store, controller: actions)),
        ]

        #expect(dashboardSections.count == 5)
        #expect(knowledge.results.map(\.relativePath) == ["notes/Remote Only.md"])
        #expect(document?.readingBody == "# Remote Only\n\nRemote knowledge body.")
        #expect(chat.turns.first?.answer == "Remote answer with [[Remote Only]].")
        #expect(actions.connectionState == .reachable)
        #expect(actions.pairedInstance?.instanceID == "acceptance-brain")
        #expect(await api.createdJobKinds == [.ask])
    }

    @Test
    func nativeMeetingTranscriptAndGmailStayOnPairedRemoteBoundaries() async throws {
        let home = try AcceptanceHome()
        defer { home.remove() }
        let api = AcceptanceRemoteAPI()
        let meetingsURL = home.url.appendingPathComponent("Meeting State", isDirectory: true)
        let meetingStore = MeetingStore(rootURL: meetingsURL)
        let meeting = MeetingRecord(
            title: "Native remote standup",
            startedAt: Date(timeIntervalSince1970: 1_784_193_000),
            endedAt: Date(timeIntervalSince1970: 1_784_193_060),
            lifecycleState: .completed,
            speechEngine: "voxtype",
            speechModel: "parakeet-tdt-0.6b-v3"
        )
        let utterance = try MeetingUtterance(
            source: .system,
            startMilliseconds: 0,
            endMilliseconds: 1_000,
            text: "Remote transcript handoff",
            baseSpeakerID: "remote"
        )
        try meetingStore.save(meeting, utterances: [utterance])
        let meetings = MeetingUploadController(
            meetingStore: meetingStore,
            analysisStore: FileMeetingAnalysisStore(rootURL: meetingsURL),
            uploadStore: FileMeetingUploadStore(rootURL: meetingsURL),
            api: api,
            sleep: { _ in throw CancellationError() }
        )

        await meetings.uploadAfterFinalTranscriptPersistence(meetingID: meeting.id)

        let gmailAPI = AcceptanceGmailAPI()
        let gmail = GmailConnectionController(api: gmailAPI)
        await gmail.refresh()
        let launch = AcceptanceLaunchService(status: .enabled)
        let settingsViews = [
            AnyView(SettingsView(
                launchAtLogin: LaunchAtLoginController(service: launch),
                gmail: gmail
            )),
        ]

        #expect(settingsViews.count == 1)
        #expect(gmail.state == .connected(account: "owner@example.test"))
        #expect(await api.captures.contains { request in
            request.type == .transcript
                && request.transcript?.contains("Remote transcript handoff") == true
                && request.source == "Brain.app meeting"
                && request.image == nil
        })
        #expect(!FileManager.default.fileExists(atPath: home.vaultURL.path))
        #expect(!FileManager.default.fileExists(atPath: home.cliURL.path))
    }

    @Test
    func settingsPresentsLaunchAtLoginStateAndActions() throws {
        let suiteName = "EndToEndAcceptanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = AcceptanceLaunchService(status: .requiresApproval)
        var openSettingsCalls = 0
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            openLoginItems: { openSettingsCalls += 1 }
        )

        #expect(controller.state == .requiresApproval)
        #expect(controller.state.title == "Approval required")
        _ = SettingsView(launchAtLogin: controller)

        controller.openLoginItemsSettings()
        #expect(openSettingsCalls == 1)

        service.status = .notRegistered
        controller.refresh()
        controller.register()
        #expect(controller.state == .enabled)
        controller.unregister()
        #expect(controller.state == .notRegistered)
        #expect(service.registerCalls == 1)
        #expect(service.unregisterCalls == 1)
    }
}

private struct AcceptanceHome {
    let url: URL

    var vaultURL: URL {
        url.appendingPathComponent("dev/brain", isDirectory: true)
    }

    var cliURL: URL {
        vaultURL.appendingPathComponent("scripts/brain", isDirectory: false)
    }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainMenuAcceptance-Home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private actor AcceptanceRemoteAPI:
    BrainStatusAPI,
    BrainCaptureAPI,
    RemoteKnowledgeAPI,
    BrainChatJobAPI,
    RemoteBrainJobAPI
{
    nonisolated let pairedInstance: BrainInstanceMetadata? = BrainInstanceMetadata(
        baseURL: URL(string: "https://brain.example.test")!,
        instanceID: "acceptance-brain",
        deviceID: "acceptance-device",
        deviceName: "Acceptance Mac",
        scopes: [.capture, .read, .control]
    )

    private(set) var captures: [BrainCaptureRequest] = []
    private(set) var createdJobKinds: [BrainJobKind] = []
    private var jobs: [String: BrainJobKind] = [:]

    func status() async throws -> BrainStatusReport {
        let generatedAt = Date(timeIntervalSince1970: 1_784_112_390)
        return BrainStatusReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            vault: BrainVaultStatus(path: "remote", state: .clean, dirtyPaths: 0),
            counts: BrainContentCounts(inbox: 1, sources: 8, notes: 7, people: 6, projects: 5),
            lastRun: BrainLastRun(at: generatedAt, commit: "acceptance", summary: "remote run"),
            services: [],
            siteURL: URL(string: "https://brain-vault.example.pages.dev")
        )
    }

    func health() async throws -> BrainHealthReport {
        BrainHealthReport(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_784_112_391),
            overall: .healthy,
            counts: BrainHealthCounts(pass: 1, activity: 0, warning: 0, failure: 0),
            checks: [
                BrainHealthCheck(
                    id: "agent.heartbeat",
                    scope: "mac_mini_agent",
                    state: .pass,
                    summary: "Remote agent is healthy",
                    detail: "Reported by the paired instance.",
                    remediation: nil
                ),
            ]
        )
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        captures.append(capture)
        return BrainCaptureReceipt(id: "capture-\(captures.count)", state: "queued")
    }

    func searchKnowledge(
        query: String,
        limit: Int?
    ) async throws -> BrainKnowledgeSearchResponse {
        BrainKnowledgeSearchResponse(
            query: query,
            results: [
                BrainKnowledgeSearchResult(
                    title: "Remote Only",
                    path: "notes/Remote Only.md",
                    snippet: "Remote knowledge body."
                ),
            ]
        )
    }

    func listKnowledge(limit: Int?) async throws -> BrainKnowledgeDocumentsResponse {
        BrainKnowledgeDocumentsResponse(documents: [
            BrainKnowledgeListItem(title: "Remote Only", path: "notes/Remote Only.md"),
        ])
    }

    func knowledgeDocument(path: String) async throws -> BrainKnowledgeDocument {
        BrainKnowledgeDocument(
            path: path,
            title: "Remote Only",
            content: "# Remote Only\n\nRemote knowledge body."
        )
    }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        createdJobKinds.append(kind)
        let id = "\(kind.rawValue)-job-\(createdJobKinds.count)"
        jobs[id] = kind
        return BrainJobCreated(id: id, state: .queued)
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        guard let kind = jobs[id] else { throw BrainAPIError.invalidResponse }
        let output = switch kind {
        case .ask: "Remote answer with [[Remote Only]]."
        case .process: "Remote process completed."
        case .digest: "Remote digest completed."
        }
        return BrainJobStatus(
            id: id,
            kind: kind,
            state: .completed,
            output: output,
            error: nil,
            detail: nil,
            truncated: false,
            createdAt: "2026-07-16T09:00:00Z",
            startedAt: "2026-07-16T09:00:01Z",
            finishedAt: "2026-07-16T09:00:02Z",
            updatedAt: "2026-07-16T09:00:02Z"
        )
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        BrainHealthProbeResponse(ok: true)
    }
}

private actor AcceptanceGmailAPI: GmailConnectionAPI {
    func start() async throws -> URL {
        URL(string: "https://accounts.example.test/authorize")!
    }

    func status() async throws -> GmailRemoteStatus {
        .connected(account: "owner@example.test")
    }

    func disconnect() async throws {}
}

@MainActor
private final class AcceptanceLaunchService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerCalls = 0
    var unregisterCalls = 0

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}
