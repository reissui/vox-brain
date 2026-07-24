import Foundation

protocol VoxTypeModelManaging: Sendable {
    func installedModelList() async throws -> String
    func installModel(id: String) async throws
}

extension VoxTypeClient: VoxTypeModelManaging {}

enum ModelAvailability: String, Equatable, Sendable {
    case ready
    case missing
    case incompatible
    case installing
    case unknown
}

struct ModelInventorySnapshot: Equatable, Sendable {
    private let availabilityByModelID: [String: ModelAvailability]

    init(availabilityByModelID: [String: ModelAvailability]) {
        self.availabilityByModelID = Dictionary(
            uniqueKeysWithValues: SpeechEngineCatalog.models.map { model in
                (model.id, availabilityByModelID[model.id] ?? .unknown)
            }
        )
    }

    static let unknown = ModelInventorySnapshot(availabilityByModelID: [:])

    func availability(for modelID: String) -> ModelAvailability {
        guard SpeechEngineCatalog.model(id: modelID) != nil else { return .unknown }
        return availabilityByModelID[modelID] ?? .unknown
    }

    var readyModelIDs: Set<String> {
        Set(availabilityByModelID.compactMap { id, availability in
            availability == .ready ? id : nil
        })
    }

    func replacing(
        _ availability: ModelAvailability,
        for modelID: String
    ) -> ModelInventorySnapshot {
        guard SpeechEngineCatalog.model(id: modelID) != nil else { return self }
        var values = availabilityByModelID
        values[modelID] = availability
        return ModelInventorySnapshot(availabilityByModelID: values)
    }
}

enum ModelInstallProgress: Equatable, Sendable {
    case installing(String)
    case refreshing(String)
    case completed(String, ModelAvailability)
    case failed(String)
    case cancelled(String)
}

enum ModelInventoryError: Error, Equatable, Sendable {
    case unknownModel
    case installationAlreadyInProgress
    case installFailed
}

