import AppKit
import SwiftUI

struct MCPConnectionInstructions: Equatable, Sendable {
    let endpointURL: URL?

    init(baseURL: URL?) {
        guard let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            endpointURL = nil
            return
        }
        components.path = "/mcp"
        components.query = nil
        components.fragment = nil
        endpointURL = components.url
    }

    var endpoint: String { endpointURL?.absoluteString ?? "Pair Brain.app to show your endpoint" }

    var codexOAuthCommands: [String] {
        guard endpointURL != nil else { return [] }
        return [
            "codex mcp add brain --url \"\(endpoint)\"",
            "codex mcp login brain",
        ]
    }

    var codexBearerCommands: [String] {
        guard endpointURL != nil else { return [] }
        return [
            "export BRAIN_MCP_PASSWORD='<your Brain MCP password>'",
            "codex mcp add brain --url \"\(endpoint)\" --bearer-token-env-var BRAIN_MCP_PASSWORD",
        ]
    }
}

@MainActor
struct MCPConnectionView: View {
    let store: BrainStore
    @State private var copiedEndpoint = false

    private var instructions: MCPConnectionInstructions {
        MCPConnectionInstructions(baseURL: store.pairedInstance?.baseURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                endpointCard
                oauthCard
                headlessCard
                capabilitiesCard
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("MCP")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Connect AI chats to Brain", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.bold())
            Text("Give an AI chat access to save relevant links, notes, files, comments, subjects, and transcripts—and to retrieve matching Brain notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endpointCard: some View {
        GroupBox("Your Brain MCP endpoint") {
            HStack(spacing: 12) {
                Text(instructions.endpoint)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button {
                    guard instructions.endpointURL != nil else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instructions.endpoint, forType: .string)
                    copiedEndpoint = true
                } label: {
                    Label(copiedEndpoint ? "Copied" : "Copy", systemImage: copiedEndpoint ? "checkmark" : "doc.on.doc")
                }
                .disabled(instructions.endpointURL == nil)
                .accessibilityLabel("Copy Brain MCP endpoint")
            }
            .padding(.vertical, 5)
        }
    }

    private var oauthCard: some View {
        connectionCard(
            title: "Recommended: browser sign-in",
            detail: "In Codex, add the endpoint and then sign in. Your browser will ask for the Brain MCP password; the password is not placed in the command or stored by Brain.app.",
            commands: instructions.codexOAuthCommands,
            footer: "For another MCP-capable chat, add a custom remote MCP server with the endpoint above and choose OAuth or browser authentication."
        )
    }

    private var headlessCard: some View {
        connectionCard(
            title: "Alternative: bearer environment variable",
            detail: "For a non-interactive client, keep the password in the client's environment and configure it as the bearer-token variable.",
            commands: instructions.codexBearerCommands,
            footer: "Do not paste the password into chat messages or commit it to a project file."
        )
    }

    private var capabilitiesCard: some View {
        GroupBox("What the connection can do") {
            VStack(alignment: .leading, spacing: 10) {
                capability("brain_add", "Save a link with its comment, title, subject, and source-chat context.")
                capability("brain_note", "Save verbatim text and the context that explains where it belongs.")
                capability("brain_file", "Retain an attached file as an immutable original while its metadata is processed.")
                capability("brain_transcript", "Retain and process a full meeting or conversation transcript.")
                capability("brain_ask", "Retrieve matching Brain notes for the AI to read as evidence.")
                Divider()
                Label("Every MCP write appears in Activity with its delivery state and MCP source.", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func connectionCard(
        title: String,
        detail: String,
        commands: [String],
        footer: String
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func capability(_ tool: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tool)
                .font(.callout.monospaced().weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
