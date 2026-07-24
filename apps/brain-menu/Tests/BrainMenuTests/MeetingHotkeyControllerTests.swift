import Foundation
import Testing
@testable import BrainMenu

@MainActor
struct MeetingHotkeyControllerTests {
    @Test
    func shortcutIsOffByDefaultAndPersistsChosenToggle() throws {
        let suite = "MeetingHotkeyControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registrar = MeetingHotkeyRegistrar()
        var actionCount = 0
        let controller = MeetingHotkeyController(
            defaults: defaults,
            registrar: registrar
        ) {
            actionCount += 1
        }

        #expect(!controller.isEnabled)
        #expect(controller.start())
        #expect(registrar.hotkey == nil)

        controller.setEnabled(true)
        #expect(controller.isRegistered)
        #expect(registrar.hotkey == .controlOptionM)
        registrar.trigger()
        #expect(actionCount == 1)

        let replacement = CaptureHotkey(keyCode: 15, modifiers: [.control, .option])
        try controller.record(
            keyCode: replacement.keyCode,
            modifiers: replacement.modifiers
        )
        #expect(controller.hotkey == replacement)

        let restored = MeetingHotkeyController(
            defaults: defaults,
            registrar: MeetingHotkeyRegistrar()
        ) {}
        #expect(restored.isEnabled)
        #expect(restored.hotkey == replacement)
    }
}

@MainActor
private final class MeetingHotkeyRegistrar: CaptureHotkeyRegistering {
    private(set) var hotkey: CaptureHotkey?
    private var action: (@MainActor () -> Void)?

    func register(
        _ hotkey: CaptureHotkey,
        action: @escaping @MainActor () -> Void
    ) throws {
        self.hotkey = hotkey
        self.action = action
    }

    func unregister() {
        hotkey = nil
        action = nil
    }

    func trigger() {
        action?()
    }
}
