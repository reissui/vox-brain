import AppKit
import SwiftUI

private let brainKnowledgeOpen = Notification.Name("BrainKnowledgeOpen")

struct KnowledgeView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: KnowledgeStore
    @State private var query = ""
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum AccessibilityTarget: Hashable {
        case heading
        case errorSummary
    }

    private let initialPath: String?

    init(
        initialPath: String? = nil,
        store: KnowledgeStore = KnowledgeStore()
    ) {
        self.initialPath = initialPath
        _store = State(initialValue: store)
    }

    var body: some View {
        HSplitView {
            documentList
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 400)

            readingView
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Knowledge")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Brain knowledge")
        .accessibilityLabel("Knowledge browser")
        .onChange(of: query) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await store.refresh() }
            } else {
                store.search(value)
            }
        }
        .task(id: initialPath) {
            if let initialPath {
                _ = await store.select(path: initialPath)
            } else {
                await store.refresh()
            }
            accessibilityFocus = .heading
        }
        .onReceive(NotificationCenter.default.publisher(for: brainKnowledgeOpen)) { notification in
            guard let path = notification.userInfo?["path"] as? String else { return }
            Task { _ = await store.followWikilink(path) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                store.terminate()
            }
        }
        .onDisappear {
            store.terminate()
        }
        .onChange(of: store.searchError) { _, error in
            if error != nil { accessibilityFocus = .errorSummary }
        }
        .onChange(of: store.documentError) { _, error in
            if error != nil { accessibilityFocus = .errorSummary }
        }
        .onChange(of: store.selectedPath) { _, path in
            if path != nil { accessibilityFocus = .heading }
        }
    }

    @ViewBuilder
    private var documentList: some View {
        if store.isSearching && store.results.isEmpty {
            ProgressView("Searching local Brain…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.searchError {
            unavailable(error)
        } else if store.results.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No knowledge yet",
                    systemImage: "books.vertical",
                    description: Text("Documents are read from your local Brain vault.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            List(store.results, selection: selectionBinding) { document in
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(document.area)
                            .fontWeight(.medium)
                        Text(document.relativePath)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !document.snippet.isEmpty {
                        Text(document.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 4)
                .tag(document.relativePath)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(document.title)
                .accessibilityValue("\(document.area). \(document.snippet)")
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var readingView: some View {
        if store.isLoadingDocument {
            ProgressView("Fetching note…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.documentError {
            unavailable(error)
        } else if let document = store.selectedDocument {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title)
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($accessibilityFocus, equals: .heading)
                        HStack(spacing: 5) {
                            Text(document.area)
                                .fontWeight(.medium)
                            Text(document.relativePath)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()

                Divider()

                ScrollView {
                    Text(store.attributedBody(for: document))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                switch url.scheme?.lowercased() {
                case "brain-document", "brain-wikilink":
                    Task { _ = await store.openNavigationURL(url) }
                    return .handled
                case "http", "https":
                    NSWorkspace.shared.open(url)
                    return .handled
                default:
                    // In particular, never hand file:, Finder, or Obsidian URLs
                    // to the host operating system from rendered Markdown.
                    return .discarded
                }
            })
        } else {
            ContentUnavailableView(
                "Select a note",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Markdown is read on demand from your local Brain vault.")
            )
            .accessibilityFocused($accessibilityFocus, equals: .heading)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedPath },
            set: { path in
                guard let path else { return }
                Task { _ = await store.select(path: path) }
            }
        )
    }

    private func unavailable(_ error: KnowledgeError) -> some View {
        ContentUnavailableView(
            error.title,
            systemImage: "exclamationmark.triangle",
            description: Text(error.localizedDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Knowledge error: \(error.title)")
        .accessibilityValue(error.localizedDescription)
        .accessibilityFocused($accessibilityFocus, equals: .errorSummary)
    }
}
