import Foundation
import Observation
import SwiftUI

protocol SpeechModelInventoryControlling: Sendable {
    func refresh() async -> ModelInventorySnapshot

    func install(
        modelID: String,
        progress: @Sendable (ModelInstallProgress) -> Void
    ) async throws -> ModelInventorySnapshot
}

extension ModelInventory: SpeechModelInventoryControlling {}

enum SpeechHardwareTestResult: Equatable, Sendable {
    case ready(String)
    case failed(String)
}

protocol SpeechSettingsActionHandling: Sendable {
    func testMicrophone() async -> SpeechHardwareTestResult
    func testSystemAudio() async -> SpeechHardwareTestResult
}

struct UnavailableSpeechSettingsActions: SpeechSettingsActionHandling {
    func testMicrophone() async -> SpeechHardwareTestResult {
        .failed("Microphone testing is not available yet.")
    }

    func testSystemAudio() async -> SpeechHardwareTestResult {
        .failed("System audio testing is not available yet.")
    }
}

enum VoxTypeHotkeyPresentation: Equatable, Sendable {
    case checking
    case configured(VoxTypeHotkeyConfiguration)
    case unavailable

    var title: String {
        switch self {
        case .checking: "Checking shortcut"
        case .configured(let hotkey): hotkey.shortcutDescription
        case .unavailable: "Not reported"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Reading VoxType's active shortcut without changing it."
        case .configured:
            "VoxType owns this shortcut. Brain only displays it."
        case .unavailable:
            "VoxType keeps ownership of its shortcut, but Brain could not read it."
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "hourglass"
        case .configured: "keyboard"
        case .unavailable: "questionmark.circle"
        }
    }

    var accessibilityLabel: String {
        "VoxType shortcut: \(title). \(detail)"
    }
}

enum VoxTypeInstallationPresentation: Equatable, Sendable {
    case checking
    case missing
    case installed(VoxTypeVersion)
    case unavailable

    var title: String {
        switch self {
        case .checking: "Checking installation"
        case .missing: "Not installed"
        case .installed: "Installed"
        case .unavailable: "Installation needs attention"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Looking for a standalone VoxType installation or Brain's included copy."
        case .missing:
            "Open Speech Setup to enable the VoxType included with Brain."
        case .installed(let version):
            "VoxType \(version.description)"
        case .unavailable:
            "Brain found VoxType but could not read a compatible version."
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "hourglass"
        case .missing: "xmark.circle"
        case .installed: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        "VoxType installation state: \(title). \(detail)"
    }
}

enum VoxTypeDaemonPresentation: Equatable, Sendable {
    case checking
    case running(VoxTypeRuntimeState)
    case stopped
    case unavailable(VoxTypeUnavailableReason)

    var title: String {
        switch self {
        case .checking: "Checking daemon"
        case .running(let state): "Running — \(state.displayName)"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Waiting for VoxType status."
        case .running:
            "VoxType is running and available for dictation and meeting transcription."
        case .stopped:
            "Start VoxType for dictation and Brain meeting transcription."
        case .unavailable(let reason):
            reason.settingsDetail
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "hourglass"
        case .running: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        "VoxType daemon state: \(title). \(detail)"
    }
}

struct SpeechCapabilityBadge: Equatable, Identifiable, Sendable {
    let title: String
    let accessibilityLabel: String

    var id: String { title }
}

struct SpeechModelSettingsRow: Equatable, Identifiable, Sendable {
    let model: SpeechModelDescriptor
    let availability: ModelAvailability

    var id: String { model.id }

    var stateTitle: String {
        switch availability {
        case .ready: "Ready"
        case .missing: "Not installed"
        case .incompatible: "Incompatible"
        case .installing: "Installing"
        case .unknown: "Availability unknown"
        }
    }

    var stateDetail: String {
        switch availability {
        case .ready:
            "Installed and available for activation."
        case .missing:
            "Install this known model before it can become active."
        case .incompatible:
            "Install the supported build before this model can become active."
        case .installing:
            "VoxType is installing this model."
        case .unknown:
            "Refresh model inventory before activating this model."
        }
    }

    var stateSymbolName: String {
        switch availability {
        case .ready: "checkmark.circle.fill"
        case .missing: "arrow.down.circle"
        case .incompatible: "exclamationmark.triangle.fill"
        case .installing: "arrow.down.circle.dotted"
        case .unknown: "questionmark.circle"
        }
    }

