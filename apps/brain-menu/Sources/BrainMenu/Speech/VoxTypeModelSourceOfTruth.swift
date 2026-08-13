import Foundation

struct VoxTypeModelAttestation: Codable, Equatable, Sendable {
    let requestedSelection: SpeechEngineSelection
    let effectiveSelection: SpeechEngineSelection
    let verifiedAt: Date
    let voxTypeVersion: VoxTypeVersion
}

enum VoxTypeModelAttestationError: Error, Equatable, LocalizedError, Sendable {
    case noSelection
    case unavailable(VoxTypeUnavailableReason)
    case daemonNotRunning
    case missingReportedModel
    case unknownReportedModel(String)
    case modelMismatch(requested: String, effective: String)
    case versionUnavailable

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "Choose an installed speech model in Speech Settings, then try again."
        case .unavailable, .daemonNotRunning:
            "VoxType is not ready. Start VoxType, refresh Speech Settings, then try again."
        case .missingReportedModel:
            "VoxType did not report an active model. Open Speech Settings and activate a model."
        case .unknownReportedModel(let model):
            "VoxType reported unsupported model \(model). Choose a Brain catalog model in Speech Settings."
        case .modelMismatch(let requested, let effective):
            "VoxType is using \(effective), not \(requested). Re-activate \(requested) in Speech Settings."
        case .versionUnavailable:
            "Brain could not verify the VoxType version. Restart VoxType, then try again."
        }
    }
}

@MainActor
protocol VoxTypeModelAttesting: Sendable {
    func attestCurrentSelection() async throws -> VoxTypeModelAttestation
}

/// Owns the single catalog-bound VoxType selection. Workflow-specific keys are
/// read only during the first migration and are never written again.
@MainActor
final class VoxTypeModelSourceOfTruth: VoxTypeModelAttesting {
    static let namespace = "brain.speech.global"

    private let persistence: any SpeechSelectionPersisting
    private let namespace: String
    private let legacySelections: SpeechSelectionStore
    private let activator: (any VoxTypeModelApplying)?
    private let voxType: (any VoxTypeControlling)?
    private let now: @Sendable () -> Date

    init(
        persistence: any SpeechSelectionPersisting = UserDefaults.standard,
        namespace: String = VoxTypeModelSourceOfTruth.namespace,
        legacySelections: SpeechSelectionStore? = nil,
        activator: (any VoxTypeModelApplying)? = nil,
        voxType: (any VoxTypeControlling)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.namespace = namespace
        self.legacySelections = legacySelections ?? SpeechSelectionStore(persistence: persistence)
        self.activator = activator
        self.voxType = voxType
        self.now = now
    }

    var selection: SpeechEngineSelection? {
        guard let engineValue = persistence.string(forKey: "\(namespace).engine"),
              let engine = SpeechEngineID(rawValue: engineValue),
              let modelID = persistence.string(forKey: "\(namespace).model"),
              SpeechEngineCatalog.model(id: modelID)?.engine == engine else {
            return nil
        }
        return SpeechEngineSelection(engine: engine, modelID: modelID)
    }

    /// Adopts the first ready, catalog-valid candidate in the mandated order.
    @discardableResult
    func migrateIfNeeded(
        status: VoxTypeStatus,
        inventory: ModelInventorySnapshot
    ) throws -> SpeechEngineSelection {
        if let selection { return selection }

        let reported = status.snapshot?.model.flatMap(Self.catalogSelection)
        let meeting = legacySelections.selection(for: .meetings).active
        let dictation = legacySelections.selection(for: .dictation).active
        let fallback = Self.catalogSelection(SpeechEngineCatalog.englishDefaultModelID)
        let candidates = [reported, meeting, dictation, fallback].compactMap { $0 }
        guard let adopted = candidates.first(where: {
            inventory.availability(for: $0.modelID) == .ready
        }) else {
            throw VoxTypeModelAttestationError.noSelection
        }
        persist(adopted)
        return adopted
    }

    /// The global selection becomes active only after the lower-level config,
    /// restart, and exact status confirmation transaction succeeds.
    @discardableResult
    func activate(_ requested: SpeechEngineSelection) async throws -> VoxTypeModelAttestation {
        guard Self.catalogSelection(requested.modelID) == requested else {
            throw SpeechSelectionError.engineMismatch
        }
        guard let activator else { throw VoxTypeModelAttestationError.noSelection }
        try await activator.apply(requested)
        let attestation = try await attest(requested)
        persist(requested)
        return attestation
    }

    func attestCurrentSelection() async throws -> VoxTypeModelAttestation {
        guard let selection else { throw VoxTypeModelAttestationError.noSelection }
        return try await attest(selection)
    }

    private func attest(_ requested: SpeechEngineSelection) async throws -> VoxTypeModelAttestation {
        guard let voxType else { throw VoxTypeModelAttestationError.noSelection }
        let status = await voxType.status()
        let snapshot: VoxTypeStatusSnapshot
        switch status {
        case .available(let value): snapshot = value
        case .unavailable(let reason): throw VoxTypeModelAttestationError.unavailable(reason)
        }
        guard snapshot.daemonIsRunning else {
            throw VoxTypeModelAttestationError.daemonNotRunning
        }
        guard let modelID = snapshot.model else {
            throw VoxTypeModelAttestationError.missingReportedModel
        }
        guard let effective = Self.catalogSelection(modelID) else {
            throw VoxTypeModelAttestationError.unknownReportedModel(modelID)
        }
        guard effective == requested else {
            throw VoxTypeModelAttestationError.modelMismatch(
                requested: requested.modelID,
                effective: effective.modelID
            )
        }
        guard let version = try? await voxType.version() else {
            throw VoxTypeModelAttestationError.versionUnavailable
        }
        return VoxTypeModelAttestation(
            requestedSelection: requested,
            effectiveSelection: effective,
            verifiedAt: now(),
            voxTypeVersion: version
        )
    }

    private func persist(_ selection: SpeechEngineSelection) {
        persistence.set(selection.engine.rawValue, forKey: "\(namespace).engine")
        persistence.set(selection.modelID, forKey: "\(namespace).model")
    }

    private static func catalogSelection(_ modelID: String) -> SpeechEngineSelection? {
        guard let model = SpeechEngineCatalog.model(id: modelID) else { return nil }
        return SpeechEngineSelection(engine: model.engine, modelID: model.id)
    }
}
