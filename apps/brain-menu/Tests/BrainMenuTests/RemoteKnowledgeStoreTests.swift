import Foundation
import Testing
@testable import BrainMenu

@Suite(.serialized)
@MainActor
struct RemoteKnowledgeStoreTests {
    @Test
    func refreshListsBoundedRemoteDocumentsWithoutSearchOrFilesystemAccess() async {
        let api = FakeRemoteKnowledgeAPI(listing: [
            BrainKnowledgeListItem(title: "Second", path: "projects/Second.md"),
            BrainKnowledgeListItem(title: "First", path: "notes/First.md"),
            BrainKnowledgeListItem(title: "Unsafe", path: "../outside.md"),
        ])
        let store = RemoteKnowledgeStore(api: api, debounce: .zero, sleep: { _ in })

        await store.refresh()

        #expect(api.listInvocations == [RemoteKnowledgeStore.defaultSearchLimit])
        #expect(api.searchInvocations.isEmpty)
        #expect(store.results.map(\.relativePath) == ["notes/First.md", "projects/Second.md"])
        #expect(store.results.allSatisfy { $0.snippet.isEmpty && !$0.fileURL.isFileURL })
    }

    @Test
    func debouncesRemoteSearchAndReturnsDeterministicBoundedPrivateResults() async throws {
        let longTitle = String(repeating: "T", count: 220)
        let longSnippet = String(repeating: "private signal ", count: 80)
        let api = FakeRemoteKnowledgeAPI(searches: [
            "first": [result("notes/First.md", title: "First", snippet: "old")],
            "second": [
                result("projects/Plan.md", title: "Plan", snippet: longSnippet),
                result("me/profile.md", title: longTitle, snippet: "profile"),
                result("inbox/Capture.md", title: "Capture", snippet: "inbox"),
                result("daily/2026-07-15.md", title: "Daily", snippet: "daily"),
            ],
        ])
        let store = RemoteKnowledgeStore(api: api, debounce: .milliseconds(80))

        store.search("first")
        try await Task.sleep(for: .milliseconds(20))
        store.search("second")
        await store.waitForPendingSearch()

        #expect(api.searchInvocations == ["second"])
        #expect(store.results.map(\.relativePath) == [
            "daily/2026-07-15.md", "inbox/Capture.md", "me/profile.md", "projects/Plan.md",
        ])
        #expect(store.results.map(\.area) == ["daily", "inbox", "me", "projects"])
        #expect(store.results.allSatisfy { !$0.fileURL.isFileURL })
        #expect(store.results.allSatisfy {
            $0.title.count <= KnowledgeDocument.maximumTitleCharacters
                && $0.snippet.count <= KnowledgeDocument.maximumSnippetCharacters
        })
        #expect(Set(store.results.map(\.area)) == RemoteKnowledgeStore.privateAreas)
    }

    @Test
    func requiresPairedReadScopeBeforePrivateSearchAndNeverTouchesAFilesystem() async {
        let api = FakeRemoteKnowledgeAPI(scopes: [.capture], searches: [
            "private": [result("me/profile.md", title: "Private", snippet: "secret")],
        ])
        let store = RemoteKnowledgeStore(api: api, debounce: .zero, sleep: { _ in })

        store.search("private")
        await store.waitForPendingSearch()

        #expect(store.searchError == .readAuthorizationRequired)
        #expect(api.searchInvocations.isEmpty)
        #expect(store.results.isEmpty)
        #expect(String(describing: type(of: api)).contains("FileManager") == false)
    }

    @Test
    func selectionFetchesExactPathAndWikilinksStayOnRemoteSearchAndDocumentRoutes() async throws {
        let sourceBody = """
        ---
        private: hidden-frontmatter
        ---
        # Source
        Read [[Target Note|the target]], [the web](https://example.com),
        [local file](file:///tmp/vox-brain-example/me/profile.md), and
        [Obsidian](obsidian://open?vault=brain).
        """
        let api = FakeRemoteKnowledgeAPI(
            searches: [
                "source": [result("notes/Source.md", title: "Source", snippet: "Read the target")],
                "Target Note": [
                    result("projects/Target Note.md", title: "Target Note", snippet: "Destination"),
                ],
            ],
            documents: [
                "notes/Source.md": BrainKnowledgeDocument(
                    path: "notes/Source.md", title: "Source", content: sourceBody
                ),
                "projects/Target Note.md": BrainKnowledgeDocument(
                    path: "projects/Target Note.md", title: "Target Note", content: "# Target\nRemote body"
                ),
            ]
        )
        let store = RemoteKnowledgeStore(api: api, debounce: .zero, sleep: { _ in })
        store.search("source")
        await store.waitForPendingSearch()

        let source = try #require(await store.select(path: "notes/Source.md"))
        #expect(api.documentInvocations == ["notes/Source.md"])
        #expect(source.readingBody.contains("hidden-frontmatter") == false)

        let rendered = store.renderedMarkdown(for: source)
        #expect(rendered.contains("brain-wikilink://open"))
        #expect(rendered.contains("https://example.com"))
        #expect(rendered.localizedCaseInsensitiveContains("file:") == false)
        #expect(rendered.localizedCaseInsensitiveContains("obsidian:") == false)

        let target = try #require(await store.followWikilink("[[Target Note|the target]]", from: source.relativePath))
        #expect(target.relativePath == "projects/Target Note.md")
        #expect(api.searchInvocations == ["source", "Target Note"])
        #expect(api.documentInvocations == ["notes/Source.md", "projects/Target Note.md"])

        let navigationURL = try #require(RemoteKnowledgeStore.navigationURL(forPath: target.relativePath))
        #expect(RemoteKnowledgeStore.path(fromNavigationURL: navigationURL) == target.relativePath)
        #expect(RemoteKnowledgeStore.navigationURL(forPath: "../../outside.md") == nil)
    }

    @Test
    func clickingChatCitationsUsesWikilinkResolutionForAliasesAnchorsAndExtensionlessTargets() async throws {
        let api = FakeRemoteKnowledgeAPI(
            searches: [
                "Target Note": [
                    result("projects/Target Note.md", title: "Target Note", snippet: "Project"),
                ],
                "Extensionless": [
                    result("notes/Extensionless.md", title: "Extensionless", snippet: "Note"),
                ],
            ],
            documents: [
                "projects/Target Note.md": BrainKnowledgeDocument(
                    path: "projects/Target Note.md", title: "Target Note", content: "# Target"
                ),
                "notes/Direct.md": BrainKnowledgeDocument(
                    path: "notes/Direct.md", title: "Direct", content: "# Direct"
                ),
                "notes/Extensionless.md": BrainKnowledgeDocument(
                    path: "notes/Extensionless.md", title: "Extensionless", content: "# Extensionless"
                ),
            ]
        )
        let store = RemoteKnowledgeStore(api: api, debounce: .zero, sleep: { _ in })
        let answer = """
        [[Target Note#Decision|the decision]]
        [[projects/Target Note.md#Status]]
        [[notes/Direct]]
        [[Extensionless]]
        """
        let clickedURLs = BrainChatAnswerRenderer.attributedAnswer(answer)
            .runs.compactMap(\.link)
            .filter { $0.scheme == BrainChatAnswerRenderer.knowledgeScheme }

        var openedPaths: [String] = []
        for url in clickedURLs {
            let document = try #require(await store.openNavigationURL(url))
            openedPaths.append(document.relativePath)
        }

        #expect(openedPaths == [
            "projects/Target Note.md",
            "projects/Target Note.md",
            "notes/Direct.md",
            "notes/Extensionless.md",
        ])
        #expect(api.searchInvocations == ["Target Note", "Extensionless"])
        #expect(api.documentInvocations == [
            "projects/Target Note.md", "notes/Direct.md", "notes/Extensionless.md",
        ])
    }

    @Test
    func boundsInMemoryCachesAndClearsThemOnTerminationAndDisconnect() async throws {
        let searches = Dictionary(uniqueKeysWithValues: (1...3).map { number in
            ("q\(number)", [result("notes/\(number).md", title: "Note \(number)", snippet: "q\(number)")])
        })
        let documents = Dictionary(uniqueKeysWithValues: (1...3).map { number in
            let path = "notes/\(number).md"
            return (path, BrainKnowledgeDocument(path: path, title: "Note \(number)", content: "# Note \(number)"))
        })
        let api = FakeRemoteKnowledgeAPI(searches: searches, documents: documents)
        let store = RemoteKnowledgeStore(
            api: api,
            debounce: .zero,
            maximumSearchCacheEntries: 2,
            maximumDocumentCacheEntries: 2,
            sleep: { _ in }
        )

        for number in 1...3 {
            store.search("q\(number)")
            await store.waitForPendingSearch()
            _ = await store.select(path: "notes/\(number).md")
        }
        #expect(store.cachedSearchCount == 2)
        #expect(store.cachedDocumentCount == 2)

        store.search("q2")
        await store.waitForPendingSearch()
        _ = await store.select(path: "notes/2.md")
        #expect(api.searchInvocations.count == 3)
        #expect(api.documentInvocations.count == 3)

        store.terminate()
        #expect(store.cachedSearchCount == 0)
        #expect(store.cachedDocumentCount == 0)
        #expect(store.results.isEmpty)
        #expect(store.selectedDocument == nil)

        store.search("q1")
        await store.waitForPendingSearch()
        #expect(store.cachedSearchCount == 1)
        let callsBeforeDisconnect = api.searchInvocations.count
        store.disconnect()
        store.search("q2")
        await store.waitForPendingSearch()
        #expect(store.cachedSearchCount == 0)
        #expect(store.cachedDocumentCount == 0)
        #expect(store.searchError == .readAuthorizationRequired)
        #expect(api.searchInvocations.count == callsBeforeDisconnect)
    }

    @Test
    func reportsOriginStaleNotFoundAndRevokedAsDistinctStates() async {
        let unavailableAPI = FakeRemoteKnowledgeAPI(
            searchErrors: ["offline": .transport]
        )
        let unavailable = RemoteKnowledgeStore(api: unavailableAPI, debounce: .zero, sleep: { _ in })
        unavailable.search("offline")
        await unavailable.waitForPendingSearch()
        #expect(unavailable.searchError == .originUnavailable)

        let missing = BrainAPIError.http(
            status: 404,
            code: "document_not_found",
            message: "Document not found",
            requestID: nil
        )
        let staleAPI = FakeRemoteKnowledgeAPI(
            searches: ["old": [result("notes/Old.md", title: "Old", snippet: "stale")]],
            documentErrors: ["notes/Old.md": missing]
        )
        let stale = RemoteKnowledgeStore(api: staleAPI, debounce: .zero, sleep: { _ in })
        stale.search("old")
        await stale.waitForPendingSearch()
        _ = await stale.select(path: "notes/Old.md")
        #expect(stale.documentError == .staleResult(path: "notes/Old.md"))

        let missingAPI = FakeRemoteKnowledgeAPI(documentErrors: ["notes/Missing.md": missing])
        let notFound = RemoteKnowledgeStore(api: missingAPI, debounce: .zero, sleep: { _ in })
        _ = await notFound.select(path: "notes/Missing.md")
        #expect(notFound.documentError == .notFound(path: "notes/Missing.md"))

        let revokedAPI = FakeRemoteKnowledgeAPI(
            documentErrors: ["me/profile.md": .credentialUnavailable]
        )
        let revoked = RemoteKnowledgeStore(api: revokedAPI, debounce: .zero, sleep: { _ in })
        _ = await revoked.select(path: "me/profile.md")
        #expect(revoked.documentError == .revokedDevice)
        #expect(revoked.cachedSearchCount == 0)
        #expect(revoked.cachedDocumentCount == 0)
    }

    @Test
    func revokedReadAccessImmediatelyClearsVisibleResultsAndSelectedDocument() async throws {
        let path = "me/profile.md"
        let api = FakeRemoteKnowledgeAPI(
            searches: [
                "visible": [result(path, title: "Profile", snippet: "Private")],
            ],
            documents: [
                path: BrainKnowledgeDocument(path: path, title: "Profile", content: "# Profile"),
            ],
            searchErrors: ["revoked": .credentialUnavailable]
        )
        let store = RemoteKnowledgeStore(api: api, debounce: .zero, sleep: { _ in })
        store.search("visible")
        await store.waitForPendingSearch()
        _ = try #require(await store.select(path: path))
        #expect(!store.results.isEmpty)
        #expect(store.selectedDocument?.relativePath == path)

        store.search("revoked")
        await store.waitForPendingSearch()

        #expect(store.searchError == .revokedDevice)
        #expect(store.results.isEmpty)
        #expect(store.selectedPath == nil)
        #expect(store.selectedDocument == nil)
        #expect(store.cachedSearchCount == 0)
        #expect(store.cachedDocumentCount == 0)
    }
}

