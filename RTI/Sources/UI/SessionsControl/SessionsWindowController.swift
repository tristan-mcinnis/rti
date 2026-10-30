import AppKit
import RTICore

/// Compatibility entry point for links to the archive.
@MainActor
final class SessionsWindowController {
    func show(folder: String? = nil) {
        if let folder { WindowCoordinator.shared.showSession(folder: folder) }
        else { WindowCoordinator.shared.showSessions() }
    }
}

/// The Sessions window. Takes its keys before the text views and menus do
/// (`SessionsWindowKeys`): ⌃⌘S the list, ⌘F find, ⌘K actions, ⌘J ask,
/// ⌘1…⌘9 rows, and esc, ↩, ↑, ↓ while a layer wants them. Marked text (an
/// input method composing, as with pinyin) keeps its own keys.
final class SessionsWindow: NSWindow {
    weak var model: SessionsWindowModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText, let model,
           let command = SessionsWindowKeys.command(
               characters: event.charactersIgnoringModifiers ?? "",
               modifiers: Self.modifiers(of: event)
           ) {
            if command == .close {
                performClose(nil)
                return true
            }
            if model.handle(command) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            model?.isCommandHeld = Self.modifiers(of: event) == .command
        case .keyDown:
            if !hasMarkedText, let model,
               let command = SessionsWindowKeys.plainKey(keyCode: event.keyCode, modifiers: Self.modifiers(of: event)),
               model.handle(command) {
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private var hasMarkedText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    static func modifiers(of event: NSEvent) -> SessionsWindowKeys.Modifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: SessionsWindowKeys.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }
}
