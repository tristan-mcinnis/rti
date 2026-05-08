import AppKit
import SwiftUI

struct ShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(key: "\u{2318}\\", desc: "Toggle overlay")
                ShortcutRow(key: "\u{2318}K", desc: "Search / command palette")
                ShortcutRow(key: "\u{2318}\u{21E7}R", desc: "Start / Stop recording")
                ShortcutRow(key: "\u{2318}\u{21E7}B", desc: "Show / hide top widget")
                ShortcutRow(key: "\u{2318}\u{21A9}", desc: "Send Assist")
                ShortcutRow(key: "\u{2318}H", desc: "Capture screen & OCR")
                ShortcutRow(key: "\u{2318}\u{2325}T", desc: "Show live transcript")
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}

private struct ShortcutRow: View {
    let key: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 64, alignment: .trailing)
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

@MainActor
final class ShortcutsWindowController {
    private let window: NSPanel

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 210),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = "Shortcuts"
        panel.backgroundColor = NSColor(white: 0.08, alpha: 1)
        panel.isOpaque = false
        panel.sharingType = .none
        panel.center()
        panel.contentView = NSHostingView(rootView: ShortcutsView())
        self.window = panel
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
