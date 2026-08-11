import SwiftUI

/// Recovery surface shown only while the bundled CLI or local vault cannot be
/// initialized. Normal first launch initializes automatically in BrainStore.
struct BrainSetupView: View {
    let store: BrainStore

    @AccessibilityFocusState private var focusedHeading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "internaldrive")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text("Set up Brain on this Mac")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusedHeading)
                Text("Brain stores Markdown in your local vault and uses the bundled Brain CLI.")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Brain setup error: \(errorMessage)")
            }

            Button {
                Task { await store.configureLocal() }
            } label: {
                if store.isConfiguringLocal {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Try Local Setup Again")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isConfiguringLocal)

            Text("Retrying never deletes or migrates existing Brain files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 420)
        .task { focusedHeading = true }
    }
}
