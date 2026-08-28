import Carbon.HIToolbox

/// Registers global hotkeys from the shared `[RTICommand]` registry.
/// Commands with non-nil `hotkeyKeyCode` and `hotkeyModifiers` get a
/// Carbon hotkey; all others are skipped. No per-action closure properties.
@MainActor
final class HotkeyCoordinator {
    private var hotkey: GlobalHotkey?

    /// Register every command that carries a hotkey. Commands without
    /// `hotkeyKeyCode` are silently skipped.
    func registerAll(commands: [RTICommand]) {
        let hk = GlobalHotkey()
        for cmd in commands {
            guard let keyCode = cmd.hotkeyKeyCode,
                  let modifiers = cmd.hotkeyModifiers else { continue }
            hk.register(keyCode: keyCode, modifiers: modifiers) { [cmd] in
                cmd.perform()
            }
        }
        hotkey = hk
    }
}