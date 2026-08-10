import AppKit
import SwiftUI

struct OverviewView: View {
    let store: BrainStore
    let graph: BrainAppControllerGraph?
    @State private var vaultMessage: String?

    init(store: BrainStore, graph: BrainAppControllerGraph? = nil) {
        self.store = store
        self.graph = graph
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !store.isReady {
                    ContentUnavailableView {
                        Label("Set up Brain", systemImage: "brain.head.profile")
                    } description: {
                        Text("Finish configuring Brain to see local activity.")
                    }
                } else {
                    inProgress
                    if store.deploymentMode == .local {
                        localVault
                    }
                    recentActivity
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button {
                    graph?.meetings.load()
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
        .task {
            graph?.meetings.load()
            await store.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.largeTitle.weight(.semibold))
                Text("What Brain is recording, transcribing, and organizing on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if hasActiveWork {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Working")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }

    private var inProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In progress")
                .font(.title3.weight(.semibold))

            if currentItems.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing running right now")
                            .font(.body.weight(.medium))
                        Text("New meeting and Voice Note transcription and Librarian work will appear here as soon as it starts.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(currentItems) { item in
                        activityRow(item)
                        if item.id != currentItems.last?.id {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var localVault: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Explore your vault")
                        .font(.title3.weight(.semibold))
                    Text("Open the same local Markdown folder in Obsidian or Finder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    guard let configuration = BrainRuntime.localConfiguration() else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([configuration.vaultURL])
                }
                .controlSize(.small)
                Button("Open in Obsidian", systemImage: "arrow.up.right.square") {
                    openVaultInObsidian()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let vaultMessage {
                Text(vaultMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Recent")
                .font(.title3.weight(.semibold))

            if recentItems.isEmpty {
                Text("Completed meetings, Voice Notes, and Librarian runs will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentItems) { item in
                        activityRow(item)
                        if item.id != recentItems.last?.id {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ item: OverviewActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if item.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: item.symbolName)
                        .foregroundStyle(item.color)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = item.date {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var currentItems: [OverviewActivityItem] {
        var items: [OverviewActivityItem] = []

        if let graph {
            let recordingLanguage = OverviewRecordingLanguage(
                isVoiceNote: graph.meeting.currentMeeting?.isVoiceNote == true
            )
            switch graph.meeting.state {
            case .starting:
                items.append(.active(
                    "meeting-starting",
                    recordingLanguage.startingTitle,
                    "Connecting microphone and computer audio.",
                    "mic"
                ))
            case .sourceSelectionRequired:
                items.append(.active(
                    "meeting-microphone",
                    "Choose another microphone",
                    "The selected input could not start. Use the microphone picker, then start again.",
                    "mic.badge.xmark"
                ))
            case .recording:
                items.append(.active(
                    "meeting-recording",
                    recordingLanguage.recordingTitle,
                    "Capturing microphone and computer audio locally.",
                    "record.circle.fill",
                    color: .red
                ))
            case .paused:
                items.append(.active(
                    "meeting-paused",
                    recordingLanguage.pausedTitle,
                    "Recording is paused until you resume or stop.",
                    "pause.circle"
                ))
            case .stopSuggested:
                items.append(.active(
                    "meeting-stop",
                    recordingLanguage.recordingTitle,
                    recordingLanguage.stopSuggestedDetail,
                    "record.circle.fill",
                    color: .red
                ))
            case .finalizing:
                items.append(.active(
                    "meeting-finalizing",
                    recordingLanguage.finalizingTitle,
                    recordingLanguage.finalizingDetail,
                    "waveform"
                ))
            case .idle, .startSuggested, .completed, .failed:
                break
            }

            for row in graph.meetings.rows.prefix(6) {
                let rowLanguage = OverviewRecordingLanguage(isVoiceNote: row.isVoiceNote)
                if let transcription = row.badges.first(where: {
                    $0.kind == .transcription && ["Transcribing", "Transcript pending"].contains($0.title)
                }) {
                    items.append(.active(
                        "transcript-\(row.stableID)",
                        rowLanguage.processingTitle(for: transcription),
                        row.title,
                        transcription.systemImage
                    ))
                } else if let analysis = row.badges.first(where: {
                    $0.kind == .analysis && $0.title == "Analyzing"
                }) {
                    items.append(.active(
                        "analysis-\(row.stableID)",
                        rowLanguage.processingTitle(for: analysis),
                        row.title,
                        analysis.systemImage
                    ))
                }
            }
        }

        if let activity = store.status?.activity {
            switch activity.librarianState {
            case .processing:
                items.append(OverviewActivityItem(
                    id: "librarian-processing",
                    title: "Librarian is organizing",
                    detail: activity.label,
                    symbolName: "books.vertical",
                    color: .blue,
                    isActive: true,
                    date: activity.startedAt
                ))
            case .queued:
                items.append(OverviewActivityItem(
                    id: "librarian-queued",
                    title: "Ready to organize",
                    detail: activity.label,
                    symbolName: "tray.full",
                    color: .secondary,
                    isActive: false,
                    date: nil
                ))
            case .idle:
                break
            }
        }

        return items
    }

    private var recentItems: [OverviewActivityItem] {
        var items = (graph?.meetings.rows.prefix(5) ?? []).map { row in
            let stage = row.badges.first(where: { $0.kind == .analysis })
                ?? row.badges.first(where: { $0.kind == .transcription })
            let recordingLanguage = OverviewRecordingLanguage(isVoiceNote: row.isVoiceNote)
            return OverviewActivityItem(
                id: "meeting-\(row.stableID)",
                title: row.title,
                detail: stage.map(recordingLanguage.processingTitle) ?? recordingLanguage.savedDetail,
                symbolName: stage?.systemImage ?? "person.2.wave.2",
                color: .secondary,
                isActive: false,
                date: row.startedAt
            )
        }
        if let lastRun = store.status?.lastRun {
            items.append(OverviewActivityItem(
                id: "last-librarian-run",
                title: "Librarian finished organizing",
                detail: lastRun.summary,
                symbolName: "checkmark.circle",
                color: .green,
                isActive: false,
                date: lastRun.at
            ))
        }
        return Array(items.prefix(6))
    }

    private var hasActiveWork: Bool {
        currentItems.contains(where: \.isActive)
    }

    private func openVaultInObsidian() {
        guard let configuration = BrainRuntime.localConfiguration() else {
            vaultMessage = "The local vault is not configured yet."
            return
        }
        let workspace = NSWorkspace.shared
        guard let obsidianURL = workspace.urlForApplication(withBundleIdentifier: "md.obsidian") else {
            vaultMessage = "Obsidian is not installed. Install it, then try again."
            if let downloadURL = URL(string: "https://obsidian.md/download") {
                workspace.open(downloadURL)
            }
            return
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        workspace.open(
            [configuration.vaultURL],
            withApplicationAt: obsidianURL,
            configuration: openConfiguration
        ) { _, error in
            Task { @MainActor in
                vaultMessage = error == nil
                    ? "Opened the local vault in Obsidian."
                    : "Obsidian could not open the vault: \(error?.localizedDescription ?? "Unknown error")"
            }
        }
    }
}

struct OverviewRecordingLanguage: Equatable, Sendable {
    let isVoiceNote: Bool

    private var noun: String { isVoiceNote ? "voice note" : "meeting" }
    private var titledNoun: String { isVoiceNote ? "Voice note" : "Meeting" }

    var startingTitle: String { "Starting \(noun)" }
    var recordingTitle: String { "Recording \(noun)" }
    var pausedTitle: String { "\(titledNoun) paused" }
    var finalizingTitle: String { "Preparing \(noun) transcript" }
    var stopSuggestedDetail: String {
        "Brain thinks the \(noun) may be finished and is waiting for you to stop it."
    }
    var finalizingDetail: String {
        "Saving the \(noun) recording and completing the local transcript."
    }
    var savedDetail: String { "\(titledNoun) saved locally" }

    func processingTitle(for badge: MeetingStatusBadge) -> String {
        switch (badge.kind, badge.title) {
        case (.analysis, "Analyzing"):
            "Analyzing \(noun)"
        case (.transcription, "Transcribing"):
            "Transcribing \(noun)"
        case (.transcription, "Transcript pending"):
            "\(titledNoun) transcript pending"
        default:
            badge.title
        }
    }
}

private struct OverviewActivityItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let color: Color
    let isActive: Bool
    let date: Date?

    static func active(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ symbolName: String,
        color: Color = .blue
    ) -> Self {
        Self(
            id: id,
            title: title,
            detail: detail,
            symbolName: symbolName,
            color: color,
            isActive: true,
            date: nil
        )
    }
}

// Kept for paired installations, but never shown by the local-first dashboard.
struct PrivateSiteAccessView: View {
    let store: BrainStore

    var body: some View {
        if let siteURL = store.privateSiteURL {
            LabeledContent("Private site") {
                Button("Open private site", systemImage: "arrow.up.right.square") {
                    store.openPrivateSite()
                }
                .accessibilityLabel("Open private site")
                .accessibilityValue(siteURL.absoluteString)
            }
        }
    }
}
