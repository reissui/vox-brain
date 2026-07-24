import SwiftUI

struct BrainSetupView: View {
    let store: BrainStore

    @AccessibilityFocusState private var focusedHeading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Where should Brain live?")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusedHeading)
                Text("Choose once now. You can switch later without deleting either vault.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                setupCard(
                    mode: .local,
                    symbol: "internaldrive",
                    features: [
                        "Markdown stays on this Mac",
                        "Capture and search work without a server",
                        "Process, digest, and Ask use the bundled local CLI",
                        "Remote integrations and MCP stay off",
                    ]
                ) {
                    Task { await store.configureLocal() }
                }

                setupCard(
                    mode: .remote,
                    symbol: "network",
                    features: [
                        "The canonical vault lives on your remote runner",
                        "This Mac connects through the paired HTTPS gateway",
                        "Optional MCP and server integrations are available",
                        "You provide and operate the runner infrastructure",
                    ]
                ) {
                    store.selectRemote()
                }
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Brain setup error: \(errorMessage)")
            }

            Text("Local-only is the simplest setup and keeps every Brain file under your user account. Remote mode is optional and can be added later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(minWidth: 760, minHeight: 560)
        .task { focusedHeading = true }
    }

    private func setupCard(
        mode: BrainDeploymentMode,
        symbol: String,
        features: [String],
        action: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(mode == .local ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(mode.title)
                        .font(.title2.bold())
                    Text(mode.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                            .font(.callout)
                    }
                }

                Spacer(minLength: 8)

                Button(mode == .local ? "Use This Mac" : "Set Up Remote Brain") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isConfiguringLocal)
                .accessibilityHint(mode.detail)

                if mode == .local, store.isConfiguringLocal {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Creating your local vault…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        }
    }
}
