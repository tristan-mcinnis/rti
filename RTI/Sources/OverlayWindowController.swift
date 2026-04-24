import AppKit
import SwiftUI

/// Non-activating panel that still accepts keyboard input when clicked,
/// so the text field works without activating RTI over the meeting app.
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayWindowController {
    private let window: NSPanel

    init(onOpenSettings: @escaping () -> Void = {}) {
        let panel = KeyableOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 658, height: 555),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        panel.contentView = NSHostingView(rootView: OverlayPanelView(onOpenSettings: onOpenSettings))

        self.window = panel
        positionOnActiveScreen()
    }

    /// Place the overlay on the screen containing the mouse cursor, sized to
    /// the left 60% of that screen's visible frame minus a margin at the top
    /// for the top widget. The right 40% is deliberately empty — no window
    /// there means click-through is free.
    func positionOnActiveScreen() {
        let screen = screenUnderMouse() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let widgetReserve: CGFloat = 72
        let margin: CGFloat = 16
        let width = max(420, visible.width * 0.6)
        let height = max(360, visible.height - widgetReserve - margin)
        let origin = NSPoint(
            x: visible.minX + margin,
            y: visible.maxY - widgetReserve - height
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    func show() {
        positionOnActiveScreen()
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
            window.alphaValue = 1
        })
    }

    func toggle() {
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }
}