    var accessibilityLabel: String {
        "\(model.displayName) model state: \(stateTitle). \(stateDetail)"
    }

    var canInstall: Bool {
        availability == .missing || availability == .incompatible
    }

    var recommendationTitle: String? { model.recommendation?.title }
    var recommendationDetail: String? { model.recommendation?.detail }

    var capabilities: [SpeechCapabilityBadge] {
        var values = [
            SpeechCapabilityBadge(
                title: model.languageSupport == .multilingual ? "Multilingual" : "English",
                accessibilityLabel: model.languageSupport == .multilingual
                    ? "Supports multiple languages"
                    : "Supports English"
            ),
            SpeechCapabilityBadge(
                title: model.supportsTimestamps ? "Timestamps" : "No timestamps",
                accessibilityLabel: model.supportsTimestamps
                    ? "Supports \(model.timestampSupport.rawValue) timestamps"
                    : "Does not support timestamps"
            ),
        ]
        if model.supportsBatch {
            values.append(SpeechCapabilityBadge(
                title: "Batch",
                accessibilityLabel: "Supports batch transcription"
            ))
        }
        if model.supportsPreview {
            values.append(SpeechCapabilityBadge(
                title: model.supportsStreamingPreview ? "Streaming preview" : "Chunked preview",
                accessibilityLabel: model.supportsStreamingPreview
                    ? "Supports streaming preview"
                    : "Supports chunked preview"
            ))
        }
        values.append(SpeechCapabilityBadge(
            title: model.diskSizeMB.settingsDiskSize,
            accessibilityLabel: "Download size \(model.diskSizeMB.settingsDiskSize)"
        ))
        return values
    }
}

enum SpeechModelApplicationState: Equatable, Sendable {
    case inactive
    case applying(SpeechEngineSelection)
    case applied(SpeechEngineSelection)
    case failed(SpeechEngineSelection, String)

    var isApplying: Bool {
        if case .applying = self { return true }
        return false
    }
}

@MainActor
@Observable
final class SpeechSettingsController {
    static let parakeetIncompatibleBundledVersion = VoxTypeVersion(
        major: 0,
        minor: 7,
        patch: 5,
        prerelease: nil
    )

    private(set) var installationState: VoxTypeInstallationPresentation
    private(set) var daemonState: VoxTypeDaemonPresentation = .checking
    private(set) var hotkeyState: VoxTypeHotkeyPresentation = .checking
    private(set) var inventorySnapshot: ModelInventorySnapshot
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var microphoneTest: SpeechHardwareTestResult?
    private(set) var microphoneTestLevel: Float = 0
    private(set) var microphoneInventory = MeetingMicrophoneInventorySnapshot(
        devices: [],
        defaultDeviceUID: nil
    )
    private(set) var microphoneSelection: MeetingMicrophoneSelection
    private(set) var systemAudioTest: SpeechHardwareTestResult?
    private(set) var isTestingMicrophone = false
    private(set) var isTestingSystemAudio = false
    private(set) var modelApplicationStates: [SpeechWorkflow: SpeechModelApplicationState] = [:]

    @ObservationIgnored private let voxType: (any VoxTypeControlling)?
    @ObservationIgnored private let inventory: any SpeechModelInventoryControlling
    @ObservationIgnored private let selections: SpeechSelectionStore
    @ObservationIgnored private let actions: any SpeechSettingsActionHandling
    @ObservationIgnored private let modelActivator: (any VoxTypeModelApplying)?
    @ObservationIgnored private let modelSource: VoxTypeModelSourceOfTruth?
    @ObservationIgnored private let microphoneService: (any MeetingMicrophoneSettingsServing)?
    @ObservationIgnored private let microphoneSelectionStore: MeetingMicrophoneSelectionStore
    @ObservationIgnored private var modelApplicationTask: Task<Void, Never>?
    @ObservationIgnored private var modelApplicationRevision: UInt64 = 0
    @ObservationIgnored private var transientSelections: [SpeechWorkflow: SpeechEngineSelection] = [:]

