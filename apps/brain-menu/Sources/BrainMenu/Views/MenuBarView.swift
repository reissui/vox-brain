import AppKit
import SwiftUI

struct MenuBarView: View {
    let store: BrainStore
    let graph: BrainAppControllerGraph?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    init(store: BrainStore, graph: BrainAppControllerGraph? = nil) {
        self.store = store
        self.graph = graph
    }

    init(graph: BrainAppControllerGraph) {
        store = graph.store
        self.graph = graph
    }

    private var remoteState: BrainStatePresentation {
        BrainPresentation.state(for: store.snapshot, isPaired: store.isReady)
    }

    private var activity: BrainAppActivity { graph?.activity ?? .remote }

    private var symbolName: String {
        activity == .remote ? remoteState.symbolName : activity.symbolName
    }

    private var statusLabel: String {
        activity == .remote ? remoteState.label : activity.label
    }

    private var statusColor: Color {
        switch activity {
        case .remote: remoteState.tone.color
        case .recording: .red
        case .transcribing: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(statusLabel)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Brain")
                        .font(.headline)
                    Text(statusLabel)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Brain status")
                }
            }

            if activity == .remote {
                snapshotSummary
            } else {
                Text(activityDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = store.errorMessage {
                Label(
                    "Current connection error: \(errorMessage)",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button {
                Task { await graph?.toggleMeeting() }
            } label: {
                Label(meetingActionTitle, systemImage: meetingActionSymbol)
            }
            .disabled(
                graph == nil
                    || graph?.meeting.state == .finalizing
            )

            Divider()

            HStack {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Spacer()

                Button("Open Brain") {
                    openWindow(id: BrainMenuApp.dashboardWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(.defaultAction)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            openDashboard()
            dismiss()
        }
        .task {
            if let graph {
                graph.start()
            } else {
                store.start()
            }
        }
    }

    private func openDashboard() {
        openWindow(id: BrainMenuApp.dashboardWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var activityDetail: String {
        switch activity {
        case .remote: ""
        case .recording(let label): "\(label). Local audio is never uploaded."
        case .transcribing(let label): "\(label) locally with VoxType."
        }
    }

    private var meetingActionTitle: String {
        graph?.meeting.isCapturingAudio == true ? "Stop Meeting" : "Start Meeting"
    }

    private var meetingActionSymbol: String {
        graph?.meeting.isCapturingAudio == true ? "stop.circle" : "record.circle"
    }

    @ViewBuilder
    private var snapshotSummary: some View {
        if !store.isReady {
            VStack(alignment: .leading, spacing: 5) {
                Text("Finish setting up Brain to see its status.")
                    .foregroundStyle(.secondary)
                Button("Set Up Brain…") {
                    openWindow(id: BrainMenuApp.dashboardWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(snapshot.isStale ? "Last successful update" : "Updated") {
                    Text(snapshot.refreshedAt, style: .relative)
                }

                LabeledContent("Ready to organize") {
                    Text(snapshot.status.counts.inbox, format: .number)
                        .monospacedDigit()
                }
            }
        } else {
            Text("Checking Brain…")
                .foregroundStyle(.secondary)
        }
    }
}

extension BrainPresentationTone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .healthy: .green
        case .activity: .blue
        case .warning: .orange
        case .failure: .red
        }
    }
}
