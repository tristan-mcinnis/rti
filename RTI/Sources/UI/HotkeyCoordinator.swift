import Carbon.HIToolbox

/// Registers global hotkeys and maps them to app actions.
@MainActor
final class HotkeyCoordinator {
    private var hotkey: GlobalHotkey?

    var onToggleOverlay: (() -> Void)?
    var onToggleSession: (() -> Void)?
    var onSendAssist: (() -> Void)?
    var onCaptureScreen: (() -> Void)?
    var onToggleDebugConsole: (() -> Void)?
    var onToggleCommandPalette: (() -> Void)?
    var onToggleTopWidget: (() -> Void)?

    func registerAll() {
        let hk = GlobalHotkey()
        hk.register(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.onToggleOverlay?()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.onToggleSession?()
        }
        hk.register(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.onSendAssist?()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.onCaptureScreen?()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.onToggleDebugConsole?()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.onToggleCommandPalette?()
        }
        hk.register(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.onToggleTopWidget?()
        }
        hotkey = hk
    }
}