    init(
        voxType: (any VoxTypeControlling)?,
        inventory: any SpeechModelInventoryControlling,
        selections: SpeechSelectionStore,
        modelActivator: (any VoxTypeModelApplying)? = nil,
        modelSource: VoxTypeModelSourceOfTruth? = nil,
        actions: any SpeechSettingsActionHandling = UnavailableSpeechSettingsActions(),
        microphoneService: (any MeetingMicrophoneSettingsServing)? = nil,
        microphoneSelectionStore: MeetingMicrophoneSelectionStore = MeetingMicrophoneSelectionStore(),
        initialSnapshot: ModelInventorySnapshot = .unknown
    ) {
        self.voxType = voxType
        self.inventory = inventory
        self.selections = selections
        self.modelActivator = modelActivator
        self.modelSource = modelSource
        self.actions = actions
        self.microphoneService = microphoneService
        self.microphoneSelectionStore = microphoneSelectionStore
        microphoneSelection = microphoneSelectionStore.selection
        inventorySnapshot = initialSnapshot
        installationState = voxType == nil ? .missing : .checking
        if voxType == nil {
            daemonState = .unavailable(.launchFailed)
            hotkeyState = .unavailable
        }
    }

    var selectedMicrophoneDetail: String {
        switch microphoneSelection {
        case .systemDefault:
            if let uid = microphoneInventory.defaultDeviceUID,
               let device = microphoneInventory.devices.first(where: { $0.id == uid }) {
                return "Following system default: \(device.name)"
            }
            return "The system default microphone is unavailable."
        case .device(let uid):
            if let device = microphoneInventory.devices.first(where: { $0.id == uid }) {
                return "Pinned to \(device.name). If it disconnects during a meeting, Brain shows a warning and switches to the system default."
            }
            return "The pinned microphone is unavailable. Reconnect it or select another input."
        }
    }

    var selectedMicrophoneIsAvailable: Bool {
        switch microphoneSelection {
        case .systemDefault:
            microphoneInventory.defaultDeviceUID != nil
        case .device(let uid):
            microphoneInventory.devices.contains { $0.id == uid }
        }
    }

    func selectMicrophone(_ selection: MeetingMicrophoneSelection) {
        microphoneSelectionStore.select(selection)
        microphoneSelection = selection
        microphoneTest = nil
        microphoneTestLevel = 0
    }

    var modelRows: [SpeechModelSettingsRow] {
        SpeechEngineCatalog.models.map {
            SpeechModelSettingsRow(
                model: $0,
                availability: inventorySnapshot.availability(for: $0.id)
            )
        }
    }

    func selection(for workflow: SpeechWorkflow) -> SpeechEngineSelection {
        if let transient = transientSelections[workflow] { return transient }
        if let global = modelSource?.selection { return global }
        let stored = selections.selection(for: workflow)
        if let pending = stored.pending { return pending }
        if let active = stored.active { return active }
        let model = SpeechEngineCatalog.model(id: SpeechEngineCatalog.englishDefaultModelID)
        return SpeechEngineSelection(
            engine: model?.engine ?? .whisper,
            modelID: SpeechEngineCatalog.englishDefaultModelID
        )
    }

    func activeSelection(for workflow: SpeechWorkflow) -> SpeechEngineSelection? {
        if let global = modelSource?.selection,
           inventorySnapshot.availability(for: global.modelID) == .ready {
            return global
        }
        return selections.effectiveSelection(for: workflow, inventory: inventorySnapshot)
    }

    func models(for workflow: SpeechWorkflow) -> [SpeechModelDescriptor] {
        SpeechEngineCatalog.models(for: selection(for: workflow).engine)
    }

    func selectEngine(_ engine: SpeechEngineID, for workflow: SpeechWorkflow) {
        guard let model = SpeechEngineCatalog.models(for: engine).first else { return }
        selectModel(model.id, for: workflow)
    }

    func selectModel(_ modelID: String, for workflow: SpeechWorkflow) {
        guard let model = SpeechEngineCatalog.model(id: modelID) else { return }
        let requested = SpeechEngineSelection(engine: model.engine, modelID: model.id)
        do {
            if inventorySnapshot.availability(for: model.id) == .ready,
               let modelActivator {
                beginApplying(
                    requested,
                    for: workflow,
                    persisting: modelSource == nil ? nil : Set(SpeechWorkflow.allCases),
                    using: modelActivator
                )
            } else {
                cancelActiveApplication()
                _ = try selections.select(
                    requested,
                    for: workflow,
                    inventory: inventorySnapshot
                )
                modelApplicationStates[workflow] = .inactive
            }
            errorMessage = nil
        } catch {
            errorMessage = "Brain could not select that speech model."
        }
    }

    func modelApplicationState(for workflow: SpeechWorkflow) -> SpeechModelApplicationState {
        modelApplicationStates[workflow] ?? .inactive
    }

