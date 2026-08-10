import Foundation
import Testing
@testable import BrainMenu

struct DashboardPresentationTests {
    @Test
    func mcpInstructionsUseThePairedGatewayAndKeepSecretsOutOfCommands() throws {
        let instructions = MCPConnectionInstructions(
            baseURL: URL(string: "https://brain-gw.example.test/ignored?old=true")
        )

        #expect(instructions.endpoint == "https://brain-gw.example.test/mcp")
        #expect(instructions.codexOAuthCommands == [
            "codex mcp add brain --url \"https://brain-gw.example.test/mcp\"",
            "codex mcp login brain",
        ])
        #expect(instructions.codexBearerCommands == [
            "export BRAIN_MCP_PASSWORD='<your Brain MCP password>'",
            "codex mcp add brain --url \"https://brain-gw.example.test/mcp\" --bearer-token-env-var BRAIN_MCP_PASSWORD",
        ])
        #expect(!instructions.codexOAuthCommands.joined().contains("test-mcp-password"))
        #expect(!SettingsSection.allCases.contains { $0.rawValue == "MCP" })
        #expect(!DashboardSection.allCases.contains { $0.rawValue == "MCP" })
    }

    @Test
    func workflowStatesHaveUniqueSpokenLabelsAndNonColorSymbols() {
        let states = BrainWorkflowAccessibilityState.allCases
        let presentations = states.map(\.presentation)

        #expect(states.map(\.rawValue) == [
            "listening",
            "transcribing",
            "locked",
            "applyingModel",
            "microphoneMissing",
            "queued",
            "waiting",
            "delivered",
            "failed",
            "serviceHealthy",
            "serviceUnavailable",
        ])
        #expect(presentations.allSatisfy { !$0.label.isEmpty })
        #expect(presentations.allSatisfy { !$0.symbolName.isEmpty })
        #expect(Set(presentations.map(\.accessibilityLabel)).count == states.count)
        #expect(BrainWorkflowAccessibilityState.microphoneMissing.presentation.label == "Microphone missing")
        #expect(BrainWorkflowAccessibilityState.waiting.presentation.accessibilityLabel.contains("remote runner"))
    }

    @Test
    func mapsPairedHealthyActivityWarningAndFailureStates() {
        let expectations: [(BrainOverallState, String, String, BrainPresentationTone)] = [
            (.healthy, "brain.head.profile", "Healthy", .healthy),
            (.activity, "arrow.triangle.2.circlepath", "Activity", .activity),
            (.warning, "exclamationmark.triangle", "Warning", .warning),
            (.failure, "xmark.octagon", "Failure", .failure),
        ]

        for (overall, symbolName, label, tone) in expectations {
            let presentation = BrainPresentation.state(
                for: snapshot(overall: overall),
                isPaired: true
            )
            #expect(presentation.symbolName == symbolName)
            #expect(presentation.label == label)
            #expect(presentation.tone == tone)
        }
    }

    @Test
    func unpairedPresentationIsNeutralAndActionable() {
        let presentation = BrainPresentation.state(for: nil, isPaired: false)

        #expect(presentation.symbolName == "link.badge.plus")
        #expect(presentation.label == "Not paired")
        #expect(presentation.accessibilityLabel.contains("not paired"))
        #expect(presentation.tone == .neutral)
    }

    @Test
    func groupsAllRemoteResponsibilitiesByServerProvidedScope() {
        let checks = [
            check(id: "unexpected-id.1", scope: "gateway"),
            check(id: "unexpected-id.2", scope: "remote_vault"),
            check(id: "unexpected-id.3", scope: "capture_delivery"),
            check(id: "unexpected-id.4", scope: "mac_mini_agent"),
            check(id: "unexpected-id.5", scope: "librarian"),
            check(id: "unexpected-id.6", scope: "telegram"),
            check(id: "unexpected-id.7", scope: "gmail"),
            check(id: "unexpected-id.8", scope: "publishing"),
            check(id: "unexpected-id.9", scope: "capture"),
        ]

        let groups = BrainPresentation.checkGroups(for: checks)

        #expect(groups.map(\.scope) == [
            .remoteVault,
            .captureDelivery,
            .macMiniAgent,
            .librarianAutomation,
            .telegram,
            .gmail,
            .publishing,
            .gateway,
        ])
        #expect(groups.map { $0.scope.title } == [
            "Remote vault",
            "Capture delivery",
            "remote runner agent",
            "Librarian automation",
            "Telegram",
            "Gmail",
            "Publishing",
            "Gateway",
        ])
        #expect(groups[0].checks.map(\.id) == ["unexpected-id.2"])
        #expect(groups[1].checks.map(\.id) == ["unexpected-id.3", "unexpected-id.9"])
        #expect(groups[2].checks.map(\.id) == ["unexpected-id.4"])
        #expect(groups[3].checks.map(\.id) == ["unexpected-id.5"])
        #expect(groups[4].checks.map(\.id) == ["unexpected-id.6"])
        #expect(groups[5].checks.map(\.id) == ["unexpected-id.7"])
        #expect(groups[6].checks.map(\.id) == ["unexpected-id.8"])
        #expect(groups[7].checks.map(\.id) == ["unexpected-id.1"])
    }

    @Test
    func captureQueueAndNeedsAttentionDoNotDegradeHealthyMacMiniAgent() throws {
        let checks = [
            check(id: "capture.queued", scope: "capture", state: .activity),
            check(id: "capture.needs_attention", scope: "capture", state: .failure),
            check(id: "agent.heartbeat", scope: "mac-mini-agent", state: .pass),
            check(id: "agent.scheduler", scope: "mac-mini-agent", state: .pass),
            check(id: "agent.last-run", scope: "mac-mini-agent", state: .pass),
        ]
        let snapshot = snapshot(overall: .failure, checks: checks)
        let groups = BrainPresentation.checkGroups(for: checks)
        let captures = try #require(groups.first { $0.scope == .captureDelivery })
        let agent = try #require(groups.first { $0.scope == .macMiniAgent })

        #expect(BrainPresentation.state(for: captures, in: snapshot).tone == .failure)
        #expect(BrainPresentation.state(for: agent, in: snapshot).label == "Healthy")
        #expect(BrainPresentation.state(for: agent, in: snapshot).tone == .healthy)
    }

    @Test
    func staleSnapshotNeverUsesHealthyPresentation() {
        let snapshot = snapshot(overall: .healthy, isStale: true)

        let overall = BrainPresentation.state(for: snapshot, isPaired: true)
        let passingCheck = BrainPresentation.state(for: .pass, in: snapshot)
        let freshness = BrainPresentation.freshness(for: snapshot)

        #expect(overall.label == "Stale")
        #expect(overall.symbolName == "exclamationmark.triangle")
        #expect(overall.tone == .warning)
        #expect(passingCheck.label == "Stale")
        #expect(passingCheck.tone == .warning)
        #expect(freshness.isStale)
        #expect(freshness.label == "Stale")
    }

    @MainActor
    @Test
    func macMiniUsesRemoteDoctorIdentifiersForAgentAndAutomation() throws {
        let health = BrainHealthReport(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_784_112_400),
            overall: .healthy,
            counts: BrainHealthCounts(pass: 2, activity: 0, warning: 0, failure: 0),
            checks: [
                check(id: "sync.agent", scope: "sync"),
                check(id: "automation.schedule", scope: "automation"),
            ]
        )

        let agent = try #require(MacMiniView.check(
            in: health,
            ids: MacMiniView.agentHealthCheckIDs
        ))
        let automation = try #require(MacMiniView.check(
            in: health,
            ids: MacMiniView.automationHealthCheckIDs
        ))

        #expect(agent.id == "sync.agent")
        #expect(automation.id == "automation.schedule")
    }

    @Test
    func localActivityUsesObsidianAndDoesNotRenderRemoteSiteStatus() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BrainMenu")
        let macMini = try String(
            contentsOf: sourceRoot.appendingPathComponent("Views/MacMiniView.swift"),
            encoding: .utf8
        )
        let overview = try String(
            contentsOf: sourceRoot.appendingPathComponent("Views/OverviewView.swift"),
            encoding: .utf8
        )
        let allSources = try FileManager.default
            .enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n") ?? ""

        #expect(macMini.contains("PrivateSiteAccessView(store: store)"))
        #expect(!overview.contains("PrivateSiteAccessView(store: store)"))
        #expect(overview.contains("Open in Obsidian"))
        #expect(overview.contains("Librarian is organizing"))
        #expect(overview.contains("Ready to organize"))
        #expect(!overview.contains("Awaiting processing"))
        #expect(!overview.contains("publish.latest"))
        #expect(!overview.contains(".truncationMode(.middle)"))
        #expect(macMini.contains("accessibilityFocused($accessibilityFocus, equals: .errorSummary)"))
        #expect(macMini.contains("fixedSize(horizontal: false, vertical: true)"))
        #expect(!allSources.contains("pages.dev"))
        #expect(!allSources.contains("private.example"))
    }

    @Test
    func activityRecordingLanguageDistinguishesMeetingsAndVoiceNotes() {
        let voiceNote = OverviewRecordingLanguage(isVoiceNote: true)
        let meeting = OverviewRecordingLanguage(isVoiceNote: false)
        let analysis = MeetingStatusBadge(
            kind: .analysis,
            title: "Analyzing",
            systemImage: "sparkles"
        )
        let transcription = MeetingStatusBadge(
            kind: .transcription,
            title: "Transcribing",
            systemImage: "waveform"
        )
        let pendingTranscript = MeetingStatusBadge(
            kind: .transcription,
            title: "Transcript pending",
            systemImage: "clock"
        )

        #expect(voiceNote.startingTitle == "Starting voice note")
        #expect(voiceNote.recordingTitle == "Recording voice note")
        #expect(voiceNote.pausedTitle == "Voice note paused")
        #expect(voiceNote.finalizingTitle == "Preparing voice note transcript")
        #expect(voiceNote.stopSuggestedDetail.contains("the voice note"))
        #expect(voiceNote.finalizingDetail.contains("the voice note recording"))
        #expect(voiceNote.processingTitle(for: analysis) == "Analyzing voice note")
        #expect(voiceNote.processingTitle(for: transcription) == "Transcribing voice note")
        #expect(voiceNote.processingTitle(for: pendingTranscript) == "Voice note transcript pending")
        #expect(voiceNote.savedDetail == "Voice note saved locally")

        #expect(meeting.startingTitle == "Starting meeting")
        #expect(meeting.recordingTitle == "Recording meeting")
        #expect(meeting.pausedTitle == "Meeting paused")
        #expect(meeting.finalizingTitle == "Preparing meeting transcript")
        #expect(meeting.processingTitle(for: analysis) == "Analyzing meeting")
        #expect(meeting.processingTitle(for: transcription) == "Transcribing meeting")
        #expect(meeting.processingTitle(for: pendingTranscript) == "Meeting transcript pending")
        #expect(meeting.savedDetail == "Meeting saved locally")
    }
}

