import AppKit

extension NSPasteboard {
    /// Convenience: clear the general pasteboard and set a single string.
    /// Named `copyString` rather than `copy` to avoid colliding with
    /// NSObject's Obj-C `copy(_:)` selector.
    static func copyString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
