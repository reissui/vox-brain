import Foundation
import Observation
import SwiftUI

protocol MeetingLibraryStoring: Sendable {
    func list() throws -> [MeetingListEntry]
    func load(_ id: UUID) throws -> StoredMeeting
    func save(_ meeting: MeetingRecord, utterances: [MeetingUtterance]) throws
    func delete(_ id: UUID, confirmed: Bool) throws
}

extension MeetingStore: MeetingLibraryStoring {}

enum MeetingBadgeKind: String, CaseIterable, Equatable, Sendable {
    case recording
    case transcription
    case analysis
    case audio
    case upload
    case corrupt
}

struct MeetingStatusBadge: Equatable, Identifiable, Sendable {
    let kind: MeetingBadgeKind
    let title: String
    let systemImage: String

    var id: MeetingBadgeKind { kind }
    var accessibilityLabel: String { "\(kind.rawValue.capitalized) status: \(title)" }
}

struct MeetingListRowModel: Equatable, Identifiable, Sendable {
    let id: UUID?
    let title: String
    let startedAt: Date?
    let dateText: String
    let durationText: String
    let isUnread: Bool
    let badges: [MeetingStatusBadge]
    let isAvailable: Bool
    let isVoiceNote: Bool
    let unavailableReason: String?
    fileprivate let searchableText: String

    var stableID: String { id?.uuidString ?? "unavailable-\(title)-\(dateText)" }
    var accessibilityLabel: String {
        ([isUnread ? (isVoiceNote ? "New voice note" : "New meeting") : "", title, dateText, durationText]
            + badges.map(\.accessibilityLabel))
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

enum MeetingLibraryScope: Equatable, Sendable {
    case meetings
    case voiceNotes

    var title: String {
        switch self {
        case .meetings: "Meetings"
        case .voiceNotes: "Voice Notes"
        }
    }

    var emptyTitle: String {
        switch self {
        case .meetings: "No meetings yet"
        case .voiceNotes: "No voice notes yet"
        }
    }

    var emptyDescription: String {
        switch self {
        case .meetings: "Completed and active meetings stored on this Mac appear here."
        case .voiceNotes: "Completed voice notes stored on this Mac appear here."
        }
    }

    var symbolName: String {
        switch self {
        case .meetings: "person.2.wave.2"
        case .voiceNotes: "mic.circle"
        }
    }

    func includes(_ row: MeetingListRowModel) -> Bool {
        switch self {
        case .meetings: !row.isVoiceNote
        case .voiceNotes: row.isVoiceNote
        }
    }
}

enum MeetingsLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct MeetingsViewModel: Equatable, Sendable {
    let state: MeetingsLoadState
    let rows: [MeetingListRowModel]
    let query: String

    var visibleRows: [MeetingListRowModel] {
        visibleRows(in: nil)
    }

    func visibleRows(in scope: MeetingLibraryScope?) -> [MeetingListRowModel] {
        let scopedRows = scope.map { scope in rows.filter(scope.includes) } ?? rows
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return scopedRows }
        return scopedRows.filter { $0.searchableText.contains(needle) }
    }

    var isEmpty: Bool { state == .loaded && rows.isEmpty }
    func isEmpty(in scope: MeetingLibraryScope) -> Bool {
        state == .loaded && rows.filter(scope.includes).isEmpty
    }

    var hasNoSearchResults: Bool {
        state == .loaded && !rows.isEmpty && !query.isEmpty && visibleRows.isEmpty
    }

    func hasNoSearchResults(in scope: MeetingLibraryScope) -> Bool {
        let scopedRows = rows.filter(scope.includes)
        return state == .loaded
            && !scopedRows.isEmpty
            && !query.isEmpty
            && visibleRows(in: scope).isEmpty
    }
}

@MainActor
@Observable
final class MeetingsController {
    private(set) var state: MeetingsLoadState = .idle
    private(set) var rows: [MeetingListRowModel] = []
    var query = ""

    var viewModel: MeetingsViewModel {
        MeetingsViewModel(state: state, rows: rows, query: query)
    }

    @ObservationIgnored private let store: any MeetingLibraryStoring
    @ObservationIgnored private let analysisStore: any MeetingAnalysisStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        store: any MeetingLibraryStoring = MeetingStore(),
        analysisStore: any MeetingAnalysisStoring = FileMeetingAnalysisStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.analysisStore = analysisStore
        self.now = now
    }

    /// Loads only Application Support state. Search subsequently filters this
    /// in-memory index and cannot contact the paired Brain server.
    func load() {
        state = .loading
        do {
            rows = try store.list().map(rowModel).sorted {
                switch ($0.startedAt, $1.startedAt) {
                case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
                case (_?, nil): true
                case (nil, _?): false
                default: $0.stableID < $1.stableID
                }
            }
            state = .loaded
        } catch {
            rows = []
            state = .failed(Self.bounded(error))
        }
    }

