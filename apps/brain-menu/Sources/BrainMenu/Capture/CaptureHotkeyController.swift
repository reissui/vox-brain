import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

struct CaptureHotkeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    static let primary: Self = [.command, .control, .option]

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

}

struct CaptureHotkey: Codable, Equatable, Sendable {
    /// The hardware-independent macOS virtual key code.
    let keyCode: UInt16
    let modifiers: CaptureHotkeyModifiers

    static let controlOptionB = Self(
        keyCode: 11, // kVK_ANSI_B
        modifiers: [.control, .option]
    )

    static let controlOptionD = Self(
        keyCode: 2, // kVK_ANSI_D
        modifiers: [.control, .option]
    )

    static let controlOptionZ = Self(
        keyCode: 6, // kVK_ANSI_Z
        modifiers: [.control, .option]
    )

    var isValid: Bool {
        keyCode <= 127
            && !Self.modifierOnlyKeyCodes.contains(keyCode)
            && !modifiers.intersection(.primary).isEmpty
            && modifiers.isSubset(of: [.command, .control, .option, .shift])
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, // right/left Command
        56, 60, // left/right Shift
        57,     // Caps Lock
        58, 61, // left/right Option
        59, 62, // left/right Control
        63,     // Fn
    ]
}

enum CaptureHotkeyError: Error, Equatable, LocalizedError, Sendable {
    case invalidShortcut
    case shortcutUnavailable
    case registrationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            "Use Command, Control, or Option with a non-modifier key."
        case .shortcutUnavailable:
            "That shortcut is already in use. Choose another shortcut in Brain Settings."
        case .registrationFailed:
            "Brain could not register this shortcut. Choose another shortcut or restart Brain."
        }
    }
}

struct QuickCaptureApplicationIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
}

@MainActor
protocol QuickCaptureOpening: AnyObject {
    func open(sourceApplication: QuickCaptureApplicationIdentity?)
}

@MainActor
protocol CaptureHotkeyRegistering: AnyObject {
    func register(_ hotkey: CaptureHotkey, action: @escaping @MainActor () -> Void) throws
    func unregister()
}

@MainActor
protocol FrontmostApplicationProviding: AnyObject {
    var frontmostApplication: QuickCaptureApplicationIdentity? { get }
}

@MainActor
final class WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    var frontmostApplication: QuickCaptureApplicationIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return QuickCaptureApplicationIdentity(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }
}

@MainActor
protocol CarbonHotKeyInstalling: AnyObject {
    func install(
        _ hotkey: CaptureHotkey,
        identifier: UInt32,
        action: @escaping @MainActor () -> Void
    ) throws -> CarbonHotKeyRegistration
}

@MainActor
final class CarbonHotKeyRegistration {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let cancellation = cancellation
        self.cancellation = nil
        cancellation?()
    }
}

private final class CarbonHotKeyActionBox: @unchecked Sendable {
    let signature: OSType
    let identifier: UInt32
    let action: @MainActor () -> Void

    init(signature: OSType, identifier: UInt32, action: @escaping @MainActor () -> Void) {
        self.signature = signature
        self.identifier = identifier
        self.action = action
    }
}

@MainActor
final class SystemCarbonHotKeyInstaller: CarbonHotKeyInstalling {
    private static let signature: OSType = 0x4252_4E48 // "BRNH"

