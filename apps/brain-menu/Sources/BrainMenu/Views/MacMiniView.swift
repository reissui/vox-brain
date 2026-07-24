import AppKit
import SwiftUI

@MainActor
struct MacMiniView: View {
    static let agentHealthCheckIDs: Set<String> = ["sync.agent", "agent.heartbeat"]
    static let automationHealthCheckIDs: Set<String> = [
        "automation.progress", "automation.schedule", "agent.scheduler", "automation.librarian",
    ]
    static let queueHealthCheckIDs: Set<String> = [
        "agent.queue_heartbeat", "agent.queue_backlog", "agent.process_progress",
    ]
    static let recoveryCommands: [MacMiniRecoveryCommand] = [
        MacMiniRecoveryCommand(
            id: "status",
            title: "Check Brain status",
            command: "cd \"$HOME/dev/vox-brain\" && scripts/brain status"
        ),
        MacMiniRecoveryCommand(
            id: "doctor",
            title: "Run Brain diagnostics",
            command: "cd \"$HOME/dev/vox-brain\" && scripts/brain doctor"
        ),
        MacMiniRecoveryCommand(
            id: "kickstart",
            title: "Restart Brain Agent",
            command: "launchctl kickstart -k \"gui/$(id -u)/app.voxbrain.agent\""
        ),
        MacMiniRecoveryCommand(
            id: "logs",
            title: "Follow Agent errors",
            command: "tail -n 200 -F \"$HOME/Library/Application Support/Brain Agent/logs/agent.stderr.log\""
        ),
    ]

