import SwiftUI

struct OverviewView: View {
    let store: BrainStore

    private var state: BrainStatePresentation {
        BrainPresentation.state(for: store.snapshot, isPaired: store.isReady)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if store.deploymentMode == .remote && store.isPaired {
                    PrivateSiteAccessView(store: store)
                }

                if !store.isReady {
                    ContentUnavailableView {
                        Label("Pair Brain", systemImage: "link.badge.plus")
                    } description: {
                        Text("Finish configuring Brain to see live status.")
                    }
                } else if let snapshot = store.snapshot {
                    ForEach(BrainPresentation.checkGroups(for: snapshot.health.checks)) { group in
                        CheckGroupView(group: group, snapshot: snapshot)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Checking Brain", systemImage: "brain.head.profile")
                    } description: {
                        Text("The first Brain status refresh is in progress.")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state.symbolName)
                    .font(.title)
                    .foregroundStyle(state.tone.color)
                    .accessibilityLabel(state.accessibilityLabel)
                Text(state.label)
                    .font(.title.bold())
                    .foregroundStyle(state.tone.color)
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Brain status")
                }
            }

            if let snapshot = store.snapshot {
                let freshness = BrainPresentation.freshness(for: snapshot)
                HStack(spacing: 6) {
                    Text(freshness.label)
                        .fontWeight(freshness.isStale ? .semibold : .regular)
                    Text(freshness.isStale ? "· last successful update" : "· updated")
                    Text(snapshot.refreshedAt, style: .relative)
                }
                .font(.subheadline)
                .foregroundStyle(freshness.isStale ? .orange : .secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(freshness.accessibilityLabel)
            }

            if let errorMessage = store.errorMessage {
                Label(
                    "Current connection error: \(errorMessage)",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct PrivateSiteAccessView: View {
    let store: BrainStore

    private var publishCheck: BrainHealthCheck? {
        store.health?.checks.first { $0.id == "publish.latest" }
    }

    var body: some View {
        GroupBox("Private site") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let siteURL = store.privateSiteURL {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your private Brain site")
                                .font(.headline)
                            Text(siteURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityLabel("Private site URL")
                                .accessibilityValue(siteURL.absoluteString)
                        }
                        Spacer()
                        Button {
                            store.openPrivateSite()
                        } label: {
                            Label("Open private site", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityHint("Opens the private site configured by the paired remote runner")
                    } else {
                        Label("Private site unavailable", systemImage: "lock.slash")
                            .foregroundStyle(.secondary)
                            .brainAccessibleStatus(
                                .serviceUnavailable,
                                detail: "The paired remote runner has not supplied a valid HTTPS destination"
                            )
                        Spacer()
                        Text("The paired remote runner has not supplied a valid HTTPS destination.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let status = store.status {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Awaiting processing") {
                            Text(status.counts.inbox, format: .number)
                                .monospacedDigit()
                                .foregroundStyle(status.counts.inbox > 0 ? .blue : .secondary)
                        }

                        Text(processingSummary(count: status.counts.inbox))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let lastRun = status.lastRun {
                            LabeledContent("Last Librarian activity") {
                                Text(lastRun.at, style: .relative)
                            }
                        }

                        if let publishCheck {
                            LabeledContent("Latest site publish") {
                                Text(publishLabel(for: publishCheck.state))
                                    .foregroundStyle(publishColor(for: publishCheck.state))
                            }
                            Text(publishCheck.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func processingSummary(count: Int) -> String {
        switch count {
        case 0:
            "The Brain inbox is clear. No delivered captures are currently waiting for Librarian processing."
        case 1:
            "1 capture is safely in the Brain inbox. It will not appear on the private site until the Librarian processes it."
        default:
            "\(count) captures are safely in the Brain inbox. They will not appear on the private site until the Librarian processes them."
        }
    }

    private func publishLabel(for state: BrainCheckState) -> String {
        switch state {
        case .pass: "Published"
        case .activity: "Publishing"
        case .warning: "Needs attention"
        case .failure: "Failed"
        }
    }

    private func publishColor(for state: BrainCheckState) -> Color {
        switch state {
        case .pass: .green
        case .activity: .blue
        case .warning: .orange
        case .failure: .red
        }
    }
}

private struct CheckGroupView: View {
    let group: DashboardCheckGroup
    let snapshot: BrainSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.scope.title, systemImage: group.scope.symbolName)
                    .font(.headline)
                Spacer()
                let state = BrainPresentation.state(for: group, in: snapshot)
                Label(state.label, systemImage: state.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(state.tone.color)
                    .accessibilityLabel("\(group.scope.title): \(state.accessibilityLabel)")
            }

            if group.checks.isEmpty {
                Text("No checks reported.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(group.checks) { check in
                    CheckRow(check: check, snapshot: snapshot)
                }
            }
        }
    }
}

private struct CheckRow: View {
    let check: BrainHealthCheck
    let snapshot: BrainSnapshot

    private var state: BrainStatePresentation {
        BrainPresentation.state(for: check.state, in: snapshot)
    }

    private var freshness: BrainFreshnessPresentation {
        BrainPresentation.freshness(for: snapshot)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.title3)
                .foregroundStyle(state.tone.color)
                .frame(width: 24)
                .accessibilityLabel(state.accessibilityLabel)

            VStack(alignment: .leading, spacing: 5) {
                Text(check.summary)
                    .font(.body.weight(.semibold))
                Text(check.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let remediation = check.remediation, !remediation.isEmpty {
                    Label(remediation, systemImage: "wrench.and.screwdriver")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                HStack(spacing: 5) {
                    Text(freshness.label)
                        .fontWeight(freshness.isStale ? .semibold : .regular)
                    Text("·")
                    Text(snapshot.refreshedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(freshness.isStale ? Color.orange : Color.secondary.opacity(0.75))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(freshness.accessibilityLabel)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