    func waitForPendingModelApplication() async {
        await modelApplicationTask?.value
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil

        if let microphoneService {
            do {
                microphoneInventory = try await microphoneService.inventory()
            } catch {
                microphoneInventory = MeetingMicrophoneInventorySnapshot(
                    devices: [],
                    defaultDeviceUID: nil
                )
            }
        }

        guard let voxType else {
            inventorySnapshot = .unknown
            installationState = .missing
            daemonState = .unavailable(.launchFailed)
            hotkeyState = .unavailable
            if modelActivator == nil { selections.reconcile(with: inventorySnapshot) }
            return
        }

        async let refreshedInventory = inventory.refresh()
        async let version: VoxTypeVersion? = try? voxType.version()
        async let hotkey: VoxTypeHotkeyConfiguration? = try? voxType.hotkeyConfiguration()
        async let status = voxType.status()
        inventorySnapshot = await refreshedInventory
        let resolvedVersion = await version
        let resolvedStatus = await status
        if let modelSource {
            _ = try? modelSource.migrateIfNeeded(
                status: resolvedStatus,
                inventory: inventorySnapshot
            )
        }
        if let resolvedVersion {
            installationState = .installed(resolvedVersion)
        } else {
            installationState = .unavailable
        }
        daemonState = Self.daemonPresentation(resolvedStatus)
        if let hotkey = await hotkey {
            hotkeyState = .configured(hotkey)
        } else {
            hotkeyState = .unavailable
        }
        if await repairUnsupportedParakeetSelectionIfNeeded(
            version: resolvedVersion,
            status: resolvedStatus
        ) {
            return
        }
        reconcileReadyPendingSelections()
    }

    /// Brain 0.1.2 could select Parakeet even though its verified VoxType 0.7.5
    /// universal binary was built without that optional engine. Repair that
    /// shipped combination once by installing and activating the bundled-safe
    /// Whisper default for both speech workflows.
    private func repairUnsupportedParakeetSelectionIfNeeded(
        version: VoxTypeVersion?,
        status: VoxTypeStatus
    ) async -> Bool {
        guard let version,
              version <= Self.parakeetIncompatibleBundledVersion,
              let activeModelID = status.snapshot?.model,
              SpeechEngineCatalog.model(id: activeModelID)?.engine == .parakeet,
              let defaultModel = SpeechEngineCatalog.model(
                  id: SpeechEngineCatalog.englishDefaultModelID
              ),
              defaultModel.engine == .whisper,
              let modelActivator else {
            return false
        }

        let repaired = SpeechEngineSelection(
            engine: defaultModel.engine,
            modelID: defaultModel.id
        )
        do {
            if inventorySnapshot.availability(for: repaired.modelID) != .ready {
                inventorySnapshot = try await inventory.install(
                    modelID: repaired.modelID,
                    progress: { _ in }
                )
            }
            try await modelActivator.apply(repaired)
            for workflow in SpeechWorkflow.allCases {
                try selections.activate(repaired, for: workflow)
                modelApplicationStates[workflow] = .applied(repaired)
            }
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Brain could not repair the incompatible speech model automatically."
        }
        return true
    }

    func installModel(_ modelID: String) async {
        guard let row = modelRows.first(where: { $0.id == modelID }), row.canInstall else {
            return
        }
        let priorSnapshot = inventorySnapshot
        inventorySnapshot = inventorySnapshot.replacing(.installing, for: modelID)
        errorMessage = nil

        do {
            let refreshed = try await inventory.install(modelID: modelID) { _ in }
            inventorySnapshot = refreshed
            reconcileReadyPendingSelections()
        } catch is CancellationError {
            inventorySnapshot = priorSnapshot
        } catch {
            inventorySnapshot = priorSnapshot
            errorMessage = "VoxType could not install \(row.model.displayName). Try again."
        }
    }

