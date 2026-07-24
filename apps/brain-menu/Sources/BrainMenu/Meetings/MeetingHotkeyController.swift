import Foundation
import Observation

@MainActor
@Observable
final class MeetingHotkeyController {
    static let defaultHotkey = CaptureHotkey.controlOptionM
    static let enabledDefaultsKey = "BrainMenu.meetingHotkey.enabled"
    static let keyCodeDefaultsKey = "BrainMenu.meetingHotkey.keyCode"
    static let modifiersDefaultsKey = "BrainMenu.meetingHotkey.modifiers"

    private(set) var hotkey: CaptureHotkey
    private(set) var isEnabled: Bool
    private(set) var isRegistered = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registrar: any CaptureHotkeyRegistering
    @ObservationIgnored private let action: @MainActor () -> Void

    init(
        defaults: UserDefaults = .standard,
        registrar: any CaptureHotkeyRegistering = SystemCaptureHotkeyRegistrar(identifier: 4),
        action: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.registrar = registrar
        self.action = action
        hotkey = Self.persistedHotkey(defaults: defaults) ?? Self.defaultHotkey
        isEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
    }

    @discardableResult
    func start() -> Bool {
        guard isEnabled else {
            stopRegistration()
            return true
        }
        return register(hotkey)
    }

    func stop() {
        stopRegistration()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            _ = register(hotkey)
        } else {
            stopRegistration()
            errorMessage = nil
        }
    }

    func record(keyCode: UInt16, modifiers: CaptureHotkeyModifiers) throws {
        let replacement = CaptureHotkey(keyCode: keyCode, modifiers: modifiers)
        guard replacement.isValid else { throw CaptureHotkeyError.invalidShortcut }

        let previous = hotkey
        stopRegistration()
        if isEnabled {
            do {
                try registrar.register(replacement, action: action)
                isRegistered = true
            } catch {
                hotkey = previous
                _ = register(previous)
                if let captureError = error as? CaptureHotkeyError {
                    throw captureError
                }
                throw CaptureHotkeyError.registrationFailed(status: -1)
            }
        }

        hotkey = replacement
        defaults.set(Int(replacement.keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(replacement.modifiers.rawValue), forKey: Self.modifiersDefaultsKey)
        errorMessage = nil
    }

    static func persistedHotkey(defaults: UserDefaults) -> CaptureHotkey? {
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil else {
            return nil
        }
        let keyCodeValue = defaults.integer(forKey: keyCodeDefaultsKey)
        let modifiersValue = defaults.integer(forKey: modifiersDefaultsKey)
        guard keyCodeValue >= 0, keyCodeValue <= Int(UInt16.max), modifiersValue >= 0 else {
            return nil
        }
        let hotkey = CaptureHotkey(
            keyCode: UInt16(keyCodeValue),
            modifiers: CaptureHotkeyModifiers(rawValue: UInt(modifiersValue))
        )
        return hotkey.isValid ? hotkey : nil
    }

    private func register(_ hotkey: CaptureHotkey) -> Bool {
        do {
            try registrar.register(hotkey, action: action)
            isRegistered = true
            errorMessage = nil
            return true
        } catch {
            isRegistered = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func stopRegistration() {
        registrar.unregister()
        isRegistered = false
    }
}
