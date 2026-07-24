import SwiftUI

@MainActor
struct ActionsView: View {
    @State private var store: BrainStore
    @State private var controller: RemoteBrainController

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
            VStack(alignment: .leading, spacing: 18) {
                pairedInstanceSection
                actionSection

                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.submittedJobID != nil {
                    jobSection
                }

                if let output = controller.output {
                    outputSection(output)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Actions")
        .task {
            store.start()
            await controller.refresh()
        }
        .confirmationDialog(
            controller.pendingConfirmation.map { "Run \($0.title)?" }
                ?? "Run Brain action?",
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: controller.pendingConfirmation
        ) { action in
            Button(action.title, role: .destructive) {
                Task { await controller.confirmPendingAction() }
            }
            Button("Cancel", role: .cancel) {
                controller.cancelPendingAction()
            }
        } message: { action in
            Text(action.confirmationMessage)
        }
    }

    private var pairedInstanceSection: some View {
        GroupBox(store.deploymentMode == .local ? "Local Brain" : "Paired Brain") {
            HStack(spacing: 12) {
                Image(systemName: store.deploymentMode == .local
                      ? "internaldrive.fill"
                      : controller.pairedInstance == nil ? "link.badge.plus" : "link.circle.fill")
                    .foregroundStyle(controller.pairedInstance == nil ? Color.gray : Color.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.deploymentMode == .local
                         ? "This Mac"
                         : controller.pairedInstance?.instanceID ?? "Not paired")
                        .font(.headline)
                    if store.deploymentMode == .local,
                       let configuration = BrainRuntime.localConfiguration() {
                        Text(configuration.vaultPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let address = controller.pairedInstance?.baseURL.host {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if store.isRefreshing || controller.connectionState == .testing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Brain")
                }
                Button {
                    Task {
                        await controller.refresh()
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isPolling)
            }
            .padding(.vertical, 6)
        }
    }

    private var actionSection: some View {
        GroupBox("Librarian actions") {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.deploymentMode == .local
                     ? "These controls run fixed Brain CLI commands on this Mac. Every action requires confirmation."
                     : "These controls submit fixed job types to the paired instance. Every job requires confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        controller.request(.process)
                    } label: {
                        Label("Process inbox", systemImage: "tray.full")
                    }
                    .disabled(controller.isMutating || controller.pairedInstance == nil)

                    Button {
                        controller.request(.digest)
                    } label: {
                        Label("Write digest", systemImage: "sun.horizon")
                    }
                    .disabled(controller.isMutating || controller.pairedInstance == nil)

                    if controller.isSubmitting || controller.isPolling {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Brain job in progress")
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var jobSection: some View {
        GroupBox("Last job") {
            VStack(alignment: .leading, spacing: 9) {
                if let id = controller.submittedJobID {
                    LabeledContent("Job ID", value: id)
                        .textSelection(.enabled)
                }
                if let kind = controller.submittedJobKind {
                    LabeledContent("Type", value: kind.rawValue.capitalized)
                }
                if let state = controller.displayedState {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: state))
                            .foregroundStyle(color(for: state))
                        Text(state.rawValue.capitalized)
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let failure = controller.publicFailure {
                    LabeledContent("Failure", value: failure.code)
                    if let remediation = failure.remediation, !remediation.isEmpty {
                        Label(remediation, systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func outputSection(_ output: RemoteBrainOutput) -> some View {
        GroupBox("Job output") {
            VStack(alignment: .leading, spacing: 14) {
                outputBlock(title: "Standard output", text: output.standardOutput)
                Divider()
                outputBlock(title: "Standard error", text: output.standardError)
                if output.isTruncated {
                    Label("Output was truncated to the safe display limit.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func outputBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "(no output)" : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented { controller.cancelPendingAction() }
            }
        )
    }

    private func symbol(for state: BrainJobState) -> String {
        switch state {
        case .queued: "clock.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    private func color(for state: BrainJobState) -> Color {
        switch state {
        case .queued: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}