    private func reconcileReadyPendingSelections() {
        guard let modelActivator else {
            selections.reconcile(with: inventorySnapshot)
            return
        }
        let unconfiguredWorkflows = SpeechWorkflow.allCases.filter { workflow in
            let stored = selections.selection(for: workflow)
            return stored.active == nil && stored.pending == nil
        }
        if !unconfiguredWorkflows.isEmpty,
           inventorySnapshot.availability(for: SpeechEngineCatalog.englishDefaultModelID) == .ready {
            let model = SpeechEngineCatalog.model(id: SpeechEngineCatalog.englishDefaultModelID)
            let selection = SpeechEngineSelection(
                engine: model?.engine ?? .whisper,
                modelID: SpeechEngineCatalog.englishDefaultModelID
            )
            beginApplying(
                selection,
                for: unconfiguredWorkflows[0],
                persisting: Set(unconfiguredWorkflows),
                using: modelActivator
            )
            return
        }
        for workflow in SpeechWorkflow.allCases {
            guard let pending = selections.selection(for: workflow).pending,
                  inventorySnapshot.availability(for: pending.modelID) == .ready else {
                continue
            }
            beginApplying(pending, for: workflow, using: modelActivator)
        }
    }

    private func cancelActiveApplication() {
        modelApplicationRevision &+= 1
        modelApplicationTask?.cancel()
        for workflow in SpeechWorkflow.allCases where modelApplicationStates[workflow]?.isApplying == true {
            transientSelections[workflow] = nil
            modelApplicationStates[workflow] = .inactive
        }
    }

    private func beginApplying(
        _ requested: SpeechEngineSelection,
        for workflow: SpeechWorkflow,
        persisting workflowsToPersist: Set<SpeechWorkflow>? = nil,
        using activator: any VoxTypeModelApplying
    ) {
        let previous = modelApplicationTask
        previous?.cancel()
        modelApplicationRevision &+= 1
        let revision = modelApplicationRevision
        for current in SpeechWorkflow.allCases where modelApplicationStates[current]?.isApplying == true {
            transientSelections[current] = nil
            modelApplicationStates[current] = .inactive
        }
        transientSelections[workflow] = requested
        modelApplicationStates[workflow] = .applying(requested)
        errorMessage = nil

        modelApplicationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == self.modelApplicationRevision else { return }
            do {
                try Task.checkCancellation()
                if let modelSource = self.modelSource {
                    _ = try await modelSource.activate(requested)
                } else {
                    try await activator.apply(requested)
                }
                try Task.checkCancellation()
                guard revision == self.modelApplicationRevision else { return }
                for target in workflowsToPersist ?? [workflow] {
                    try self.selections.activate(requested, for: target)
                }
                self.transientSelections[workflow] = nil
                self.modelApplicationStates[workflow] = .applied(requested)
                self.errorMessage = nil
            } catch is CancellationError {
                guard revision == self.modelApplicationRevision else { return }
                self.transientSelections[workflow] = nil
                self.modelApplicationStates[workflow] = .inactive
            } catch {
                guard revision == self.modelApplicationRevision else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "VoxType could not apply that model. The previous model was restored."
                self.transientSelections[workflow] = nil
                self.modelApplicationStates[workflow] = .failed(requested, message)
                self.errorMessage = message
            }
        }
    }

    func testMicrophone() async {
        guard !isTestingMicrophone else { return }
        isTestingMicrophone = true
        microphoneTest = nil
        microphoneTestLevel = 0
        if let microphoneService {
            microphoneTest = await microphoneService.test(
                selection: microphoneSelection,
                duration: .seconds(5)
            ) { [weak self] level in
                Task { @MainActor in self?.microphoneTestLevel = level }
            }
        } else {
            microphoneTest = await actions.testMicrophone()
        }
        isTestingMicrophone = false
    }

    func testSystemAudio() async {
        guard !isTestingSystemAudio else { return }
        isTestingSystemAudio = true
        systemAudioTest = await actions.testSystemAudio()
        isTestingSystemAudio = false
    }

    private static func daemonPresentation(_ status: VoxTypeStatus) -> VoxTypeDaemonPresentation {
        switch status {
        case .available(let snapshot) where snapshot.daemonIsRunning:
            .running(snapshot.state)
        case .available:
            .stopped
        case .unavailable(let reason):
            .unavailable(reason)
        }
    }
}

@MainActor
struct SpeechSettingsView: View {
    @Bindable var controller: SpeechSettingsController
    @AccessibilityFocusState private var errorIsFocused: Bool

