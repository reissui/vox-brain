import SwiftUI

@MainActor
struct CaptureActivityView: View {
    @Bindable var controller: CaptureController
    let store: BrainStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                pipelineSummary
                recentActivity
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Activity")
        .task {
            controller.checkAgain()
            await store.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture activity")
                    .font(.title2.bold())
                Text("See what Brain has received and what the Librarian is working through.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.checkAgain()
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
    }

    private var pipelineSummary: some View {
        GroupBox("Processing queue") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    metric(
                        title: "Waiting in Brain inbox",
                        value: store.status.map { String($0.counts.inbox) } ?? "—"
                    )
                    metric(
                        title: "Local delivery backlog",
                        value: store.health?.operations.map { String($0.backlogCount) } ?? "—"
                    )
                    metric(
                        title: "Capture agent",
                        value: captureAgentState
                    )
                    metric(
                        title: "Librarian automation",
                        value: librarianAutomationState
                    )
                }

                if let label = store.health?.operations?.process.label, !label.isEmpty {
                    Label("Capture agent: \(label)", systemImage: "gearshape.2")
                        .font(.callout)
                        .textSelection(.enabled)
                } else {
                    Text("The capture agent is not currently delivering an item.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if store.isStale {
                    Label("Capture status is stale; refresh or inspect Brain health.", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent captures")
                    .font(.headline)
                Spacer()
                if controller.activities.contains(where: { $0.stage == .delivered }) {
                    Button("Clear delivered") { controller.clearCompletedActivity() }
                        .buttonStyle(.plain)
                }
            }

            if controller.activities.isEmpty {
                ContentUnavailableView(
                    "No capture activity yet",
                    systemImage: "tray",
                    description: Text("New notes, links, transcripts, and screenshots will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(controller.activities) { record in
                        activityRow(record)
                        if record.id != controller.activities.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Delivery status is exact for each capture. The Brain inbox count shows work waiting for the Librarian, but the server does not yet report per-item filing completion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityRow(_ record: CaptureActivityRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.stage.symbolName)
                .foregroundStyle(record.stage.color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.label)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.kind?.title ?? "Capture")
                    if let source = record.source, !source.isEmpty {
                        Text("·")
                        Text(source)
                            .foregroundStyle(.secondary)
                    }
                    Text("·")
                    Text(record.updatedAt, style: .relative)
                    if let captureID = record.captureID {
                        Text("·")
                        Text(captureID).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(record.stage.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(record.stage.color)
                if let error = record.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var captureAgentState: String {
        guard let state = store.health?.operations?.process.state, !state.isEmpty else { return "Unknown" }
        return state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var librarianAutomationState: String {
        guard let state = store.health?.operations?.launchd.automation, !state.isEmpty else {
            return "Unknown"
        }
        return state.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private extension CaptureActivityStage {
    var title: String {
        switch self {
        case .sending: "Sending"
        case .queued: "Queued"
        case .delivering: "Delivering"
        case .delivered: "Delivered to Brain"
        case .needsAttention: "Needs attention"
        }
    }

    var symbolName: String {
        switch self {
        case .sending: "paperplane"
        case .queued: "clock"
        case .delivering: "arrow.up.circle"
        case .delivered: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .sending, .queued: .secondary
        case .delivering: .blue
        case .delivered: .green
        case .needsAttention: .red
        }
    }
}
