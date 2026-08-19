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
    let processingIsRegenerating: Bool
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
    let regenerateTranscript: () -> Void
    let seek: (Int64) -> Void
    let toggleSelection: ([UUID]) -> Void
    let copyTranscript: () -> Void
    let downloadTranscript: () -> Void
    let revealSavedTranscript: () -> Void
    let createImprovementPrompt: () -> String?

    @State private var promptPresentation: ImprovementPromptPresentation?
    @State private var showsTranscriptDetails = false

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                transcriptVersionPicker
                processingStatus
                Spacer(minLength: 8)
                transcriptActions
            }

            if audioPlayback.meetingID != nil {
                MeetingAudioPlayerView(controller: audioPlayback)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        .labelsHidden()
        .frame(width: 190)
    }

    @ViewBuilder
    private var processingStatus: some View {
        if model.processingIsRegenerating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Processing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.processedIsCurrent {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var transcriptActions: some View {
        HStack(spacing: 6) {
            Button("Regenerate", systemImage: "arrow.clockwise") {
                regenerateTranscript()
            }
            .buttonStyle(.bordered)
            .disabled(model.processingIsRegenerating)
            .help("Regenerate the processed transcript from Raw and audio evidence")

            Button {
                copyTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(model.rows.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .accessibilityLabel("Copy \(model.mode.rawValue) transcript")
            .accessibilityHint("Copies the full \(model.mode.rawValue.lowercased()) transcript with speaker labels.")

            Button {
                downloadTranscript()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(model.rows.isEmpty)
            .accessibilityLabel("Download \(model.mode.rawValue) transcript")
            .help("Download the \(model.mode.rawValue.lowercased()) transcript as Markdown")

            Button {
                revealSavedTranscript()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Reveal saved \(model.mode.rawValue) transcript")
            .help("Reveal the saved \(model.mode.rawValue.lowercased()) Markdown file in Finder")

            Button {
                if let prompt = createImprovementPrompt() {
                    promptPresentation = ImprovementPromptPresentation(prompt: prompt)
                }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canCreateImprovementPrompt)
            .accessibilityLabel("Create \(model.mode.rawValue) improvement prompt")
            .help("Create an improvement prompt for the \(model.mode.rawValue) transcript")

            Button {
                showsTranscriptDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Transcript details")
            .help("Show transcript details")
            .popover(isPresented: $showsTranscriptDetails) {
                transcriptDetails
                    .padding(16)
                    .frame(width: 320)
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var transcriptDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript details").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("Utterances").foregroundStyle(.secondary)
                    Text(String(model.quality.rawUtteranceCount)).monospacedDigit()
                }
                GridRow {
                    Text("Audio previews").foregroundStyle(.secondary)
                    Text(String(model.quality.retainedPreviewCount)).monospacedDigit()
                }
                GridRow {
                    Text("Corrections").foregroundStyle(.secondary)
                    Text(String(model.quality.correctionCount)).monospacedDigit()
                }
                GridRow {
                    Text("Skipped spans").foregroundStyle(.secondary)
                    Text(String(model.quality.skippedFinalCount)).monospacedDigit()
                }
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
            .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var processedUnavailable: some View {
        VStack(spacing: 18) {
            if model.processingIsRegenerating {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: "text.badge.xmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 7) {
                Text(model.processingIsRegenerating ? "Cleaning up transcript" : "Processed transcript isn’t ready")
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
                if !model.processingIsRegenerating {
                    Button("Regenerate", systemImage: "arrow.clockwise") {
                        regenerateTranscript()
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