private func check(
    id: String,
    scope: String,
    state: BrainCheckState = .pass
) -> BrainHealthCheck {
    BrainHealthCheck(
        id: id,
        scope: scope,
        state: state,
        summary: "\(id) summary",
        detail: "\(id) detail",
        remediation: nil
    )
}

private func snapshot(
    overall: BrainOverallState,
    isStale: Bool = false,
    checks: [BrainHealthCheck] = [check(id: "vault.remote", scope: "vault")]
) -> BrainSnapshot {
    let generatedAt = Date(timeIntervalSince1970: 1_784_112_400)
    let stateCounts = checks.reduce(into: (pass: 0, activity: 0, warning: 0, failure: 0)) {
        switch $1.state {
        case .pass: $0.pass += 1
        case .activity: $0.activity += 1
        case .warning: $0.warning += 1
        case .failure: $0.failure += 1
        }
    }
    return BrainSnapshot(
        status: BrainStatusReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            vault: BrainVaultStatus(path: "remote", state: .clean, dirtyPaths: 0),
            counts: BrainContentCounts(inbox: 0, sources: 0, notes: 0, people: 0, projects: 0),
            lastRun: nil,
            services: []
        ),
        health: BrainHealthReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            overall: overall,
            counts: BrainHealthCounts(
                pass: stateCounts.pass,
                activity: stateCounts.activity,
                warning: stateCounts.warning,
                failure: stateCounts.failure
            ),
            checks: checks
        ),
        refreshedAt: generatedAt,
        isStale: isStale
    )
}
