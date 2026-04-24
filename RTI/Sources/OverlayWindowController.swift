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

    init() {
        let size = NSSize(width: 658, height: 555)
        let margin: CGFloat = 24
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.minX + margin,
            y: screenFrame.maxY - size.height - margin
        )
        let frame = NSRect(origin: origin, size: size)

        let panel = KeyableOverlayPanel(
            contentRect: frame,
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
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView: OverlayPanelView())

        self.window = panel
    }

    func show() {
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func toggle() {
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }
}
