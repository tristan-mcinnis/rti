import AppKit
import SwiftUI

/// Owns the borderless `NSPanel` that hosts the command palette. Single
/// responsibility: show, hide, recenter on open. The palette body itself
/// (`CommandPaletteView`) handles search + keyboard nav + dismissal.
@MainActor
final class CommandPaletteWindowController {
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if let panel {
            recenter(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CommandPaletteView(
            registry: CommandRegistry.shared,
            onDismiss: { [weak self] in self?.hide() }
        )
        p.contentView = NSHostingView(rootView: view)

        // Round the corners; SwiftUI's `.background(.regularMaterial)` paints
        // up to the host's bounds, so the radius lives on the layer.
        if let layer = p.contentView?.layer {
            layer.cornerRadius = 12
            layer.masksToBounds = true
        } else {
            p.contentView?.wantsLayer = true
            p.contentView?.layer?.cornerRadius = 12
            p.contentView?.layer?.masksToBounds = true
        }

        recenter(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func recenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let w: CGFloat = 600
        // Default content height — palette will grow downward as results
        // arrive; this gives a usable starting size.
        let h: CGFloat = 80
        let x = frame.midX - (w / 2)
        // Position roughly a third from the top — same idiom Spotlight uses.
        let y = frame.maxY - (frame.height / 3) - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }
}
