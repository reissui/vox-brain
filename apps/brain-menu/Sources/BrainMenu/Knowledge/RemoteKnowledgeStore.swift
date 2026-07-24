import Foundation
import Observation

protocol RemoteKnowledgeAPI: Sendable {
    var pairedInstance: BrainInstanceMetadata? { get }

    func listKnowledge(limit: Int?) async throws -> BrainKnowledgeDocumentsResponse
    func searchKnowledge(query: String, limit: Int?) async throws -> BrainKnowledgeSearchResponse
    func knowledgeDocument(path: String) async throws -> BrainKnowledgeDocument
}

extension BrainAPIClient: RemoteKnowledgeAPI {}

enum RemoteKnowledgeError: Error, Equatable, LocalizedError, Sendable {
    case readAuthorizationRequired
    case originUnavailable
    case staleResult(path: String)
    case notFound(path: String)
    case revokedDevice
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .readAuthorizationRequired:
            "Pair this Mac with read access before searching knowledge."
        case .originUnavailable:
            "The paired Brain origin is unavailable."
        case .staleResult:
            "This search result is stale. Search again to find the current note."
        case .notFound:
            "That note was not found in the Brain vault."
        case .revokedDevice:
            "This device's Brain access was revoked. Pair it again to continue."
        case .invalidResponse:
            "Brain returned an invalid knowledge response."
        case .requestFailed(let message):
            message
        }
    }

    var title: String {
        switch self {
        case .readAuthorizationRequired:
            "Read access required"
        case .originUnavailable:
            "Brain unavailable"
        case .staleResult:
            "Result changed"
        case .notFound:
            "Note not found"
        case .revokedDevice:
            "Device revoked"
        case .invalidResponse, .requestFailed:
            "Knowledge unavailable"
        }
    }
}

@MainActor
@Observable
final class RemoteKnowledgeStore {
    static let defaultDebounce: Duration = .milliseconds(300)
    static let defaultSearchLimit = 30
    static let authorizedAreas: Set<String> = [
        "maps", "notes", "sources", "projects", "people", "me", "daily", "inbox",
    ]
    static let privateAreas: Set<String> = ["me", "daily", "projects", "inbox"]

    private(set) var query = ""
    private(set) var results: [KnowledgeDocument] = []
    private(set) var selectedPath: String?
    private(set) var selectedDocument: KnowledgeDocument?
    private(set) var searchError: RemoteKnowledgeError?
    private(set) var documentError: RemoteKnowledgeError?
    private(set) var isSearching = false
    private(set) var isLoadingDocument = false

    @ObservationIgnored private var api: (any RemoteKnowledgeAPI)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let searchLimit: Int
    @ObservationIgnored private let maximumSearchCacheEntries: Int
    @ObservationIgnored private let maximumDocumentCacheEntries: Int
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchCache: [String: [KnowledgeDocument]] = [:]
    @ObservationIgnored private var searchCacheOrder: [String] = []
    @ObservationIgnored private var documentCache: [String: KnowledgeDocument] = [:]
    @ObservationIgnored private var documentCacheOrder: [String] = []
    @ObservationIgnored private var knownResultPaths: Set<String> = []

    var cachedSearchCount: Int { searchCache.count }
    var cachedDocumentCount: Int { documentCache.count }

    init(
        api: (any RemoteKnowledgeAPI)? = BrainRuntime.knowledgeClient(),
        debounce: Duration = RemoteKnowledgeStore.defaultDebounce,
        searchLimit: Int = RemoteKnowledgeStore.defaultSearchLimit,
        maximumSearchCacheEntries: Int = 8,
        maximumDocumentCacheEntries: Int = 16,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.api = api
        self.debounce = debounce
        self.searchLimit = min(max(searchLimit, 1), 50)
        self.maximumSearchCacheEntries = max(maximumSearchCacheEntries, 1)
        self.maximumDocumentCacheEntries = max(maximumDocumentCacheEntries, 1)
        self.sleep = sleep
    }

