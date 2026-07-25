import SwiftUI

struct OnboardingView: View {
    @State private var controller: OnboardingController
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case errorSummary
    }

    init(controller: OnboardingController = OnboardingController()) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.isComplete ? "Brain is ready" : "Set up speech")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                Text(
                    controller.isComplete
                        ? "Dictation is ready. Meeting transcription can be set up later in Settings."
                        : "Enable Brain's included speech engine and complete each required prerequisite."
                )
                .foregroundStyle(.secondary)
            }

            if let summary = accessibilityErrorSummary {
                Label(summary, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Speech setup error: \(summary)")
                    .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
            }

            List(controller.checks) { check in
                HStack(alignment: .center, spacing: 12) {
                    if check.state == .checking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20)
                    } else {
                        Image(systemName: check.state.symbolName)
                            .foregroundStyle(tint(for: check.state))
                            .frame(width: 20)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(check.id.title)
                                .font(.headline)
                            Text(check.state.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if check.state == .installing {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 280)
                                .accessibilityLabel("Installing \(check.id.title)")
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(check.id.title), \(check.state.label)")
                    .accessibilityValue(check.detail)

                    Spacer()

                    if let action = check.action {
                        Button(action.label) {
                            Task {
                                await controller.perform(action)
                                if accessibilityErrorSummary != nil {
                                    accessibilityFocus = .errorSummary
                                }
                            }
                        }
                        .disabled(!controller.canPerform(action))
                        .accessibilityLabel("\(check.id.title): \(action.label)")
                        .accessibilityValue(
                            controller.canPerform(action) ? "Enabled" : "Disabled"
                        )
                        .accessibilityHint(
                            "May enable Brain's included VoxType, download a speech model, open System Settings, or open the official guide."
                        )
                    }
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)

            HStack {
                if let completionDate = controller.completionDate {
                    Text("Last completed \(completionDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await controller.refresh() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isWorking)
                .keyboardShortcut(.defaultAction)
                .accessibilityValue(
                    controller.isWorking
                        ? "Disabled"
                        : "Enabled"
                )
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 620)
        .task {
            await controller.refresh()
            accessibilityFocus = .heading
        }
    }

    private var accessibilityErrorSummary: String? {
        controller.checks.first(where: {
            $0.state == .actionNeeded || $0.state == .denied
        }).map { "\($0.id.title). \($0.detail)" }
    }

    private func tint(for state: OnboardingCheckState) -> Color {
        switch state {
        case .checking: .secondary
        case .installing: .accentColor
        case .ready: .green
        case .optional: .secondary
        case .actionNeeded: .orange
        case .denied: .red
        case .unavailable: .secondary
        }
    }
}