private func result(
    _ path: String,
    title: String,
    snippet: String
) -> BrainKnowledgeSearchResult {
    BrainKnowledgeSearchResult(title: title, path: path, snippet: snippet)
}

private final class FakeRemoteKnowledgeAPI: RemoteKnowledgeAPI, @unchecked Sendable {
    let pairedInstance: BrainInstanceMetadata?

    private struct State {
        var listing: [BrainKnowledgeListItem]
        var searches: [String: [BrainKnowledgeSearchResult]]
        var documents: [String: BrainKnowledgeDocument]
        var searchErrors: [String: BrainAPIError]
        var documentErrors: [String: BrainAPIError]
        var listInvocations: [Int?] = []
        var searchInvocations: [String] = []
        var documentInvocations: [String] = []
    }

    private let lock = NSLock()
    private var state: State

    init(
        scopes: [BrainDeviceScope] = [.read],
        listing: [BrainKnowledgeListItem] = [],
        searches: [String: [BrainKnowledgeSearchResult]] = [:],
        documents: [String: BrainKnowledgeDocument] = [:],
        searchErrors: [String: BrainAPIError] = [:],
        documentErrors: [String: BrainAPIError] = [:]
    ) {
        pairedInstance = BrainInstanceMetadata(
            baseURL: URL(string: "https://brain.example.test")!,
            instanceID: "brain-owner",
            deviceID: "device-test",
            deviceName: "Test Mac",
            scopes: scopes
        )
        state = State(
            listing: listing,
            searches: searches,
            documents: documents,
            searchErrors: searchErrors,
            documentErrors: documentErrors
        )
    }