    func markOpened(_ id: UUID) {
        do {
            var stored = try store.load(id)
            guard stored.meeting.isUnread else { return }
            stored.meeting.isUnread = false
            try store.save(stored.meeting, utterances: stored.utterances)
            load()
        } catch {
            // Opening the meeting remains useful even if the read marker could
            // not be saved. The detail view will try the same idempotent write.
        }
    }

    func storedMeetingForPostProcessing(_ id: UUID) throws -> StoredMeeting {
        try store.load(id)
    }

    func markAnalysisRunning(_ stored: StoredMeeting) throws -> MeetingRecord {
        var meeting = stored.meeting
        meeting.analysisState = .running
        try store.save(meeting, utterances: stored.utterances)
        load()
        return meeting
    }

    @discardableResult
    func mergeAnalysisResult(_ result: MeetingAnalysisRunResult) throws -> MeetingRecord {
        let current = try store.load(result.meeting.id)
        var merged = current.meeting
        merged.analysisState = result.meeting.analysisState
        if merged.titleSource != .manual, result.meeting.titleSource == .analysis {
            merged.title = result.meeting.title
            merged.titleSource = .analysis
        }
        try store.save(merged, utterances: current.utterances)
        load()
        return merged
    }

    private func rowModel(for entry: MeetingListEntry) -> MeetingListRowModel {
        switch entry {
        case .available(let meeting):
            do {
                let stored = try store.load(meeting.id)
                let analysis = try? analysisStore.load(meetingID: meeting.id)
                let editor = SpeakerEditor(
                    utterances: stored.utterances,
                    state: analysis?.speakerState ?? SpeakerEditingState()
                )
                let speakers = editor.speakers.values.map(\.displayName)
                let searchable = ([
                    meeting.title,
                    analysis?.analysis.summary ?? "",
                    stored.utterances.map(\.text).joined(separator: " "),
                ] + speakers).joined(separator: " ").lowercased()
                return MeetingListRowModel(
                    id: meeting.id,
                    title: meeting.title,
                    startedAt: meeting.startedAt,
                    dateText: Self.dateFormatter.string(from: meeting.startedAt),
                    durationText: Self.durationText(
                        from: meeting.startedAt,
                        to: meeting.endedAt ?? now()
                    ),
                    isUnread: meeting.isUnread,
                    badges: Self.badges(for: meeting),
                    isAvailable: true,
                    isVoiceNote: meeting.isVoiceNote,
                    unavailableReason: nil,
                    searchableText: searchable
                )
            } catch {
                return unavailableRow(
                    id: meeting.id,
                    directoryName: meeting.title,
                    reason: Self.bounded(error)
                )
            }

        case .unavailable(let unavailable):
            return unavailableRow(
                id: unavailable.id,
                directoryName: unavailable.directoryName,
                reason: Self.unavailableDescription(unavailable.reason)
            )
        }
    }

    private func unavailableRow(
        id: UUID?,
        directoryName: String,
        reason: String
    ) -> MeetingListRowModel {
        MeetingListRowModel(
            id: id,
            title: "Unavailable meeting",
            startedAt: nil,
            dateText: directoryName,
            durationText: "",
            isUnread: false,
            badges: [MeetingStatusBadge(
                kind: .corrupt,
                title: "Local data unavailable",
                systemImage: "exclamationmark.triangle.fill"
            )],
            isAvailable: false,
            isVoiceNote: false,
            unavailableReason: reason,
            searchableText: "unavailable corrupt \(directoryName) \(reason)".lowercased()
        )
    }

    static func badges(for meeting: MeetingRecord) -> [MeetingStatusBadge] {
        [
            MeetingStatusBadge(
                kind: .recording,
                title: lifecycleTitle(meeting.lifecycleState),
                systemImage: lifecycleSymbol(meeting.lifecycleState)
            ),
            MeetingStatusBadge(
                kind: .transcription,
                title: transcriptionTitle(meeting.transcriptionState),
                systemImage: transcriptionSymbol(meeting.transcriptionState)
            ),
            MeetingStatusBadge(
                kind: .analysis,
                title: analysisTitle(meeting.analysisState),
                systemImage: analysisSymbol(meeting.analysisState)
            ),
            MeetingStatusBadge(
                kind: .audio,
                title: meeting.retainedAudio == nil ? "Not retained" : "Retained locally",
                systemImage: meeting.retainedAudio == nil ? "waveform.slash" : "waveform"
            ),
            MeetingStatusBadge(
                kind: .upload,
                title: uploadTitle(meeting.uploadState),
                systemImage: uploadSymbol(meeting.uploadState)
            ),
        ]
    }

