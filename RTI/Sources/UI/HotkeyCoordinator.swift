/// Owns the process-wide `GlobalHotkey` instance and registers RTI's four
/// global hotkeys against it. Thin on purpose — the actual key/action list
/// lives in `Commands.swift`, the single source both this and
/// `MenuCoordinator` read from.
@MainActor
final class HotkeyCoordinator {
    private var hotkey: GlobalHotkey?

    func registerAll() {
        let hk = GlobalHotkey()
        Commands.registerHotkeys(on: hk)
        hotkey = hk
    }
}
