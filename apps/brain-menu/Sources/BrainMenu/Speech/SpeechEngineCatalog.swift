import Foundation

enum SpeechEngineID: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisper
}

enum SpeechLanguageSupport: String, Codable, Sendable {
    case englishOnly
    case multilingual
}

enum SpeechTimestampSupport: String, Codable, Sendable {
    case none
    case token
    case segment
}

enum SpeechPreviewSupport: String, Codable, Sendable {
    case none

    /// Preview is produced by repeatedly transcribing finalized audio chunks.
    case chunked

    /// The model can also back a documented streaming transcript interface.
    case streaming
}

struct SpeechModelDescriptor: Equatable, Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let engine: SpeechEngineID
    let languageSupport: SpeechLanguageSupport
    let timestampSupport: SpeechTimestampSupport
    let supportsBatch: Bool
    let previewSupport: SpeechPreviewSupport
    let diskSizeMB: Int
    let recommendation: SpeechModelRecommendation?

    var supportsTimestamps: Bool { timestampSupport != .none }
    var supportsPreview: Bool { previewSupport != .none }
    var supportsStreamingPreview: Bool { previewSupport == .streaming }
}

struct SpeechModelRecommendation: Equatable, Codable, Sendable {
    let title: String
    let detail: String
}

struct SpeechEngineDescriptor: Equatable, Identifiable, Sendable {
    let id: SpeechEngineID
    let displayName: String
    let models: [SpeechModelDescriptor]
}

enum SpeechEngineCatalog {
    // Brain embeds VoxType's signed universal macOS release, which is built
    // with Whisper/Metal but not the optional Parakeet feature. Keep the
    // automatic fresh-install choice inside that verified capability set.
    /// The one fresh-install default used by every VoxType-backed workflow.
    static let englishDefaultModelID = "large-v3"
    static let multilingualFallbackModelID = "large-v3-turbo"
    static let modelGuideURL = URL(
        string: "https://voxtype.io/docs/MODEL_SELECTION_GUIDE"
    )!

    static let models: [SpeechModelDescriptor] = [
        SpeechModelDescriptor(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            engine: .parakeet,
            languageSupport: .englishOnly,
            timestampSupport: .token,
            supportsBatch: true,
            previewSupport: .chunked,
            diskSizeMB: 2_600,
            recommendation: nil
        ),
        SpeechModelDescriptor(
            id: "parakeet-unified-en-0.6b",
            displayName: "Parakeet Unified 0.6B",
            engine: .parakeet,
            languageSupport: .englishOnly,
            timestampSupport: .token,
            supportsBatch: true,
            previewSupport: .streaming,
            diskSizeMB: 2_660,
            recommendation: nil
        ),
        SpeechModelDescriptor(
            id: "small.en",
            displayName: "Whisper Small (English)",
            engine: .whisper,
            languageSupport: .englishOnly,
            timestampSupport: .segment,
            supportsBatch: true,
            previewSupport: .chunked,
            diskSizeMB: 466,
            recommendation: nil
        ),
        SpeechModelDescriptor(
            id: "medium.en",
            displayName: "Whisper Medium (English)",
            engine: .whisper,
            languageSupport: .englishOnly,
            timestampSupport: .segment,
            supportsBatch: true,
            previewSupport: .chunked,
            diskSizeMB: 1_500,
            recommendation: nil
        ),
        SpeechModelDescriptor(
            id: "large-v3",
            displayName: "Whisper Large v3",
            engine: .whisper,
            languageSupport: .multilingual,
            timestampSupport: .segment,
            supportsBatch: true,
            previewSupport: .chunked,
            diskSizeMB: 3_100,
            recommendation: SpeechModelRecommendation(
                title: "Recommended",
                detail: "Brain's verified model for dictation, live preview, and final meeting transcription."
            )
        ),
        SpeechModelDescriptor(
            id: "large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisper,
            languageSupport: .multilingual,
            timestampSupport: .segment,
            supportsBatch: true,
            previewSupport: .chunked,
            diskSizeMB: 1_600,
            recommendation: SpeechModelRecommendation(
                title: "Multilingual fallback",
                detail: "Use this fallback when dictating languages beyond English."
            )
        ),
    ]

    static let engines: [SpeechEngineDescriptor] = SpeechEngineID.allCases.map { engine in
        SpeechEngineDescriptor(
            id: engine,
            displayName: engine == .parakeet ? "Parakeet" : "Whisper",
            models: models.filter { $0.engine == engine }
        )
    }

    static func model(id: String) -> SpeechModelDescriptor? {
        models.first { $0.id == id }
    }

    static func models(for engine: SpeechEngineID) -> [SpeechModelDescriptor] {
        models.filter { $0.engine == engine }
    }
}

enum SpeechWorkflow: String, Codable, CaseIterable, Sendable {
    case dictation
    case meetings
}

struct SpeechEngineSelection: Equatable, Codable, Sendable {
    let engine: SpeechEngineID
    let modelID: String
}

