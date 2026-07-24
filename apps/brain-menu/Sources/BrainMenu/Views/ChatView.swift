import AppKit
import SwiftUI

struct ChatView: View {
    @State private var controller: BrainChatController
    @State private var draft = ""
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case primaryField
        case errorSummary
    }

    private let openCitation: (URL) -> Void

    init(
        controller: BrainChatController = BrainChatController(),
        openCitation: @escaping (URL) -> Void = { _ in }
    ) {
        _controller = State(initialValue: controller)
        self.openCitation = openCitation
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            Divider()
            composer
        }
        .navigationTitle("Ask Brain")
        .task {
            await controller.restore()
            accessibilityFocus = .primaryField
        }
        .environment(\.openURL, OpenURLAction { url in
            if BrainChatAnswerRenderer.citationTarget(from: url) != nil {
                openCitation(url)
                return .handled
            }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .discarded
        })
    }

    @ViewBuilder
    private var conversation: some View {
        if controller.turns.isEmpty {
            ContentUnavailableView(
                "Ask the Librarian",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Questions run against your configured Brain vault.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(controller.turns) { turn in
                        turnView(turn)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func turnView(_ turn: BrainChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 70)
                Text(turn.question)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }

            if let answer = controller.attributedAnswer(for: turn) {
                Text(answer)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }

            if let failure = turn.failure {
                VStack(alignment: .leading, spacing: 7) {
                    Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(failure.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.currentTurn?.id == turn.id {
                        Button("Retry question", systemImage: "arrow.clockwise") {
                            Task { await controller.retry() }
                        }
                        .disabled(!controller.canRetry)
                        .accessibilityValue(controller.canRetry ? "Enabled" : "Disabled")
                    }
                }
                .brainAccessibleStatus(
                    .failed,
                    detail: "\(failure.title). \(failure.detail)"
                )
                .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
            } else if let state = turn.jobState {
                jobState(state)
            } else if controller.currentTurn?.id == turn.id, controller.isSubmitting {
                Label("Submitting…", systemImage: "paperplane")
                    .foregroundStyle(.secondary)
                    .brainAccessibleStatus(.waiting, detail: "Submitting question")
            }
        }
    }

    private func jobState(_ state: BrainJobState) -> some View {
        HStack(spacing: 7) {
            if state == .queued || state == .running {
                ProgressView()
                    .controlSize(.small)
            }
            Label(state.rawValue.capitalized, systemImage: symbol(for: state))
                .foregroundStyle(state == .failed || state == .cancelled ? .red : .secondary)
        }
        .font(.caption)
        .brainAccessibleStatus(state.accessibilityState, detail: "Ask job \(state.rawValue)")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 48, maxHeight: 120)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }
                .accessibilityLabel("Question for Brain")
                .accessibilityFocused($accessibilityFocus, equals: .primaryField)

            Button {
                submitDraft()
            } label: {
                Label("Ask", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                controller.isWorking
                    || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(16)
    }

    private func submitDraft() {
        let question = draft
        draft = ""
        Task {
            await controller.submit(question)
            if controller.currentTurn?.failure != nil {
                accessibilityFocus = .errorSummary
            }
        }
    }

    private func symbol(for state: BrainJobState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        }
    }
}

private extension BrainJobState {
    var accessibilityState: BrainWorkflowAccessibilityState {
        switch self {
        case .queued: .queued
        case .running: .waiting
        case .completed: .delivered
        case .failed, .cancelled: .failed
        }
    }
}
