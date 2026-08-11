import CryptoKit
import Foundation

enum LocalBrainError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case notInitialized
    case commandFailed(String)
    case invalidOutput
    case invalidCapture
    case documentNotFound
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The local Brain CLI or vault path is invalid."
        case .notInitialized:
            "Set up the local Brain vault before continuing."
        case .commandFailed(let detail):
            detail.isEmpty ? "The local Brain command failed." : detail
        case .invalidOutput:
            "The local Brain command returned an invalid response."
        case .invalidCapture:
            "The capture could not be stored in the local Brain vault."
        case .documentNotFound:
            "That note was not found in the local Brain vault."
        case .invalidRequest:
            "The local Brain request is invalid."
        }
    }
}

private struct LocalBrainProcessResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data

    var outputText: String {
        String(decoding: standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor LocalBrainState {
    static let shared = LocalBrainState()

    private var captures: [String: [String: BrainCaptureStatus]] = [:]
    private var captureOrder: [String: [String]] = [:]
    private var jobs: [String: [String: BrainJobStatus]] = [:]

    func record(_ capture: BrainCaptureStatus, vault: String) {
        var scopedCaptures = captures[vault] ?? [:]
        var scopedOrder = captureOrder[vault] ?? []
        scopedCaptures[capture.id] = capture
        scopedOrder.removeAll { $0 == capture.id }
        scopedOrder.insert(capture.id, at: 0)
        if scopedOrder.count > 100 {
            for identifier in scopedOrder.dropFirst(100) {
                scopedCaptures.removeValue(forKey: identifier)
            }
            scopedOrder = Array(scopedOrder.prefix(100))
        }
        captures[vault] = scopedCaptures
        captureOrder[vault] = scopedOrder
    }

    func capture(id: String, vault: String) -> BrainCaptureStatus? {
        captures[vault]?[id]
    }

    func captureList(vault: String) -> [BrainCaptureStatus] {
        (captureOrder[vault] ?? []).compactMap { captures[vault]?[$0] }
    }

    func record(_ job: BrainJobStatus, vault: String) {
        jobs[vault, default: [:]][job.id] = job
    }

    func job(id: String, vault: String) -> BrainJobStatus? {
        jobs[vault]?[id]
    }
}

struct LocalBrainClient: BrainStatusAPI, BrainCaptureAPI, KnowledgeAPI,
    BrainChatJobAPI, @unchecked Sendable {
    static let markerFilename = ".brain-data-root"
    static let maximumKnowledgeFileBytes = 1_048_576
    static let maximumCaptureObjectBytes = 6 * 1_024 * 1_024
    static let allowedKnowledgeRoots = [
        "maps", "notes", "sources", "projects", "people", "me", "daily", "inbox",
    ]

    let configuration: BrainLocalConfiguration
    private let fileManager: FileManager
    private let librarianModel: String?

    init(
        configuration: BrainLocalConfiguration,
        fileManager: FileManager = .default,
        requireInitializedVault: Bool = true,
        librarianModel: String? = nil
    ) throws {
        let vaultURL = configuration.vaultURL.standardizedFileURL
        let cliURL = configuration.cliURL.standardizedFileURL
        guard vaultURL.path.hasPrefix("/"),
              cliURL.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw LocalBrainError.invalidConfiguration
        }
        if requireInitializedVault {
            let marker = vaultURL.appendingPathComponent(Self.markerFilename)
            guard fileManager.fileExists(atPath: marker.path) else {
                throw LocalBrainError.notInitialized
            }
        }
        self.configuration = BrainLocalConfiguration(
            vaultPath: vaultURL.path,
            cliPath: cliURL.path
        )
        self.fileManager = fileManager
        do {
            self.librarianModel = try AIProviderValidation.validatedModel(librarianModel)
        } catch {
            throw LocalBrainError.invalidConfiguration
        }
    }

    static func initialize(_ configuration: BrainLocalConfiguration) async throws {
        let client = try LocalBrainClient(
            configuration: configuration,
            requireInitializedVault: false
        )
        let result = try await client.run(arguments: ["init-data"])
        guard result.status == 0 else {
            throw LocalBrainError.commandFailed(result.errorText)
        }
        _ = try LocalBrainClient(configuration: configuration)
    }

    func status() async throws -> BrainStatusReport {
        try await decodeCommand(
            BrainStatusReport.self,
            arguments: ["status", "--json"]
        )
    }

    func health() async throws -> BrainHealthReport {
        try await decodeCommand(
            BrainHealthReport.self,
            arguments: ["doctor", "--json"],
            allowNonzero: true
        )
    }

    func healthProbe() async throws -> BrainHealthProbeResponse {
        let marker = configuration.vaultURL.appendingPathComponent(Self.markerFilename)
        return BrainHealthProbeResponse(
            ok: fileManager.fileExists(atPath: marker.path)
                && fileManager.isExecutableFile(atPath: configuration.cliPath)
        )
    }

    func capture(
        _ capture: BrainCaptureRequest,
        idempotencyKey: UUID
    ) async throws -> BrainCaptureReceipt {
        let capturedAt = Date()
        let envelope = try makeEnvelope(
            capture,
            identifier: idempotencyKey,
            capturedAt: capturedAt
        )
        defer {
            if let objectPath = envelope.objectPath {
                try? fileManager.removeItem(atPath: objectPath)
                try? fileManager.removeItem(
                    at: URL(fileURLWithPath: objectPath).deletingLastPathComponent()
                )
            }
        }
        let input = try JSONEncoder().encode(envelope)
        let result = try await run(arguments: ["ingest", "--json"], standardInput: input)
        guard result.status == 0 else {
            throw LocalBrainError.commandFailed(result.errorText)
        }
        let identifier = idempotencyKey.uuidString.lowercased()
        let deliveredAt = Date()
        await LocalBrainState.shared.record(BrainCaptureStatus(
            id: identifier,
            type: envelope.type,
            source: envelope.source,
            state: .delivered,
            retryable: false,
            error: nil,
            createdAt: capturedAt,
            updatedAt: deliveredAt,
            deliveredAt: deliveredAt
        ), vault: configuration.vaultPath)
        return BrainCaptureReceipt(id: identifier, state: "queued")
    }

    func captureStatus(id: String) async throws -> BrainCaptureStatus {
        guard let status = await LocalBrainState.shared.capture(
            id: id,
            vault: configuration.vaultPath
        ) else {
            throw LocalBrainError.invalidCapture
        }
        return status
    }

    func captureList() async throws -> BrainCaptureListResponse {
        BrainCaptureListResponse(
            captures: await LocalBrainState.shared.captureList(
                vault: configuration.vaultPath
            )
        )
    }

    func listKnowledge(limit: Int?) async throws -> BrainKnowledgeDocumentsResponse {
        let boundedLimit = min(max(limit ?? 50, 1), 50)
        let documents = try markdownDocuments().prefix(boundedLimit).map {
            BrainKnowledgeListItem(title: try title(for: $0), path: relativePath(for: $0))
        }
        return BrainKnowledgeDocumentsResponse(documents: Array(documents))
    }

    func searchKnowledge(
        query: String,
        limit: Int?
    ) async throws -> BrainKnowledgeSearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256 else {
            throw LocalBrainError.invalidRequest
        }
        let boundedLimit = min(max(limit ?? 30, 1), 50)
        var results: [BrainKnowledgeSearchResult] = []
        for documentURL in try markdownDocuments() {
            let content = try readDocument(at: documentURL)
            guard let range = content.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else {
                continue
            }
            results.append(BrainKnowledgeSearchResult(
                title: title(in: content, fallback: documentURL.deletingPathExtension().lastPathComponent),
                path: relativePath(for: documentURL),
                snippet: snippet(in: content, around: range)
            ))
            if results.count == boundedLimit { break }
        }
        return BrainKnowledgeSearchResponse(query: query, results: results)
    }

    func knowledgeDocument(path: String) async throws -> BrainKnowledgeDocument {
        let url = try safeDocumentURL(for: path)
        let content = try readDocument(at: url)
        return BrainKnowledgeDocument(
            path: path,
            title: title(in: content, fallback: url.deletingPathExtension().lastPathComponent),
            content: content
        )
    }

    func createJob(kind: BrainJobKind, question: String?) async throws -> BrainJobCreated {
        let identifier = UUID().uuidString.lowercased()
        let createdAt = Self.timestamp()
        let arguments: [String]
        switch kind {
        case .ask:
            guard let question,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalBrainError.invalidRequest
            }
            arguments = ["ask", question]
        case .process:
            guard question == nil else { throw LocalBrainError.invalidRequest }
            arguments = ["process"]
        case .digest:
            guard question == nil else { throw LocalBrainError.invalidRequest }
            arguments = ["digest"]
        }

        let result = try await run(arguments: arguments)
        let finishedAt = Self.timestamp()
        let completed = result.status == 0
        let job = BrainJobStatus(
            id: identifier,
            kind: kind,
            state: completed ? .completed : .failed,
            output: result.outputText.isEmpty ? nil : result.outputText,
            error: completed || result.errorText.isEmpty ? nil : result.errorText,
            detail: completed ? "Completed on this Mac." : "The local Brain CLI failed.",
            truncated: false,
            createdAt: createdAt,
            startedAt: createdAt,
            finishedAt: finishedAt,
            updatedAt: finishedAt
        )
        await LocalBrainState.shared.record(job, vault: configuration.vaultPath)
        return BrainJobCreated(id: identifier, state: job.state)
    }

    func jobStatus(id: String) async throws -> BrainJobStatus {
        guard let job = await LocalBrainState.shared.job(
            id: id,
            vault: configuration.vaultPath
        ) else {
            throw LocalBrainError.invalidOutput
        }
        return job
    }

    private func decodeCommand<Response: Decodable>(
        _ type: Response.Type,
        arguments: [String],
        allowNonzero: Bool = false
    ) async throws -> Response {
        let result = try await run(arguments: arguments)
        guard allowNonzero || result.status == 0 else {
            throw LocalBrainError.commandFailed(result.errorText)
        }
        do {
            return try JSONDecoder.brainDecoder().decode(Response.self, from: result.standardOutput)
        } catch {
            throw LocalBrainError.invalidOutput
        }
    }

    private func run(
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> LocalBrainProcessResult {
        let configuration = configuration
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let input = standardInput.map { _ in Pipe() }
            process.executableURL = configuration.cliURL
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.fileExists(
                atPath: configuration.vaultPath
            )
                ? configuration.vaultURL
                : configuration.cliURL.deletingLastPathComponent().deletingLastPathComponent()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = input

            var environment = ProcessInfo.processInfo.environment
            environment["BRAIN_DATA_ROOT"] = configuration.vaultPath
            environment["BRAIN_SOURCE_ROOT"] = configuration.cliURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            if let librarianModel {
                environment["BRAIN_LIBRARIAN_MODEL"] = librarianModel
            } else {
                environment.removeValue(forKey: "BRAIN_LIBRARIAN_MODEL")
            }
            let commonPaths = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/Applications/ChatGPT.app/Contents/MacOS",
            ]
            environment["PATH"] = (
                commonPaths + [environment["PATH"] ?? ""]
            ).joined(separator: ":")
            process.environment = environment

            do {
                try process.run()
                if let standardInput, let input {
                    input.fileHandleForWriting.write(standardInput)
                    try input.fileHandleForWriting.close()
                }
                let outputRead = Task.detached {
                    try output.fileHandleForReading.readToEnd() ?? Data()
                }
                let errorRead = Task.detached {
                    try error.fileHandleForReading.readToEnd() ?? Data()
                }
                process.waitUntilExit()
                return try await LocalBrainProcessResult(
                    status: process.terminationStatus,
                    standardOutput: outputRead.value,
                    standardError: errorRead.value
                )
            } catch is CancellationError {
                if process.isRunning { process.terminate() }
                throw CancellationError()
            } catch {
                if process.isRunning { process.terminate() }
                throw LocalBrainError.commandFailed(error.localizedDescription)
            }
        }.value
    }

    private func makeEnvelope(
        _ request: BrainCaptureRequest,
        identifier: UUID,
        capturedAt: Date
    ) throws -> LocalIngestEnvelope {
        let type = request.type ?? Self.detectType(for: request.url)
        var object: LocalCaptureObject?
        if let image = request.image {
            object = try temporaryObject(from: image, identifier: identifier)
        }
        return LocalIngestEnvelope(
            id: identifier.uuidString.lowercased(),
            capturedAt: ISO8601DateFormatter().string(from: capturedAt),
            type: type,
            source: request.source ?? "Brain.app",
            storageMode: "local",
            url: request.url,
            text: request.transcript ?? request.text,
            note: request.note,
            title: request.title,
            entity: request.entity,
            objectPath: object?.path,
            objectSHA256: object?.sha256,
            objectMIME: object?.mime,
            objectSize: object?.size,
            objectFilename: object?.filename
        )
    }

    private func temporaryObject(
        from dataURL: String,
        identifier: UUID
    ) throws -> LocalCaptureObject {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ",") else {
            throw LocalBrainError.invalidCapture
        }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let parts = metadata.split(separator: ";")
        guard let mime = parts.first.map(String.init),
              parts.dropFirst().contains("base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              !data.isEmpty,
              data.count <= Self.maximumCaptureObjectBytes else {
            throw LocalBrainError.invalidCapture
        }
        let extensionName: String
        switch mime {
        case "image/jpeg": extensionName = "jpg"
        case "image/png": extensionName = "png"
        case "image/webp": extensionName = "webp"
        default: throw LocalBrainError.invalidCapture
        }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("BrainLocalCapture-\(identifier.uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let filename = "capture.\(extensionName)"
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LocalCaptureObject(
            path: url.path,
            sha256: digest,
            mime: mime,
            size: data.count,
            filename: filename
        )
    }

    private func markdownDocuments() throws -> [URL] {
        var documents: [URL] = []
        for rootName in Self.allowedKnowledgeRoots {
            let root = configuration.vaultURL.appendingPathComponent(rootName, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "md",
                      let values = try? url.resourceValues(
                          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                let resolvedRoot = configuration.vaultURL
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path + "/"
                guard resolved.path.hasPrefix(resolvedRoot) else { continue }
                documents.append(resolved)
            }
        }
        return documents.sorted {
            relativePath(for: $0).localizedCaseInsensitiveCompare(relativePath(for: $1))
                == .orderedAscending
        }
    }

    private func safeDocumentURL(for path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              Self.allowedKnowledgeRoots.contains(String(components[0])),
              path.hasSuffix(".md"),
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw LocalBrainError.invalidRequest
        }
        let candidate = configuration.vaultURL.appendingPathComponent(path).standardizedFileURL
        guard let originalValues = try? candidate.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              originalValues.isRegularFile == true,
              originalValues.isSymbolicLink != true else {
            throw LocalBrainError.documentNotFound
        }
        let resolved = candidate.resolvingSymlinksInPath()
        let rootPath = configuration.vaultURL.standardizedFileURL
            .resolvingSymlinksInPath().path + "/"
        guard resolved.path.hasPrefix(rootPath),
              let values = try? resolved.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LocalBrainError.documentNotFound
        }
        return resolved
    }

    private func readDocument(at url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumKnowledgeFileBytes else {
            throw LocalBrainError.invalidOutput
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func title(for url: URL) throws -> String {
        let content = try readDocument(at: url)
        return title(in: content, fallback: url.deletingPathExtension().lastPathComponent)
    }

    private func title(in content: String, fallback: String) -> String {
        content.split(separator: "\n").lazy
            .first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback
    }

    private func snippet(
        in content: String,
        around range: Range<String.Index>
    ) -> String {
        let lower = content.index(range.lowerBound, offsetBy: -120, limitedBy: content.startIndex)
            ?? content.startIndex
        let upper = content.index(range.upperBound, offsetBy: 180, limitedBy: content.endIndex)
            ?? content.endIndex
        return content[lower..<upper]
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relativePath(for url: URL) -> String {
        String(url.path.dropFirst(configuration.vaultURL.standardizedFileURL.path.count + 1))
    }

    private static func detectType(for url: String?) -> BrainCaptureType {
        guard let url = url?.lowercased() else { return .note }
        if url.contains("youtube.com/") || url.contains("youtu.be/") { return .video }
        if url.contains("x.com/") || url.contains("twitter.com/") { return .tweet }
        return .article
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private struct LocalCaptureObject: Sendable {
    let path: String
    let sha256: String
    let mime: String
    let size: Int
    let filename: String
}

private struct LocalIngestEnvelope: Encodable, Sendable {
    let id: String
    let capturedAt: String
    let type: BrainCaptureType
    let source: String
    let storageMode: String
    let url: String?
    let text: String?
    let note: String?
    let title: String?
    let entity: String?
    let objectPath: String?
    let objectSHA256: String?
    let objectMIME: String?
    let objectSize: Int?
    let objectFilename: String?

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case type
        case source
        case storageMode = "storage_mode"
        case url, text, note, title, entity
        case objectPath = "object_path"
        case objectSHA256 = "object_sha256"
        case objectMIME = "object_mime"
        case objectSize = "object_size"
        case objectFilename = "object_filename"
    }
}
