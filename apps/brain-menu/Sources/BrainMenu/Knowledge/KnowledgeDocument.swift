import Foundation

struct KnowledgeDocument: Identifiable, Hashable, Sendable {
    static let maximumTitleCharacters = 160
    static let maximumSnippetCharacters = 320

    /// Retained for the legacy local index. Remote documents use an internal
    /// `brain-document` URL and never expose a filesystem location.
    let fileURL: URL
    let title: String
    let area: String
    let relativePath: String
    let snippet: String
    let body: String
    let modificationDate: Date

    var id: String { relativePath }

    /// Markdown suitable for the reading view. YAML frontmatter remains available
    /// in `body` for local search, but is deliberately omitted here.
    var readingBody: String {
        Self.removingFrontmatter(from: body)
    }

    init(
        fileURL: URL,
        title: String,
        area: String,
        relativePath: String,
        snippet: String = "",
        body: String,
        modificationDate: Date
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.title = title
        self.area = area
        self.relativePath = relativePath
        self.snippet = snippet
        self.body = body
        self.modificationDate = modificationDate
    }

    init(
        remoteTitle: String,
        area: String,
        relativePath: String,
        snippet: String,
        body: String = ""
    ) {
        var components = URLComponents()
        components.scheme = "brain-document"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: relativePath)]

        fileURL = components.url ?? URL(string: "brain-document://open")!
        title = remoteTitle
        self.area = area
        self.relativePath = relativePath
        self.snippet = snippet
        self.body = body
        modificationDate = .distantPast
    }

    static func title(in body: String, fallback: String) -> String {
        var insideFence = false

        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, line.hasPrefix("# ") else { continue }

            let heading = line.dropFirst(2)
                .replacingOccurrences(
                    of: #"\s+#+\s*$"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty {
                return heading
            }
        }

        return fallback
    }

    static func removingFrontmatter(from body: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized == "---" || normalized.hasPrefix("---\n") else {
            return body
        }

        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return body }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
            return body
        }

        lines.removeSubrange(...closingIndex)
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}
