import Carbon.HIToolbox
import Foundation

/// The whole runtime surface for the minimal UI's menubar and global
/// hotkeys — replaces `CommandPaletteFactory` / `CommandRegistry` /
/// `RegistryMenu`. There is no command palette in the minimal UI, so one
/// small enum is enough: it builds the 4-item menu (Start/Finish Recording,
/// Open RTI, Settings…, plus Quit which `MenuCoordinator` adds natively) and
/// registers the 4 global hotkeys that survive the cut.
@MainActor
enum Commands {
    struct MenuItem {
        /// Re-evaluated on every menu-open, so "Start/Finish Recording"
        /// tracks the live session phase.
        let title: () -> String
        let action: () -> Void
    }

    static func menuItems() -> [MenuItem] {
        [
            MenuItem(
                title: {
                    SessionCoordinator.shared.isRunning ? "Finish recording  ⌘⇧R" : "Start recording  ⌘⇧R"
                },
                action: { SessionCoordinator.shared.toggleSession() }
            ),
            MenuItem(
                title: { "Open RTI" },
                action: { WindowCoordinator.shared.showOverlay() }
            ),
            MenuItem(
                title: { "Settings…" },
                action: {
                    WindowCoordinator.shared.showOverlay()
                    NotificationCenter.default.post(name: .rtiOpenSettings, object: nil)
                }
            ),
        ]
    }

    /// ⌘⇧R start/finish, ⌘⇧P pause/resume, ⌘\ toggle overlay, ⌘⏎ assist.
    /// Nothing else survives the cut.
    static func registerHotkeys(on hotkey: GlobalHotkey) {
        hotkey.register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)) {
            SessionCoordinator.shared.toggleSession()
        }
        hotkey.register(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)) {
            SessionCoordinator.shared.togglePause()
        }
        hotkey.register(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey)) {
            WindowCoordinator.shared.toggleOverlay()
        }
        hotkey.register(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) {
            LLMController.shared.perform(actionID: "assist")
        }
    }
}
