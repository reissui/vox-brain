import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum MeetingTranscriptReviewMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case processed = "Processed"
    case raw = "Raw"

    var id: Self { self }
}

struct MeetingTranscriptReviewRowModel: Equatable, Identifiable, Sendable {
    let id: UUID
    let utteranceIDs: [UUID]
    let startMilliseconds: Int64
    let timestamp: String
    let speakerName: String
    let provenance: SpeakerAssignmentProvenance
    let text: String
    let isSelected: Bool

    var accessibilityLabel: String { "\(timestamp), \(speakerName): \(text)" }
}

struct MeetingTranscriptQualityViewModel: Equatable, Sendable {
    let rawUtteranceCount: Int
    let retainedPreviewCount: Int
    let skippedFinalCount: Int
    let correctionCount: Int
}

struct MeetingTranscriptModelViewModel: Equatable, Sendable {
    let requested: String
    let effective: String
    let verificationLabel: String
    let isVerified: Bool
}

struct MeetingTranscriptReviewViewModel: Equatable, Sendable {
    let mode: MeetingTranscriptReviewMode
    let processedIsCurrent: Bool
    let processingIsRetrying: Bool
    let processingMessage: String?
    let bullets: [String]
    let rawRows: [MeetingTranscriptReviewRowModel]
    let processedRows: [MeetingTranscriptReviewRowModel]
    let quality: MeetingTranscriptQualityViewModel
    let model: MeetingTranscriptModelViewModel
    let canCreateImprovementPrompt: Bool

    var rows: [MeetingTranscriptReviewRowModel] {
        switch mode {
        case .processed: processedIsCurrent ? processedRows : []
        case .raw: rawRows
        }
    }

    var fullText: String {
        rows.map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n\n")
    }
}

@MainActor
final class SystemMeetingAudioPlayer: MeetingAudioPlaying {
    var durationMilliseconds: Int64 {
        Int64(max(0, player?.duration ?? 0) * 1_000)
    }
    var elapsedMilliseconds: Int64 {
        Int64(max(0, player?.currentTime ?? 0) * 1_000)
    }
    var onProgress: (@MainActor (Int64) -> Void)?
    var onCompletion: (@MainActor () -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) throws {
        stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    func play() throws {
        guard let player, player.play() else {
            throw CocoaError(.fileReadUnknown)
        }
        startTimer()
    }

    func pause() {
        player?.pause()
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
    }

    func seek(to milliseconds: Int64) throws {
        guard let player else { throw CocoaError(.fileReadUnknown) }
        player.currentTime = min(max(0, Double(milliseconds) / 1_000), player.duration)
        onProgress?(elapsedMilliseconds)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else {
                    self?.timer?.invalidate()
                    self?.timer = nil
                    return
                }
                self.onProgress?(self.elapsedMilliseconds)
                if !player.isPlaying && player.currentTime >= player.duration {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.onCompletion?()
                }
            }
        }
    }
}

@MainActor
struct MeetingTranscriptReviewView: View {
    let model: MeetingTranscriptReviewViewModel
    let audioPlayback: MeetingAudioPlaybackController
    let selectMode: (MeetingTranscriptReviewMode) -> Void
    let retryProcessing: () -> Void
    let seek: (Int64) -> Void
    let toggleSelection: ([UUID]) -> Void
    let copyTranscript: () -> Void
    let createImprovementPrompt: () -> String?

