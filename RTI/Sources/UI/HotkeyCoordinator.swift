import Carbon.HIToolbox

/// Registers global hotkeys from the shared `[RTICommand]` registry.
/// Commands with non-nil `hotkeyKeyCode` and `hotkeyModifiers` get a
/// Carbon hotkey; all others are skipped.
///
/// Hotkeys come in two scopes. Always-on chords (start/stop, show RTI)
/// live for the app's lifetime. Session-scoped chords (⌘⏎ and the quick
/// actions) are held only while a session is recording — a Carbon hotkey
/// consumes its chord for the whole system, so keeping ⌘⏎ registered all
/// day silently breaks Command-Return in every other app.
@MainActor
final class HotkeyCoordinator {
    private var alwaysOn: GlobalHotkey?
    private var sessionScoped: GlobalHotkey?
    private var sessionCommands: [RTICommand] = []
    private var sessionHotkeysActive = false

    /// Register always-on hotkeys now; remember session-scoped ones for
    /// `setSessionActive(true)`. Commands without `hotkeyKeyCode` are skipped.
    func registerAll(commands: [RTICommand]) {
        let hk = GlobalHotkey()
        sessionCommands = []
        for cmd in commands {
            guard cmd.hotkeyKeyCode != nil, cmd.hotkeyModifiers != nil else { continue }
            if cmd.hotkeySessionScoped {
                sessionCommands.append(cmd)
            } else {
                register(cmd, on: hk)
            }
        }
        alwaysOn = hk
        if sessionHotkeysActive { armSessionHotkeys() }
    }

    /// Arm or release the session-scoped chords as recording starts/stops.
    /// Idempotent — safe to call on every session-state observation tick.
    func setSessionActive(_ active: Bool) {
        guard active != sessionHotkeysActive else { return }
        sessionHotkeysActive = active
        if active {
            armSessionHotkeys()
        } else {
            sessionScoped?.unregisterAll()
        }
    }

    private func armSessionHotkeys() {
        let hk = sessionScoped ?? GlobalHotkey()
        sessionScoped = hk
        for cmd in sessionCommands { register(cmd, on: hk) }
    }

    private func register(_ cmd: RTICommand, on hk: GlobalHotkey) {
        guard let keyCode = cmd.hotkeyKeyCode,
              let modifiers = cmd.hotkeyModifiers else { return }
        hk.register(keyCode: keyCode, modifiers: modifiers) { [cmd] in
            cmd.perform()
        }
    }
}
