import AppKit
import SwiftUI

/// Owns the borderless `NSPanel` that hosts the command palette. Single
/// responsibility: show, hide, anchor on open. The palette body itself
/// (`CommandPaletteView`) handles search + keyboard nav + dismissal.
///
/// Anchoring policy: when the Sessions Control window is visible, the palette
/// presents as a child window centered on that window (Spotlight-style sheet
/// over the panel). Otherwise it falls back to a screen-centered position so
/// ⌘K still works from the overlay or top-widget contexts.
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
        let parent = preferredParentWindow()
        if let panel {
            attach(panel, to: parent)
            anchor(panel, to: parent)
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

        attach(p, to: parent)
        anchor(p, to: parent)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func hide() {
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    /// Add the palette as a child of the parent window so it tracks the
    /// parent's position/space. Skipped when there's no parent (the palette
    /// then lives as a free-floating panel).
    private func attach(_ panel: NSPanel, to parent: NSWindow?) {
        // Detach from any previous parent first so we don't accumulate
        // child-window relationships across opens.
        if let existing = panel.parent {
            existing.removeChildWindow(panel)
        }
        if let parent {
            parent.addChildWindow(panel, ordered: .above)
        }
    }

    /// Position the palette: centered horizontally on the parent (or screen),
    /// pinned ~80 px from the top — matching the Spotlight idiom.
    private func anchor(_ panel: NSPanel, to parent: NSWindow?) {
        let w: CGFloat = 600
        let h: CGFloat = max(panel.frame.height, 80)
        let topInset: CGFloat = 80

        let frame: NSRect
        if let parent {
            let pf = parent.frame
            let x = pf.midX - (w / 2)
            let y = pf.maxY - topInset - h
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - (w / 2)
            let y = visible.maxY - (visible.height / 3) - h
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else {
            return
        }
        panel.setFrame(frame, display: false)
    }

    /// The window the palette should attach to. Prefer the Sessions Control
    /// window (the surface a ⌘K user is most likely searching from), then
    /// any visible non-palette key/main window.
    private func preferredParentWindow() -> NSWindow? {
        let sessionsControl = NSApp.windows.first { window in
            window.frameAutosaveName == "rti.sessionscontrol" && window.isVisible
        }
        if let sessionsControl { return sessionsControl }

        // Fallbacks. Skip our own panel so we never parent to ourselves.
        if let key = NSApp.keyWindow, key !== panel, key.isVisible {
            return key
        }
        if let main = NSApp.mainWindow, main !== panel, main.isVisible {
            return main
        }
        return nil
    }
}