    func install(
        _ hotkey: CaptureHotkey,
        identifier: UInt32,
        action: @escaping @MainActor () -> Void
    ) throws -> CarbonHotKeyRegistration {
        let box = CarbonHotKeyActionBox(
            signature: Self.signature,
            identifier: identifier,
            action: action
        )
        let context = Unmanaged.passRetained(box).toOpaque()
        var handlerRef: EventHandlerRef?
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let box = Unmanaged<CarbonHotKeyActionBox>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var received = EventHotKeyID()
                let status = withUnsafeMutablePointer(to: &received) { pointer in
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        pointer
                    )
                }
                guard status == noErr,
                      received.signature == box.signature,
                      received.id == box.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in box.action() }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard handlerStatus == noErr, let handlerRef else {
            Unmanaged<CarbonHotKeyActionBox>.fromOpaque(context).release()
            throw CaptureHotkeyError.registrationFailed(status: handlerStatus)
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registrationStatus = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            Self.carbonModifiers(hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr, let hotKeyRef else {
            RemoveEventHandler(handlerRef)
            Unmanaged<CarbonHotKeyActionBox>.fromOpaque(context).release()
            if registrationStatus == OSStatus(eventHotKeyExistsErr) {
                throw CaptureHotkeyError.shortcutUnavailable
            }
            throw CaptureHotkeyError.registrationFailed(status: registrationStatus)
        }

        return CarbonHotKeyRegistration {
            UnregisterEventHotKey(hotKeyRef)
            RemoveEventHandler(handlerRef)
            Unmanaged<CarbonHotKeyActionBox>.fromOpaque(context).release()
        }
    }

    private static func carbonModifiers(_ modifiers: CaptureHotkeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}

/// Registers one operating-system hotkey without passively observing keyboard
/// events. Carbon reports the shortcut only when this exact registration fires.
@MainActor
final class SystemCaptureHotkeyRegistrar: CaptureHotkeyRegistering {
    private let carbon: any CarbonHotKeyInstalling
    private let identifier: UInt32
    private var registration: CarbonHotKeyRegistration?

    init(
        carbon: any CarbonHotKeyInstalling = SystemCarbonHotKeyInstaller(),
        identifier: UInt32 = 1
    ) {
        self.carbon = carbon
        self.identifier = identifier
    }

    func register(
        _ hotkey: CaptureHotkey,
        action: @escaping @MainActor () -> Void
    ) throws {
        guard hotkey.isValid else { throw CaptureHotkeyError.invalidShortcut }
        unregister()
        registration = try carbon.install(
            hotkey,
            identifier: identifier,
            action: action
        )
    }

    func unregister() {
        registration?.cancel()
        registration = nil
    }
}

@MainActor
@Observable
final class CaptureHotkeyController {
    static let defaultHotkey = CaptureHotkey.controlOptionB
    static let keyCodeDefaultsKey = "BrainMenu.quickCapture.keyCode"
    static let modifiersDefaultsKey = "BrainMenu.quickCapture.modifiers"

    private(set) var hotkey: CaptureHotkey
    private(set) var isRegistered = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registrar: any CaptureHotkeyRegistering
    @ObservationIgnored private let applications: any FrontmostApplicationProviding
    @ObservationIgnored private weak var panel: (any QuickCaptureOpening)?
    @ObservationIgnored private weak var adaptiveCapture: (any AdaptiveCapturePerforming)?

    init(
        panel: any QuickCaptureOpening,
        defaults: UserDefaults = .standard,
        registrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(),
        applications: any FrontmostApplicationProviding = WorkspaceFrontmostApplicationProvider(),
        adaptiveCapture: (any AdaptiveCapturePerforming)? = nil
    ) {
        self.panel = panel
        self.defaults = defaults
        self.registrar = registrar
        self.applications = applications
        self.adaptiveCapture = adaptiveCapture
        hotkey = Self.persistedHotkey(defaults: defaults) ?? Self.defaultHotkey
    }

    @discardableResult
    func start() -> Bool {
        do {
            try registrar.register(hotkey) { [weak self] in
                self?.openQuickCapture()
            }
            isRegistered = true
            errorMessage = nil
            return true
        } catch {
            isRegistered = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stop() {
        registrar.unregister()
        isRegistered = false
    }

    func record(keyCode: UInt16, modifiers: CaptureHotkeyModifiers) throws {
        let replacement = CaptureHotkey(keyCode: keyCode, modifiers: modifiers)
        guard replacement.isValid else { throw CaptureHotkeyError.invalidShortcut }

        let previous = hotkey
        registrar.unregister()
        isRegistered = false
        do {
            try registrar.register(replacement) { [weak self] in
                self?.openQuickCapture()
            }
            hotkey = replacement
            defaults.set(Int(replacement.keyCode), forKey: Self.keyCodeDefaultsKey)
            defaults.set(Int(replacement.modifiers.rawValue), forKey: Self.modifiersDefaultsKey)
            isRegistered = true
            errorMessage = nil
        } catch {
            hotkey = previous
            _ = start()
            if let captureError = error as? CaptureHotkeyError {
                throw captureError
            }
            throw CaptureHotkeyError.registrationFailed(status: -1)
        }
    }

    func openQuickCapture() {
        // Snapshot before any UI can activate Brain, preserving the exact app
        // whose Accessibility tree the adaptive action may inspect.
        let sourceApplication = applications.frontmostApplication
        if let adaptiveCapture {
            Task { @MainActor [weak adaptiveCapture] in
                await adaptiveCapture?.capture(from: sourceApplication)
            }
        } else {
            // Retained as a test seam and compatibility fallback. Production
            // supplies the adaptive action; the menu command opens the manual
            // panel directly through BrainAppControllerGraph.
            panel?.open(sourceApplication: sourceApplication)
        }
    }

    static func persistedHotkey(defaults: UserDefaults) -> CaptureHotkey? {
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil else {
            return nil
        }
        let stored = CaptureHotkey(
            keyCode: UInt16(clamping: defaults.integer(forKey: keyCodeDefaultsKey)),
            modifiers: CaptureHotkeyModifiers(
                rawValue: UInt(defaults.integer(forKey: modifiersDefaultsKey))
            )
        )
        return stored.isValid ? stored : nil
    }
}
