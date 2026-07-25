import SwiftUI

private enum AISetupWorkflow: String, CaseIterable, Identifiable {
    case librarian = "Librarian"
    case meetings = "Meetings"

    var id: Self { self }
}

@MainActor
struct AISetupView: View {
    @Bindable var librarian: LibrarianAIController
    @Bindable var meetings: AISettingsController
    @State private var workflow: AISetupWorkflow = .librarian

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Setup")
                        .font(.title2.weight(.semibold))
                    Text("Configure how Brain organises knowledge and analyses meetings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("AI workflow", selection: $workflow) {
                    ForEach(AISetupWorkflow.allCases) { workflow in
                        Text(workflow.rawValue).tag(workflow)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            switch workflow {
            case .librarian:
                LibrarianAISettingsView(controller: librarian)
            case .meetings:
                AISettingsView(controller: meetings)
            }
        }
        .navigationTitle("AI Setup")
    }
}

@MainActor
private struct LibrarianAISettingsView: View {
    @Bindable var controller: LibrarianAIController

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                        .frame(width: 34, height: 34)
                        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Librarian AI")
                            .font(.title3.weight(.semibold))
                        Text("Processes inbox captures, enriches sources, connects notes, and updates maps, projects, and evidence-backed profiles.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                    Label(controller.state.title, systemImage: controller.state.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColour)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(statusColour.opacity(0.1), in: Capsule())
                }
            }

            Section("Automation") {
                Toggle(
                    "Organise new captures automatically",
                    isOn: $controller.automaticProcessingEnabled
                )

                Text("Brain runs the Librarian shortly after a capture arrives and periodically checks for retained inbox work. The original captured words remain unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local AI") {
                LabeledContent("Provider", value: "Codex CLI")

                LabeledContent {
                    TextField("Provider default", text: $controller.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Optional Librarian Codex model")
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Model")
                        Text("This choice is separate from meeting post-processing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Label(
                    "Uses your existing Codex CLI ChatGPT sign-in. Brain confines persistent writes to your local vault.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Run Librarian Now") {
                        Task { await controller.runNow() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isWorking)

                    Button("Save Settings") {
                        controller.save()
                    }
                    .disabled(controller.isWorking)

                    Spacer()
                    if controller.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Librarian AI is working")
                    }
                }

                if let savedMessage = controller.savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusColour: Color {
        switch controller.state {
        case .idle, .completed: .green
        case .scheduled, .running: .indigo
        case .failed: .red
        }
    }
}