actor ModelInventory {
    static let maximumLineCount = 512
    static let maximumLineBytes = 512

    private let client: any VoxTypeModelManaging
    private var inventorySnapshot: ModelInventorySnapshot = .unknown
    private var activeInstallationModelID: String?

    init(client: any VoxTypeModelManaging) {
        self.client = client
    }

    func currentSnapshot() -> ModelInventorySnapshot {
        inventorySnapshot
    }

    /// Inventory failures and format changes fail closed. Callers receive an
    /// unknown snapshot rather than a false claim that configured names are
    /// installed.
    @discardableResult
    func refresh() async -> ModelInventorySnapshot {
        do {
            let output = try await client.installedModelList()
            try Task.checkCancellation()
            let refreshed = Self.parse(output)
            inventorySnapshot = refreshed
            return refreshed
        } catch {
            inventorySnapshot = .unknown
            return .unknown
        }
    }

    /// Runs the fixed catalog-only download and then always asks VoxType for a
    /// new inventory. Cancelling the caller cancels the underlying Process task.
    @discardableResult
    func install(
        modelID: String,
        progress: @Sendable (ModelInstallProgress) -> Void = { _ in }
    ) async throws -> ModelInventorySnapshot {
        guard SpeechEngineCatalog.model(id: modelID) != nil else {
            throw ModelInventoryError.unknownModel
        }
        guard activeInstallationModelID == nil else {
            throw ModelInventoryError.installationAlreadyInProgress
        }

        activeInstallationModelID = modelID
        defer { activeInstallationModelID = nil }

        let priorSnapshot = inventorySnapshot
        inventorySnapshot = priorSnapshot.replacing(.installing, for: modelID)
        progress(.installing(modelID))

        do {
            try Task.checkCancellation()
            try await client.installModel(id: modelID)
            try Task.checkCancellation()

            progress(.refreshing(modelID))
            let output = try await client.installedModelList()
            try Task.checkCancellation()
            let refreshed = Self.parse(output)
            inventorySnapshot = refreshed
            progress(.completed(modelID, refreshed.availability(for: modelID)))
            return refreshed
        } catch is CancellationError {
            inventorySnapshot = priorSnapshot
            progress(.cancelled(modelID))
            throw CancellationError()
        } catch {
            inventorySnapshot = priorSnapshot
            progress(.failed(modelID))
            throw ModelInventoryError.installFailed
        }
    }

    static func parse(_ output: String) -> ModelInventorySnapshot {
        guard output.utf8.count <= VoxTypeClient.maximumOutputBytes else {
            return .unknown
        }

        let lines = output.split(
            separator: "\n",
            maxSplits: maximumLineCount,
            omittingEmptySubsequences: false
        )
        guard lines.count <= maximumLineCount,
              lines.allSatisfy({ $0.utf8.count <= maximumLineBytes }) else {
            return .unknown
        }

        var currentEngine: SpeechEngineID?
        var recognizedEngines = Set<SpeechEngineID>()
        var invalidEngines = Set<SpeechEngineID>()
        var parsedAvailability: [String: ModelAvailability] = [:]

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let engine = engineHeader(line) {
                currentEngine = engine
                recognizedEngines.insert(engine)
                continue
            }

            guard let engine = currentEngine else { continue }
            if isKnownDecorationOrMessage(line, for: engine) { continue }

            guard let entry = parseEntry(line) else {
                invalidEngines.insert(engine)
                continue
            }

            // Syntactically valid entries for models outside Brain's fixed
            // catalog are ignored and never retained.
            guard let knownModel = SpeechEngineCatalog.model(id: entry.modelID) else {
                continue
            }

            if knownModel.engine != engine || entry.isIncompatible {
                parsedAvailability[knownModel.id] = .incompatible
            } else {
                parsedAvailability[knownModel.id] = .ready
            }
        }

        guard !recognizedEngines.isEmpty else { return .unknown }

        var result: [String: ModelAvailability] = [:]
        for model in SpeechEngineCatalog.models {
            if parsedAvailability[model.id] == .incompatible {
                result[model.id] = .incompatible
                continue
            }
            guard recognizedEngines.contains(model.engine),
                  !invalidEngines.contains(model.engine) else {
                result[model.id] = .unknown
                continue
            }
            result[model.id] = parsedAvailability[model.id] ?? .missing
        }
        return ModelInventorySnapshot(availabilityByModelID: result)
    }

    private struct ParsedEntry {
        let modelID: String
        let isIncompatible: Bool
    }

    private static func engineHeader(_ line: String) -> SpeechEngineID? {
        switch line {
        case "Installed Whisper Models": .whisper
        case "Installed Parakeet Models": .parakeet
        default: nil
        }
    }

    private static func isKnownDecorationOrMessage(
        _ line: String,
        for engine: SpeechEngineID
    ) -> Bool {
        if line.allSatisfy({ $0 == "=" }) { return true }
        if line.hasPrefix("Run 'voxtype setup model'") { return true }
        if line.hasPrefix("No models directory found:") { return true }
        switch engine {
        case .whisper:
            return line == "No models installed."
        case .parakeet:
            return line == "No Parakeet models installed."
        }
    }

    private static func parseEntry(_ line: String) -> ParsedEntry? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let modelID = String(line[..<separator])
        guard isBoundedModelID(modelID) else { return nil }

        let detail = line[line.index(after: separator)...]
        guard detail.hasPrefix("("),
              let sizeEnd = detail.range(of: " MB) - "),
              sizeEnd.lowerBound > detail.startIndex else {
            return nil
        }

        let sizeStart = detail.index(after: detail.startIndex)
        let size = detail[sizeStart..<sizeEnd.lowerBound]
        let description = detail[sizeEnd.upperBound...]
        guard !size.isEmpty,
              size.allSatisfy({ $0.isNumber || $0 == "." }),
              size.filter({ $0 == "." }).count <= 1,
              Double(size) != nil,
              !description.isEmpty,
              description.utf8.count <= 256 else {
            return nil
        }

        let normalizedDescription = description.lowercased()
        let incompatible = normalizedDescription.contains("[incompatible]")
            || normalizedDescription.contains("not compatible")
        return ParsedEntry(modelID: modelID, isIncompatible: incompatible)
    }

    private static func isBoundedModelID(_ modelID: String) -> Bool {
        guard !modelID.isEmpty, modelID.utf8.count <= 64 else { return false }
        return modelID.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57)
                || $0 == 45
                || $0 == 46
        }
    }
}