    @State private var store: BrainStore
    @State private var controller: RemoteBrainController
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case errorSummary
    }

    init(store: BrainStore? = nil, controller: RemoteBrainController? = nil) {
        let resolvedStore = store ?? BrainStore()
        _store = State(initialValue: resolvedStore)
        _controller = State(
            initialValue: controller ?? RemoteBrainController.live(
                refresh: { await resolvedStore.refresh() }
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Remote runner status")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                pairedInstanceSection
                PrivateSiteAccessView(store: store)
                remoteServiceSection(
                    title: "Agent heartbeat",
                    systemImage: "waveform.path.ecg",
                    check: check(ids: Self.agentHealthCheckIDs)
                )
                remoteServiceSection(
                    title: "Librarian schedule",
                    systemImage: "clock.arrow.2.circlepath",
                    check: check(ids: Self.automationHealthCheckIDs)
                )
                remoteServiceSection(
                    title: "Capture delivery",
                    systemImage: "shippingbox.and.arrow.backward",
                    check: check(ids: Self.queueHealthCheckIDs)
                )
                operationalDetailsSection
                lastJobSection
                recoveryCommandsSection
                connectionTestSection
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Remote Runner")
        .task {
            store.start()
            await controller.refresh()
            accessibilityFocus = .heading
        }
    }

    private var operationalDetailsSection: some View {
        GroupBox("Operational detail") {
            if let operations = store.health?.operations {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(
                        "Last Queue poll",
                        value: operations.lastSuccessfulPoll?.formatted(
                            date: .abbreviated, time: .standard
                        ) ?? "Not yet"
                    )
                    LabeledContent("Queue backlog", value: "\(operations.backlogCount)")
                    LabeledContent("Agent process", value: operations.process.state.capitalized)
                    LabeledContent("Agent launchd", value: operations.launchd.agent.capitalized)
                    LabeledContent(
                        "Librarian launchd",
                        value: operations.launchd.automation.replacingOccurrences(of: "_", with: " ").capitalized
                    )
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            } else {
                Text("The paired Agent has not supplied operational detail yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var recoveryCommandsSection: some View {
        GroupBox("Setup and recovery commands") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.recoveryCommands) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.title).font(.headline)
                            Spacer()
                            Button("Copy") { copy(item.command) }
                                .accessibilityLabel("Copy \(item.title) command")
                        }
                        Text(item.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var pairedInstanceSection: some View {
        GroupBox("Paired instance") {
            VStack(alignment: .leading, spacing: 10) {
                if let instance = controller.pairedInstance {
                    LabeledContent("Instance", value: instance.instanceID)
                    LabeledContent("Address", value: instance.baseURL.absoluteString)
                    LabeledContent("This device", value: instance.deviceName)
                    LabeledContent("Device ID", value: instance.deviceID)
                    LabeledContent(
                        "Scopes",
                        value: instance.scopes.map(\.rawValue).sorted().joined(separator: ", ")
                    )
                } else {
                    Label("Brain.app is not paired with a remote instance.", systemImage: "link.badge.plus")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private func remoteServiceSection(
        title: String,
        systemImage: String,
        check: BrainHealthCheck?
    ) -> some View {
        GroupBox(title) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: check.map { symbol(for: $0.state) } ?? systemImage)
                    .font(.title2)
                    .foregroundStyle(check.map { color(for: $0.state) } ?? .secondary)

                VStack(alignment: .leading, spacing: 5) {
                    Text(check?.summary ?? "Not reported")
                        .font(.headline)
                    Text(check?.detail ?? "The paired instance has not supplied this status yet.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let remediation = check?.remediation {
                        Label(remediation, systemImage: "wrench.and.screwdriver")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) service health")
            .accessibilityValue(
                check.map { "\($0.state.rawValue). \($0.summary). \($0.detail)" }
                    ?? "Unavailable. The paired instance has not reported this service."
            )
        }
    }

    private var lastJobSection: some View {
        GroupBox("Last job") {
            VStack(alignment: .leading, spacing: 8) {
                if let id = controller.submittedJobID {
                    LabeledContent("Job ID", value: id)
                    if let kind = controller.submittedJobKind {
                        LabeledContent("Type", value: kind.rawValue.capitalized)
                    }
                    if let state = controller.displayedState {
                        LabeledContent("State", value: state.rawValue.capitalized)
                    } else {
                        LabeledContent("State", value: "Refreshing")
                    }
                } else if let lastRun = store.status?.lastRun {
                    LabeledContent("Librarian", value: lastRun.summary)
                    LabeledContent(
                        "Completed",
                        value: lastRun.at.formatted(date: .abbreviated, time: .standard)
                    )
                } else {
                    Text("No remote job has been reported.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private var connectionTestSection: some View {
        GroupBox("Connection test") {
            HStack(spacing: 12) {
                connectionLabel
                Spacer()
                Button {
                    Task {
                        await controller.refresh()
                        await store.refresh()
                        if case .failed = controller.connectionState {
                            accessibilityFocus = .errorSummary
                        }
                    }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(controller.connectionState == .testing || controller.isPolling)
                .keyboardShortcut(.defaultAction)
                .accessibilityValue(
                    controller.connectionState == .testing || controller.isPolling
                        ? "Disabled"
                        : "Enabled"
                )
            }
            .padding(.vertical, 8)
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch controller.connectionState {
        case .notTested:
            Label("Not tested", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing paired HTTPS instance…")
            }
        case .reachable:
            Label("Paired instance is reachable", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .brainAccessibleStatus(.failed, detail: message)
            .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
        }
    }

    private func check(ids: Set<String>) -> BrainHealthCheck? {
        Self.check(in: store.health, ids: ids)
    }

    static func check(
        in health: BrainHealthReport?,
        ids: Set<String>
    ) -> BrainHealthCheck? {
        health?.checks.first { ids.contains($0.id) }
    }

    private func symbol(for state: BrainCheckState) -> String {
        switch state {
        case .pass: "checkmark.circle.fill"
        case .activity: "arrow.triangle.2.circlepath.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private func color(for state: BrainCheckState) -> Color {
        switch state {
        case .pass: .green
        case .activity: .blue
        case .warning: .orange
        case .failure: .red
        }
    }
}