    nonisolated static func durationText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func lifecycleTitle(_ state: MeetingLifecycleState) -> String {
        switch state {
        case .idle: "Idle"
        case .startSuggested: "Start suggested"
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopSuggested: "Stop suggested"
        case .finalizing: "Finalizing"
        case .completed: "Completed"
        case .failed: "Recording failed"
        }
    }

    private static func lifecycleSymbol(_ state: MeetingLifecycleState) -> String {
        switch state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .completed: "checkmark.circle.fill"
        default: "clock"
        }
    }

    private static func analysisTitle(_ state: MeetingAnalysisState) -> String {
        switch state {
        case .notRequested: "Not analyzed"
        case .running: "Analyzing"
        case .completed: "Analyzed"
        case .failed: "Analysis failed"
        }
    }

    private static func transcriptionTitle(_ state: MeetingTranscriptionState) -> String {
        switch state {
        case .pending: "Transcript pending"
        case .processing: "Transcribing"
        case .completed: "Transcript ready"
        case .failed: "Transcription failed"
        }
    }

    private static func transcriptionSymbol(_ state: MeetingTranscriptionState) -> String {
        switch state {
        case .pending: "clock"
        case .processing: "waveform"
        case .completed: "text.badge.checkmark"
        case .failed: "exclamationmark.bubble.fill"
        }
    }

    private static func analysisSymbol(_ state: MeetingAnalysisState) -> String {
        switch state {
        case .notRequested: "sparkles"
        case .running: "sparkles"
        case .completed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private static func uploadTitle(_ state: MeetingUploadState) -> String {
        switch state {
        case .notUploaded: "Not uploaded"
        case .queued: "Upload queued"
        case .delivering: "Delivering"
        case .delivered: "Delivered to inbox"
        case .failed: "Upload failed"
        }
    }

    private static func uploadSymbol(_ state: MeetingUploadState) -> String {
        switch state {
        case .notUploaded: "icloud.slash"
        case .queued: "clock.arrow.circlepath"
        case .delivering: "icloud.and.arrow.up"
        case .delivered: "icloud.and.arrow.up.fill"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    private static func unavailableDescription(_ reason: UnavailableMeetingReason) -> String {
        switch reason {
        case .unsafeEntry: "The local entry is not a safe meeting directory."
        case .missingMeeting: "Meeting metadata is missing."
        case .corruptMeeting: "Meeting metadata is corrupt."
        case .missingTranscript: "The local transcript is missing."
        case .corruptTranscript: "The local transcript is corrupt."
        case .mismatchedIdentifier: "The meeting identifier does not match its directory."
        }
    }

    private static func bounded(_ error: Error) -> String {
        String(error.localizedDescription.prefix(240))
    }
}

struct MeetingsView: View {
    @State private var controller: MeetingsController
    @State private var query = ""
    private let scope: MeetingLibraryScope
    private let openMeeting: (UUID) -> Void

    init(
        controller: MeetingsController = MeetingsController(),
        scope: MeetingLibraryScope = .meetings,
        openMeeting: @escaping (UUID) -> Void = { _ in }
    ) {
        _controller = State(initialValue: controller)
        self.scope = scope
        self.openMeeting = openMeeting
    }

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .loading:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(index == 0 ? "Loading meetings" : "Reading local details")
                                    .font(.body.weight(.medium))
                                Text(index == 0
                                     ? "Brain is checking saved transcripts and processing states."
                                     : "Titles, dates, and transcript status will appear here.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        if index < 2 { Divider().padding(.leading, 46) }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading local meetings and processing states")
            case .failed(let message):
                ContentUnavailableView(
                    "\(scope.title) unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where viewModel.isEmpty(in: scope):
                ContentUnavailableView(
                    scope.emptyTitle,
                    systemImage: scope.symbolName,
                    description: Text(scope.emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where viewModel.hasNoSearchResults(in: scope):
                ContentUnavailableView.search(text: query)
            case .loaded:
                meetingList
            }
        }
        .navigationTitle(scope.title)
        .searchable(text: $query, prompt: "Search local \(scope.title.lowercased())")
        .task { controller.load() }
    }

    private var viewModel: MeetingsViewModel {
        MeetingsViewModel(state: controller.state, rows: controller.rows, query: query)
    }

    private var meetingList: some View {
        List(viewModel.visibleRows(in: scope), id: \.stableID) { row in
            if let id = row.id, row.isAvailable {
                Button { openMeeting(id) } label: { meetingRow(row) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
            } else {
                meetingRow(row)
            }
        }
        .listStyle(.inset)
    }

    private func meetingRow(_ row: MeetingListRowModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(row.title).font(.headline)
                if row.isUnread {
                    Text("New")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityHidden(true)
                }
                Spacer()
                Text(row.durationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(row.dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(row.badges) { badge in
                    Label(badge.title, systemImage: badge.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(badge.accessibilityLabel)
                }
            }
            if let reason = row.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
