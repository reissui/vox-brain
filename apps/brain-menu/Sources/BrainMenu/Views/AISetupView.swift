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

            Section("CLI Command") {
                AICommandEditor(
                    command: $controller.command,
                    accessibilityLabel: "Librarian AI CLI command",
                    canSave: controller.canSave,
                    save: controller.save,
                    canTestConnection: controller.canTestConnection,
                    testConnection: controller.testConnection,
                    testState: controller.testState,
                    testDetail: controller.testDetail,
                    selectedModelName: controller.selectedModelName,
                    confirmedModelName: controller.confirmedModelName,
                    commandErrorMessage: controller.commandErrorMessage,
                    savedMessage: controller.savedMessage
                )

                if let errorMessage = controller.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Run Librarian Now") {
                        Task { await controller.runNow() }
                    }
                    .disabled(controller.isWorking)

                    Spacer()
                    if controller.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Librarian AI is working")
                    }
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