    var body: some View {
        Form {
            Section("VoxType") {
                statusRow(
                    title: "Installation",
                    detail: controller.installationState.detail,
                    badgeTitle: controller.installationState.title,
                    symbolName: controller.installationState.symbolName,
                    accessibilityLabel: controller.installationState.accessibilityLabel
                )
                statusRow(
                    title: "Daemon",
                    detail: controller.daemonState.detail,
                    badgeTitle: controller.daemonState.title,
                    symbolName: controller.daemonState.symbolName,
                    accessibilityLabel: controller.daemonState.accessibilityLabel
                )
                statusRow(
                    title: "Shortcut",
                    detail: controller.hotkeyState.detail,
                    badgeTitle: controller.hotkeyState.title,
                    symbolName: controller.hotkeyState.symbolName,
                    accessibilityLabel: controller.hotkeyState.accessibilityLabel
                )

                HStack {
                    Spacer()
                    Button("Refresh") {
                        Task { await controller.refresh() }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
                .disabled(controller.isRefreshing)

                Link("Open VoxType guide", destination: SpeechEngineCatalog.modelGuideURL)
                Text("Brain can enable its included VoxType and install catalog models in-app. Existing standalone installations remain preferred; Brain changes only models you explicitly select.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            workflowSection(.dictation)

            Section("Audio Tests") {
                Picker("Microphone", selection: Binding(
                    get: { controller.microphoneSelection },
                    set: { controller.selectMicrophone($0) }
                )) {
                    Text("System Default").tag(MeetingMicrophoneSelection.systemDefault)
                    ForEach(controller.microphoneInventory.devices) { device in
                        Text(device.name).tag(MeetingMicrophoneSelection.device(uid: device.id))
                    }
                }
                Label(
                    controller.selectedMicrophoneDetail,
                    systemImage: controller.selectedMicrophoneIsAvailable
                        ? "mic.fill"
                        : BrainWorkflowAccessibilityState.microphoneMissing.presentation.symbolName
                )
                .font(.caption)
                .foregroundStyle(
                    controller.selectedMicrophoneIsAvailable ? Color.secondary : Color.red
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Microphone selection")
                .accessibilityValue(controller.selectedMicrophoneDetail)
                .accessibilityAddTraits(
                    controller.selectedMicrophoneIsAvailable ? [] : .isStaticText
                )
                HStack {
                    Button("Test Microphone") {
                        Task { await controller.testMicrophone() }
                    }
                    .disabled(controller.isTestingMicrophone)
                    .accessibilityValue(controller.isTestingMicrophone ? "Disabled" : "Enabled")
                    Button("Test System Audio") {
                        Task { await controller.testSystemAudio() }
                    }
                    .disabled(controller.isTestingSystemAudio)
                    .accessibilityValue(controller.isTestingSystemAudio ? "Disabled" : "Enabled")
                }
                if controller.isTestingMicrophone {
                    ProgressView(value: controller.microphoneTestLevel)
                        .accessibilityLabel("Live microphone test level")
                        .accessibilityValue("\(Int((controller.microphoneTestLevel * 100).rounded())) percent")
                }
                hardwareResult(controller.microphoneTest, label: "Microphone")
                hardwareResult(controller.systemAudioTest, label: "System audio")
            }

            if let errorMessage = controller.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Speech settings error: \(errorMessage)")
                        .accessibilityFocused($errorIsFocused)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speech")
        .task { await controller.refresh() }
        .onChange(of: controller.errorMessage) { _, error in
            if error != nil { errorIsFocused = true }
        }
    }

    @ViewBuilder
    private func workflowSection(_ workflow: SpeechWorkflow) -> some View {
        let selection = controller.selection(for: workflow)
        Section("Speech Model") {
            Picker("Engine", selection: Binding(
                get: { controller.selection(for: workflow).engine },
                set: { controller.selectEngine($0, for: workflow) }
            )) {
                ForEach(SpeechEngineCatalog.engines) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }
            .accessibilityLabel("VoxType speech engine")
            .accessibilityValue(
                SpeechEngineCatalog.engines.first(where: { $0.id == selection.engine })?
                    .displayName ?? selection.engine.rawValue
            )

            Picker("Model", selection: Binding(
                get: { controller.selection(for: workflow).modelID },
                set: { controller.selectModel($0, for: workflow) }
            )) {
                ForEach(controller.models(for: workflow)) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .accessibilityLabel("VoxType speech model for dictation and meetings")
            .accessibilityValue(
                SpeechEngineCatalog.model(id: selection.modelID)?.displayName
                    ?? selection.modelID
            )

            if let row = controller.modelRows.first(where: { $0.id == selection.modelID }) {
                modelStateBadge(row)
                capabilityBadges(row.capabilities)
                modelApplicationStatus(workflow)
                if !controller.modelApplicationState(for: workflow).isApplying,
                   controller.activeSelection(for: workflow) != selection {
                    Text("This choice is pending and will not become active until its model is Ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(workflow.displayName) selection is pending until the model is ready")
                }
                if let detail = row.recommendationDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link("VoxType model guide", destination: SpeechEngineCatalog.modelGuideURL)
                    .font(.caption)
                Text("This active model is used for dictation, live meeting preview, and final meeting transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(
        title: String,
        detail: String,
        badgeTitle: String,
        symbolName: String,
        accessibilityLabel: String
    ) -> some View {
        LabeledContent {
            Label(badgeTitle, systemImage: symbolName)
                .accessibilityLabel(accessibilityLabel)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func modelRow(_ row: SpeechModelSettingsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.model.displayName)
                    if let recommendation = row.recommendationTitle {
                        Text(recommendation)
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("\(row.model.displayName): \(recommendation)")
                    }
                    Text(SpeechEngineCatalog.engines.first(where: { $0.id == row.model.engine })?.displayName ?? row.model.engine.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelStateBadge(row)
                if row.canInstall {
                    Button(row.availability == .incompatible ? "Install Supported Build" : "Install") {
                        Task { await controller.installModel(row.id) }
                    }
                    .accessibilityLabel("Install \(row.model.displayName) using VoxType")
                }
            }
            capabilityBadges(row.capabilities)
            if row.availability == .installing {
                ProgressView("Installing \(row.model.displayName)")
                    .accessibilityLabel("Installing \(row.model.displayName)")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func modelApplicationStatus(_ workflow: SpeechWorkflow) -> some View {
        switch controller.modelApplicationState(for: workflow) {
        case .inactive:
            EmptyView()
        case .applying(let selection):
            ProgressView("Applying \(SpeechEngineCatalog.model(id: selection.modelID)?.displayName ?? selection.modelID)…")
                .brainAccessibleStatus(
                    .applyingModel,
                    detail: "\(workflow.displayName): \(selection.modelID)"
                )
        case .applied(let selection):
            Label(
                "Applied \(SpeechEngineCatalog.model(id: selection.modelID)?.displayName ?? selection.modelID)",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .accessibilityLabel("\(workflow.displayName) model state: Applied")
        case .failed(_, let message):
            Label("Restored previous model — \(message)", systemImage: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("\(workflow.displayName) model state: Failed. \(message)")
                .accessibilityValue(message)
        }
    }

    private func modelStateBadge(_ row: SpeechModelSettingsRow) -> some View {
        Label(row.stateTitle, systemImage: row.stateSymbolName)
            .font(.caption)
            .accessibilityLabel(row.accessibilityLabel)
    }

    private func capabilityBadges(_ capabilities: [SpeechCapabilityBadge]) -> some View {
        HStack(spacing: 6) {
            ForEach(capabilities) { capability in
                Text(capability.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(capability.accessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private func hardwareResult(_ result: SpeechHardwareTestResult?, label: String) -> some View {
        if let result {
            switch result {
            case .ready(let detail):
                Label("\(label) Ready — \(detail)", systemImage: "checkmark.circle.fill")
                    .accessibilityLabel("\(label) test state: Ready. \(detail)")
            case .failed(let detail):
                Label("\(label) test failed — \(detail)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .brainAccessibleStatus(
                        label == "Microphone" ? .microphoneMissing : .failed,
                        detail: detail
                    )
            }
        }
    }
}

private extension VoxTypeRuntimeState {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .recording: "Recording"
        case .streaming: "Streaming"
        case .transcribing: "Transcribing"
        case .stopped: "Stopped"
        }
    }
}

private extension VoxTypeUnavailableReason {
    var settingsDetail: String {
        switch self {
        case .daemonNotRunning:
            "Start VoxType for dictation and Brain meeting transcription."
        case .malformedStatus:
            "VoxType returned an unrecognized status. Check its configuration in VoxType."
        case .outputTooLarge:
            "VoxType returned more status data than Brain accepts."
        case .timedOut:
            "VoxType did not answer the status check in time."
        case .launchFailed:
            "Brain could not run the fixed VoxType status check."
        }
    }
}

private extension SpeechWorkflow {
    var displayName: String {
        switch self {
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        }
    }
}

private extension Int {
    var settingsDiskSize: String {
        self >= 1_000
            ? String(format: "%.1f GB", Double(self) / 1_000)
            : "\(self) MB"
    }
}
