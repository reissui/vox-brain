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
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    transcriptVersionPicker
                    Spacer()
                    transcriptActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    transcriptVersionPicker
                    transcriptActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if audioPlayback.meetingID != nil {
                MeetingAudioPlayerView(controller: audioPlayback)
            }

            HStack(spacing: 14) {
                metric("Raw", value: model.quality.rawUtteranceCount)
                metric("Previews preserved", value: model.quality.retainedPreviewCount)
                metric("Finals skipped", value: model.quality.skippedFinalCount)
                metric("Corrections", value: model.quality.correctionCount)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 3) {
                Text("Requested: \(model.model.requested)")
                Text("Effective: \(model.model.effective)")
                Label(
                    model.model.verificationLabel,
                    systemImage: model.model.isVerified
                        ? "checkmark.seal.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.model.isVerified ? .green : .orange)
            }
            .font(.caption)
            .textSelection(.enabled)
        }
        .padding()
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
        .frame(minWidth: 180, idealWidth: 260, maxWidth: 260)
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
        .fixedSize()
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value)).font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var processedUnavailable: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                model.processingMessage ?? "The processed transcript is unavailable or stale.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
            Text("The selected immutable raw transcript remains available in Raw.")
                .foregroundStyle(.secondary)
            Button(model.processingIsRetrying ? "Retrying…" : "Retry Processing", systemImage: "arrow.clockwise") {
                retryProcessing()
            }
            .disabled(model.processingIsRetrying)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            if model.mode == .processed, !model.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Highlights").font(.headline)
                    ForEach(Array(model.bullets.prefix(8).enumerated()), id: \.offset) { _, bullet in
                        Text("• \(bullet)").textSelection(.enabled)
                    }
                }
                .padding()
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel((row.isSelected ? "Selected, " : "") + row.accessibilityLabel)
            }
        }
    }
}

private struct ImprovementPromptPresentation: Identifiable {
    let id = UUID()
    let prompt: String
}

private struct MeetingImprovementPromptSheet: View {
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Improvement Prompt").font(.title2.bold())
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
                }
                .keyboardShortcut("c", modifiers: [.command])
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
    }
}