    @State private var promptPresentation: ImprovementPromptPresentation?
    @State private var showsTechnicalDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.mode == .processed && !model.processedIsCurrent {
                processedUnavailable
            } else {
                transcriptContent
            }
        }
        .sheet(item: $promptPresentation) { presentation in
            MeetingImprovementPromptSheet(prompt: presentation.prompt)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transcriptVersionPicker
                    processingStatus
                    Spacer()
                    transcriptActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        transcriptVersionPicker
                        processingStatus
                    }
                    transcriptActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if audioPlayback.meetingID != nil {
                MeetingAudioPlayerView(controller: audioPlayback)
            }

            qualitySummary
            technicalDetails
        }
        .padding(20)
        .background(.background.secondary)
    }

    private var transcriptVersionPicker: some View {
        Picker("Transcript version", selection: Binding(
            get: { model.mode },
            set: { mode in selectMode(mode) }
        )) {
            ForEach(MeetingTranscriptReviewMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 230)
    }

    @ViewBuilder
    private var processingStatus: some View {
        if model.processingIsRetrying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Processing")
            }
            .foregroundStyle(.secondary)
            .statusCapsule()
        } else if model.processedIsCurrent {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .statusCapsule()
        } else {
            Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .statusCapsule()
        }
    }

    private var transcriptActions: some View {
        HStack {
            Button("Copy Transcript", systemImage: "doc.on.doc") {
                copyTranscript()
            }
            .disabled(model.rows.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityHint("Copies the full \(model.mode.rawValue.lowercased()) transcript with speaker labels.")
            Button("Create Improvement Prompt", systemImage: "wrench.and.screwdriver") {
                if let prompt = createImprovementPrompt() {
                    promptPresentation = ImprovementPromptPresentation(prompt: prompt)
                }
            }
            .disabled(!model.canCreateImprovementPrompt)
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private var qualitySummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                qualityItems
            }
            VStack(alignment: .leading, spacing: 8) {
                qualityItems
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var qualityItems: some View {
        Label("\(model.quality.rawUtteranceCount) utterances", systemImage: "text.bubble")
        Label("\(model.quality.retainedPreviewCount) audio previews", systemImage: "waveform")
        Label("\(model.quality.correctionCount) corrections", systemImage: "wand.and.stars")
        if model.quality.skippedFinalCount > 0 {
            Label(
                "\(model.quality.skippedFinalCount) skipped spans",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("Requested").foregroundStyle(.secondary)
                    Text(model.model.requested)
                }
                GridRow {
                    Text("Effective").foregroundStyle(.secondary)
                    Text(model.model.effective)
                }
                GridRow {
                    Text("Verification").foregroundStyle(.secondary)
                    Label(
                        model.model.verificationLabel,
                        systemImage: model.model.isVerified
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(model.model.isVerified ? .green : .orange)
                }
            }
            .padding(.top, 8)
            .textSelection(.enabled)
        } label: {
            Label("Transcription details", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var processedUnavailable: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(model.processingIsRetrying ? Color.accentColor.opacity(0.12) : Color.orange.opacity(0.12))
                    .frame(width: 54, height: 54)
                if model.processingIsRetrying {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: "text.badge.xmark")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
            }
            VStack(spacing: 7) {
                Text(model.processingIsRetrying ? "Cleaning up transcript" : "Processed transcript isn’t ready")
                    .font(.title3.bold())
                Text(
                    model.processingMessage
                        ?? "Brain can retry without changing your immutable Raw transcript."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Text("Raw remains available at all times.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button("View Raw", systemImage: "doc.plaintext") {
                    selectMode(.raw)
                }
                if !model.processingIsRetrying {
                    Button("Retry Processing", systemImage: "arrow.clockwise") {
                        retryProcessing()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            if model.mode == .processed, !model.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Highlights", systemImage: "sparkles")
                        .font(.headline)
                    ForEach(Array(model.bullets.prefix(8).enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                            Text(bullet).textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            List(model.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    if model.mode == .raw {
                        Button { toggleSelection(row.utteranceIDs) } label: {
                            Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.isSelected ? "Deselect transcript turn" : "Select transcript turn")
                    }
                    Button(row.timestamp) { seek(row.startMilliseconds) }
                        .buttonStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Seeks the local recording to this transcript turn.")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.speakerName).font(.caption.bold())
                            if model.mode == .raw {
                                Text(row.provenance.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(row.text).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 5)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .contain)
                .accessibilityLabel((row.isSelected ? "Selected, " : "") + row.accessibilityLabel)
            }
            .listStyle(.plain)
        }
    }
}

private struct ImprovementPromptPresentation: Identifiable {
    let id = UUID()
    let prompt: String
}

private struct MeetingImprovementPromptSheet: View {
    let prompt: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Improvement Prompt").font(.title2.bold())
            Text("Built from the specific quality signals detected in this call. It contains no transcript text.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(prompt)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("c", modifiers: [.command])
            }
            if copied {
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}

private extension View {
    func statusCapsule() -> some View {
        self
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
}