    var searchInvocations: [String] {
        lock.withLock { state.searchInvocations }
    }

    var listInvocations: [Int?] {
        lock.withLock { state.listInvocations }
    }

    var documentInvocations: [String] {
        lock.withLock { state.documentInvocations }
    }

    func listKnowledge(limit: Int?) async throws -> BrainKnowledgeDocumentsResponse {
        lock.withLock {
            state.listInvocations.append(limit)
            return BrainKnowledgeDocumentsResponse(
                documents: Array(state.listing.prefix(limit ?? 50))
            )
        }
    }

    func searchKnowledge(
        query: String,
        limit: Int?
    ) async throws -> BrainKnowledgeSearchResponse {
        let outcome: Result<BrainKnowledgeSearchResponse, BrainAPIError> = lock.withLock {
            state.searchInvocations.append(query)
            if let error = state.searchErrors[query] { return .failure(error) }
            let results = Array(state.searches[query, default: []].prefix(limit ?? 50))
            return .success(BrainKnowledgeSearchResponse(query: query, results: results))
        }
        return try outcome.get()
    }

    func knowledgeDocument(path: String) async throws -> BrainKnowledgeDocument {
        let outcome: Result<BrainKnowledgeDocument, BrainAPIError> = lock.withLock {
            state.documentInvocations.append(path)
            if let error = state.documentErrors[path] { return .failure(error) }
            if let document = state.documents[path] { return .success(document) }
            return .failure(.http(
                status: 404,
                code: "document_not_found",
                message: "Document not found",
                requestID: nil
            ))
        }
        return try outcome.get()
    }
}