struct SpeechWorkflowSelection: Equatable, Sendable {
    let active: SpeechEngineSelection?
    let pending: SpeechEngineSelection?
}

enum SpeechSelectionDecision: Equatable, Sendable {
    case activated(SpeechEngineSelection)
    case pending(SpeechEngineSelection, ModelAvailability)
}

enum SpeechSelectionError: Error, Equatable, Sendable {
    case unknownModel
    case engineMismatch
}

protocol SpeechSelectionPersisting: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SpeechSelectionPersisting {}

/// Persists active and pending choices under workflow-specific keys. A pending
/// choice never replaces a working active model until inventory proves it is
/// ready.
final class SpeechSelectionStore {
    private let persistence: any SpeechSelectionPersisting
    private let namespace: String

    init(
        persistence: any SpeechSelectionPersisting = UserDefaults.standard,
        namespace: String = "brain.speech"
    ) {
        self.persistence = persistence
        self.namespace = namespace
    }

    func selection(for workflow: SpeechWorkflow) -> SpeechWorkflowSelection {
        SpeechWorkflowSelection(
            active: readSelection(kind: "active", workflow: workflow),
            pending: readSelection(kind: "pending", workflow: workflow)
        )
    }

    func activate(_ selection: SpeechEngineSelection, for workflow: SpeechWorkflow) throws {
        try validate(selection)
        writeSelection(selection, kind: "active", workflow: workflow)
        removeSelection(kind: "pending", workflow: workflow)
    }

    func stage(_ selection: SpeechEngineSelection, for workflow: SpeechWorkflow) throws {
        try validate(selection)
        writeSelection(selection, kind: "pending", workflow: workflow)
    }

    func clearPending(for workflow: SpeechWorkflow) {
        removeSelection(kind: "pending", workflow: workflow)
    }

    func effectiveSelection(
        for workflow: SpeechWorkflow,
        inventory: ModelInventorySnapshot
    ) -> SpeechEngineSelection? {
        guard let active = selection(for: workflow).active,
              inventory.availability(for: active.modelID) == .ready else {
            return nil
        }
        return active
    }

    @discardableResult
    func select(
        _ requested: SpeechEngineSelection,
        for workflow: SpeechWorkflow,
        inventory: ModelInventorySnapshot
    ) throws -> SpeechSelectionDecision {
        try validate(requested)

        let availability = inventory.availability(for: requested.modelID)
        if availability == .ready {
            writeSelection(requested, kind: "active", workflow: workflow)
            removeSelection(kind: "pending", workflow: workflow)
            return .activated(requested)
        }

        writeSelection(requested, kind: "pending", workflow: workflow)
        return .pending(requested, availability)
    }

    /// Promotes independently saved pending choices after a successful model
    /// inventory refresh. Choices that are still unavailable stay pending.
    func reconcile(with inventory: ModelInventorySnapshot) {
        for workflow in SpeechWorkflow.allCases {
            guard let pending = selection(for: workflow).pending,
                  inventory.availability(for: pending.modelID) == .ready else {
                continue
            }
            writeSelection(pending, kind: "active", workflow: workflow)
            removeSelection(kind: "pending", workflow: workflow)
        }
    }

    private func readSelection(
        kind: String,
        workflow: SpeechWorkflow
    ) -> SpeechEngineSelection? {
        guard let engineValue = persistence.string(
            forKey: key(kind: kind, component: "engine", workflow: workflow)
        ),
        let engine = SpeechEngineID(rawValue: engineValue),
        let modelID = persistence.string(
            forKey: key(kind: kind, component: "model", workflow: workflow)
        ),
        let model = SpeechEngineCatalog.model(id: modelID),
        model.engine == engine else {
            return nil
        }
        return SpeechEngineSelection(engine: engine, modelID: modelID)
    }

    private func validate(_ requested: SpeechEngineSelection) throws {
        guard let model = SpeechEngineCatalog.model(id: requested.modelID) else {
            throw SpeechSelectionError.unknownModel
        }
        guard model.engine == requested.engine else {
            throw SpeechSelectionError.engineMismatch
        }
    }

    private func writeSelection(
        _ selection: SpeechEngineSelection,
        kind: String,
        workflow: SpeechWorkflow
    ) {
        persistence.set(
            selection.engine.rawValue,
            forKey: key(kind: kind, component: "engine", workflow: workflow)
        )
        persistence.set(
            selection.modelID,
            forKey: key(kind: kind, component: "model", workflow: workflow)
        )
    }

    private func removeSelection(kind: String, workflow: SpeechWorkflow) {
        persistence.removeObject(
            forKey: key(kind: kind, component: "engine", workflow: workflow)
        )
        persistence.removeObject(
            forKey: key(kind: kind, component: "model", workflow: workflow)
        )
    }

    private func key(kind: String, component: String, workflow: SpeechWorkflow) -> String {
        "\(namespace).\(workflow.rawValue).\(kind).\(component)"
    }
}
