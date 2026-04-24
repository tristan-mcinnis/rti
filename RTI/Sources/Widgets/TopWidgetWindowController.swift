import AppKit
import SwiftUI

@MainActor
final class TopWidgetWindowController {
    private let window: NSPanel
    private let onHideToggle: () -> Void

    init(onHideToggle: @escaping () -> Void) {
        self.onHideToggle = onHideToggle

        let size = NSSize(width: 260, height: 54)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 8
        )
        let frame = NSRect(origin: origin, size: size)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView: TopWidgetView(onHideToggle: onHideToggle))

        self.window = panel
    }

    func show() {
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func toggle() {
        if window.isVisible { hide() } else { show() }
    }
}