    /// Schedules a remote-only search. A newer query cancels the previous wait
    /// and response, so an older response can never replace newer results.
    func search(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        searchTask?.cancel()
        searchTask = nil
        searchError = nil

        guard !trimmed.isEmpty else {
            isSearching = false
            results = []
            return
        }

        do {
            try requireReadAuthorization()
        } catch let error as RemoteKnowledgeError {
            results = []
            isSearching = false
            searchError = error
            return
        } catch {
            results = []
            isSearching = false
            searchError = .invalidResponse
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(self.debounce)
                try Task.checkCancellation()
                let documents = try await self.results(for: trimmed)
                try Task.checkCancellation()
                guard self.query == trimmed else { return }
                self.results = documents
                self.knownResultPaths.formUnion(documents.map(\.relativePath))
                self.searchError = nil
                self.isSearching = false
                if let selectedPath = self.selectedPath,
                   !documents.contains(where: { $0.relativePath == selectedPath }) {
                    self.selectedPath = nil
                    self.selectedDocument = nil
                    self.documentError = nil
                }
            } catch is CancellationError {
                if self.query == trimmed {
                    self.isSearching = false
                }
            } catch {
                guard self.query == trimmed else { return }
                let mapped = self.map(error)
                self.results = []
                self.searchError = mapped
                self.isSearching = false
                if mapped == .revokedDevice {
                    self.clearRevokedReadState()
                }
            }
        }
    }

    /// Test and coordination hook that waits only for the currently scheduled
    /// debounced request. It does not start a request itself.
    func waitForPendingSearch() async {
        await searchTask?.value
    }

    /// Loads a bounded live index from the paired Agent. No document bodies or
    /// local filesystem paths are cached, and a search started while the list
    /// is in flight always wins.
    func refresh() async {
        searchTask?.cancel()
        searchTask = nil
        query = ""
        searchError = nil
        isSearching = true
        defer { isSearching = false }

        do {
            try requireReadAuthorization()
            guard let api else { throw RemoteKnowledgeError.readAuthorizationRequired }
            let response = try await api.listKnowledge(limit: searchLimit)
            guard query.isEmpty else { return }
            let documents = Self.listedDocuments(response.documents)
            results = documents
            knownResultPaths.formUnion(documents.map(\.relativePath))
            if let selectedPath,
               !documents.contains(where: { $0.relativePath == selectedPath }) {
                self.selectedPath = nil
                selectedDocument = nil
                documentError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard query.isEmpty else { return }
            let mapped = map(error)
            results = []
            searchError = mapped
            if mapped == .revokedDevice { clearRevokedReadState() }
        }
    }

    @discardableResult
    func select(path: String) async -> KnowledgeDocument? {
        let wasSearchResult = knownResultPaths.contains(path)
        selectedPath = path
        selectedDocument = nil
        documentError = nil
        isLoadingDocument = true
        defer { isLoadingDocument = false }

        do {
            let document = try await document(at: path, staleIfMissing: wasSearchResult)
            guard selectedPath == path else { return nil }
            selectedDocument = document
            return document
        } catch is CancellationError {
            return nil
        } catch {
            guard selectedPath == path else { return nil }
            let mapped = map(error, path: path, staleIfMissing: wasSearchResult)
            selectedDocument = nil
            documentError = mapped
            if mapped == .revokedDevice {
                clearRevokedReadState()
            }
            return nil
        }
    }

    @discardableResult
    func followWikilink(
        _ rawLink: String,
        from sourcePath: String? = nil
    ) async -> KnowledgeDocument? {
        do {
            let target = Self.wikilinkTarget(rawLink)
            guard !target.isEmpty else { throw RemoteKnowledgeError.notFound(path: rawLink) }

            if let exactPath = Self.directDocumentPath(for: target, from: sourcePath) {
                return await select(path: exactPath)
            }

            let matches = try await results(for: target)
            guard let match = Self.bestWikilinkMatch(target: target, in: matches) else {
                throw RemoteKnowledgeError.notFound(path: target)
            }
            knownResultPaths.insert(match.relativePath)
            return await select(path: match.relativePath)
        } catch is CancellationError {
            return nil
        } catch {
            let mapped = map(error)
            documentError = mapped
            if mapped == .revokedDevice {
                clearRevokedReadState()
            }
            return nil
        }
    }

    @discardableResult
    func openNavigationURL(_ url: URL) async -> KnowledgeDocument? {
        if let path = Self.path(fromNavigationURL: url) {
            return await select(path: path)
        }
        guard let link = Self.wikilink(fromNavigationURL: url) else { return nil }
        return await followWikilink(link.target, from: link.sourcePath)
    }

    func renderedMarkdown(for document: KnowledgeDocument) -> String {
        let markdown = Self.removingLocalNavigation(from: document.readingBody)
        guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#) else {
            return markdown
        }

        let mutable = NSMutableString(string: markdown)
        let matches = expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: mutable.length)
        )
        for match in matches.reversed() where match.numberOfRanges == 2 {
            let contents = mutable.substring(with: match.range(at: 1))
            let pieces = contents.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = pieces.count == 2 ? String(pieces[1]) : target
            let replacement: String
            if let url = Self.wikilinkURL(target: target, sourcePath: document.relativePath) {
                replacement = "[\(Self.escapedMarkdownLabel(label))](\(url.absoluteString))"
            } else {
                replacement = Self.escapedMarkdownText(label)
            }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    func attributedBody(for document: KnowledgeDocument) -> AttributedString {
        let markdown = renderedMarkdown(for: document)
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(document.readingBody)
    }

    func clearCache() {
        searchCache.removeAll(keepingCapacity: false)
        searchCacheOrder.removeAll(keepingCapacity: false)
        documentCache.removeAll(keepingCapacity: false)
        documentCacheOrder.removeAll(keepingCapacity: false)
        knownResultPaths.removeAll(keepingCapacity: false)
    }

    /// Called when pairing is disconnected. Cached private text is discarded
    /// immediately and no future request can reuse the disconnected API.
    func disconnect() {
        searchTask?.cancel()
        searchTask = nil
        api = nil
        resetAndClear()
        searchError = .readAuthorizationRequired
    }

    /// In-memory data vanishes with the process; this explicit hook also clears
    /// it as soon as the scene is torn down or moves to the background.
    func terminate() {
        searchTask?.cancel()
        searchTask = nil
        resetAndClear()
    }

    static func navigationURL(forPath path: String) -> URL? {
        guard isValidRelativePath(path) else { return nil }
        var components = URLComponents()
        components.scheme = "brain-document"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    static func path(fromNavigationURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "brain-document", url.host == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
              isValidRelativePath(path)
        else { return nil }
        return path
    }

    private func resetAndClear() {
        query = ""
        results = []
        selectedPath = nil
        selectedDocument = nil
        searchError = nil
        documentError = nil
        isSearching = false
        isLoadingDocument = false
        clearCache()
    }

    private func clearRevokedReadState() {
        searchTask?.cancel()
        searchTask = nil
        results = []
        selectedPath = nil
        selectedDocument = nil
        isSearching = false
        isLoadingDocument = false
        clearCache()
    }

    private func requireReadAuthorization() throws {
        guard let metadata = api?.pairedInstance,
              metadata.scopes.contains(.read) else {
            throw RemoteKnowledgeError.readAuthorizationRequired
        }
    }

    private func results(for query: String) async throws -> [KnowledgeDocument] {
        try requireReadAuthorization()
        let key = Self.normalized(query)
        if let cached = searchCache[key] {
            touchSearchCache(key)
            return cached
        }
        guard let api else { throw RemoteKnowledgeError.readAuthorizationRequired }
        let response = try await api.searchKnowledge(query: query, limit: searchLimit)
        guard Self.normalized(response.query) == key else {
            throw RemoteKnowledgeError.invalidResponse
        }

        var seen: Set<String> = []
        let documents = response.results.compactMap { result -> KnowledgeDocument? in
            guard Self.isValidRelativePath(result.path), seen.insert(result.path).inserted else {
                return nil
            }
            let area = String(result.path.split(separator: "/", maxSplits: 1)[0])
            let fallback = (result.path as NSString).lastPathComponent
                .replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            let title = Self.boundedText(
                result.title.trimmingCharacters(in: .whitespacesAndNewlines),
                fallback: fallback,
                limit: KnowledgeDocument.maximumTitleCharacters
            )
            let snippet = Self.boundedText(
                Self.collapsedWhitespace(result.snippet),
                fallback: "",
                limit: KnowledgeDocument.maximumSnippetCharacters
            )
            return KnowledgeDocument(
                remoteTitle: title,
                area: area,
                relativePath: result.path,
                snippet: snippet
            )
        }.sorted(by: Self.documentSort)

        cacheSearch(documents, for: key)
        return documents
    }

    private static func listedDocuments(
        _ items: [BrainKnowledgeListItem]
    ) -> [KnowledgeDocument] {
        var seen: Set<String> = []
        return items.compactMap { item -> KnowledgeDocument? in
            guard isValidRelativePath(item.path), seen.insert(item.path).inserted else {
                return nil
            }
            let area = String(item.path.split(separator: "/", maxSplits: 1)[0])
            let fallback = (item.path as NSString).lastPathComponent
                .replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            return KnowledgeDocument(
                remoteTitle: boundedText(
                    item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    fallback: fallback,
                    limit: KnowledgeDocument.maximumTitleCharacters
                ),
                area: area,
                relativePath: item.path,
                snippet: ""
            )
        }.sorted(by: documentSort)
    }

    private func document(at path: String, staleIfMissing: Bool) async throws -> KnowledgeDocument {
        try requireReadAuthorization()
        guard Self.isValidRelativePath(path) else {
            throw RemoteKnowledgeError.notFound(path: path)
        }
        if let cached = documentCache[path] {
            touchDocumentCache(path)
            return cached
        }
        guard let api else { throw RemoteKnowledgeError.readAuthorizationRequired }
        do {
            let response = try await api.knowledgeDocument(path: path)
            guard response.path == path, Self.isValidRelativePath(response.path) else {
                throw RemoteKnowledgeError.staleResult(path: path)
            }
            let area = String(path.split(separator: "/", maxSplits: 1)[0])
            let fallback = (path as NSString).lastPathComponent
                .replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
            let matchingResult = results.first(where: { $0.relativePath == path })
                ?? searchCache.values.lazy.flatMap({ $0 }).first(where: { $0.relativePath == path })
            let title = Self.boundedText(
                response.title.trimmingCharacters(in: .whitespacesAndNewlines),
                fallback: fallback,
                limit: KnowledgeDocument.maximumTitleCharacters
            )
            let document = KnowledgeDocument(
                remoteTitle: title,
                area: area,
                relativePath: path,
                snippet: matchingResult?.snippet ?? "",
                body: response.content
            )
            cacheDocument(document)
            return document
        } catch {
            throw map(error, path: path, staleIfMissing: staleIfMissing)
        }
    }

    private func map(
        _ error: Error,
        path: String? = nil,
        staleIfMissing: Bool = false
    ) -> RemoteKnowledgeError {
        if let remote = error as? RemoteKnowledgeError { return remote }
        guard let apiError = error as? BrainAPIError else {
            return .requestFailed(error.localizedDescription)
        }
        switch apiError {
        case .transport, .timedOut:
            return .originUnavailable
        case .notPaired:
            return .readAuthorizationRequired
        case .credentialUnavailable:
            return .revokedDevice
        case .http(let status, let code, _, _):
            if status == 401 || status == 403
                || ["device_revoked", "revoked_device", "unauthorized_device"].contains(code) {
                return .revokedDevice
            }
            if status == 404 || code == "document_not_found" {
                let wanted = path ?? ""
                return staleIfMissing ? .staleResult(path: wanted) : .notFound(path: wanted)
            }
            return .requestFailed(apiError.localizedDescription)
        case .invalidResponse:
            return .invalidResponse
        case .invalidBaseURL, .invalidRequest:
            return .invalidResponse
        }
    }

    private func cacheSearch(_ documents: [KnowledgeDocument], for key: String) {
        searchCache[key] = documents
        touchSearchCache(key)
        while searchCacheOrder.count > maximumSearchCacheEntries {
            searchCache.removeValue(forKey: searchCacheOrder.removeFirst())
        }
    }

    private func touchSearchCache(_ key: String) {
        searchCacheOrder.removeAll { $0 == key }
        searchCacheOrder.append(key)
    }

    private func cacheDocument(_ document: KnowledgeDocument) {
        documentCache[document.relativePath] = document
        touchDocumentCache(document.relativePath)
        while documentCacheOrder.count > maximumDocumentCacheEntries {
            documentCache.removeValue(forKey: documentCacheOrder.removeFirst())
        }
    }

    private func touchDocumentCache(_ path: String) {
        documentCacheOrder.removeAll { $0 == path }
        documentCacheOrder.append(path)
    }

    private static func wikilinkURL(target: String, sourcePath: String?) -> URL? {
        let target = wikilinkTarget(target)
        guard !target.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "brain-wikilink"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        if let sourcePath { components.queryItems?.append(URLQueryItem(name: "source", value: sourcePath)) }
        return components.url
    }

    private static func wikilink(fromNavigationURL url: URL) -> (target: String, sourcePath: String?)? {
        guard url.scheme?.lowercased() == "brain-wikilink", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = items.first(where: { $0.name == "target" })?.value,
              !wikilinkTarget(target).isEmpty
        else { return nil }
        return (target, items.first(where: { $0.name == "source" })?.value)
    }

    private static func wikilinkTarget(_ link: String) -> String {
        let raw = link.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? link
        return raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .split(separator: "^", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func directDocumentPath(for target: String, from sourcePath: String?) -> String? {
        var candidate = target
        if target.hasPrefix("./") || target.hasPrefix("../") {
            guard let sourcePath else { return nil }
            let directory = (sourcePath as NSString).deletingLastPathComponent
            candidate = ((directory as NSString).appendingPathComponent(target) as NSString).standardizingPath
        }
        guard candidate.contains("/") || candidate.lowercased().hasSuffix(".md") else { return nil }
        if !candidate.lowercased().hasSuffix(".md") { candidate += ".md" }
        return isValidRelativePath(candidate) ? candidate : nil
    }

    private static func bestWikilinkMatch(
        target: String,
        in documents: [KnowledgeDocument]
    ) -> KnowledgeDocument? {
        let wanted = normalizedPath(target)
        let wantedWithoutExtension = removingMarkdownExtension(from: wanted)
        let best = documents.min { lhs, rhs in
            let leftRank = wikilinkRank(lhs, wanted: wanted, withoutExtension: wantedWithoutExtension)
            let rightRank = wikilinkRank(rhs, wanted: wanted, withoutExtension: wantedWithoutExtension)
            return leftRank == rightRank ? documentSort(lhs, rhs) : leftRank < rightRank
        }
        guard let best,
              wikilinkRank(best, wanted: wanted, withoutExtension: wantedWithoutExtension) < 3 else {
            return nil
        }
        return best
    }

    private static func wikilinkRank(
        _ document: KnowledgeDocument,
        wanted: String,
        withoutExtension: String
    ) -> Int {
        let path = normalizedPath(document.relativePath)
        let pathWithoutExtension = removingMarkdownExtension(from: path)
        let filename = removingMarkdownExtension(
            from: normalizedPath((document.relativePath as NSString).lastPathComponent)
        )
        let title = normalizedPath(document.title)
        if path == wanted || pathWithoutExtension == withoutExtension { return 0 }
        if filename == withoutExtension { return 1 }
        if title == withoutExtension { return 2 }
        return 3
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, authorizedAreas.contains(String(parts[0])),
              path.lowercased().hasSuffix(".md") else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    private static func boundedText(_ value: String, fallback: String, limit: Int) -> String {
        let chosen = value.isEmpty ? fallback : value
        guard chosen.count > limit else { return chosen }
        guard limit > 1 else { return String(chosen.prefix(limit)) }
        return String(chosen.prefix(limit - 1)) + "…"
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func documentSort(_ lhs: KnowledgeDocument, _ rhs: KnowledgeDocument) -> Bool {
        let left = normalizedPath(lhs.relativePath)
        let right = normalizedPath(rhs.relativePath)
        return left == right ? lhs.relativePath < rhs.relativePath : left < right
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalizedPath(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private static func removingMarkdownExtension(from value: String) -> String {
        value.hasSuffix(".md") ? String(value.dropLast(3)) : value
    }

    private static func escapedMarkdownLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapedMarkdownText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func removingLocalNavigation(from markdown: String) -> String {
        let linkedPattern = #"\[([^\]\n]+)\]\(\s*(?:file|finder|obsidian):[^)\n]*\)"#
        let automaticPattern = #"<(?:file|finder|obsidian):[^>\n]+>"#
        let mutable = NSMutableString(string: markdown)

        if let expression = try? NSRegularExpression(
            pattern: linkedPattern,
            options: [.caseInsensitive]
        ) {
            let matches = expression.matches(
                in: mutable as String,
                range: NSRange(location: 0, length: mutable.length)
            )
            for match in matches.reversed() {
                let label = match.numberOfRanges > 1
                    ? mutable.substring(with: match.range(at: 1))
                    : "Local link"
                mutable.replaceCharacters(in: match.range, with: escapedMarkdownText(label))
            }
        }

        if let expression = try? NSRegularExpression(
            pattern: automaticPattern,
            options: [.caseInsensitive]
        ) {
            let matches = expression.matches(
                in: mutable as String,
                range: NSRange(location: 0, length: mutable.length)
            )
            for match in matches.reversed() {
                mutable.replaceCharacters(in: match.range, with: "Local link")
            }
        }
        return mutable as String
    }

}
