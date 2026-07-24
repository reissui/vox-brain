import SwiftUI

struct DictationHistoryView: View {
    let history: DictationHistoryStore
    let speech: SpeechSettingsController
    let onboarding: OnboardingController

    @State private var selectedID: UUID?
    @State private var isConfirmingClear = false
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case errorSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if let errorMessage = history.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Dictation history warning: \(errorMessage)")
                    .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
            }
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No saved dictation", systemImage: "text.bubble")
                } description: {
                    Text("New completed VoxType dictations will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyList
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Dictation")
        .task {
            await speech.refresh()
            await onboarding.refresh()
            accessibilityFocus = .heading
        }
        .onChange(of: history.errorMessage) { _, error in
            if error != nil { accessibilityFocus = .errorSummary }
        }
        .confirmationDialog(
            "Clear all dictation history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                history.clearAll()
                selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved snippets only. It does not change VoxType or its shortcut.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dictation history", systemImage: "waveform.and.mic")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                Spacer()
                Button("Copy") {
                    guard let selectedID else { return }
                    history.copy(id: selectedID)
                }
                .keyboardShortcut("c", modifiers: .command)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
                .accessibilityLabel("Copy selected dictation")
                .accessibilityValue(selectedID == nil ? "Disabled" : "Enabled")

                Button("Clear All", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(history.entries.isEmpty)
                .accessibilityLabel("Clear all dictation history")
                .accessibilityValue(history.entries.isEmpty ? "Disabled" : "Enabled")
                .accessibilityHint("Requires confirmation before deleting saved snippets")
            }

            Text("VoxType owns dictation and output. This history reader only reads VoxType's existing local log after delivery; it never changes VoxType, its configuration, shortcut, or output path.")
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("VoxType shortcut").font(.headline)
                Label(speech.hotkeyState.title, systemImage: speech.hotkeyState.symbolName)
                Text(speech.hotkeyState.detail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyList: some View {
        List(selection: $selectedID) {
            ForEach(history.entries) { entry in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(BrainPresentation.dictationTimestamp(entry.completedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Completed \(BrainPresentation.dictationTimestamp(entry.completedAt))")
                        Spacer()
                        Button("Copy") { history.copy(id: entry.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Copy dictation from \(BrainPresentation.dictationTimestamp(entry.completedAt))")
                        Button("Delete", role: .destructive) {
                            history.delete(id: entry.id)
                            if selectedID == entry.id { selectedID = nil }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete dictation from \(BrainPresentation.dictationTimestamp(entry.completedAt))")
                    }
                    Text(entry.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Dictation: \(entry.text)")
                }
                .padding(.vertical, 5)
                .tag(entry.id)
            }
        }
        .accessibilityLabel("Saved dictation snippets")
    }
}
