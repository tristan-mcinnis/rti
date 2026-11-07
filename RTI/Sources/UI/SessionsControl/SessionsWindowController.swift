import AppKit
import RTICore

/// Reads an event's modifier keys the way `SessionsWindowKeys` matches them.
/// The main window (`OverlayWindowController`) routes Sessions keys with it.
enum SessionsWindow {
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
