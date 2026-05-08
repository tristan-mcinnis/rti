import AppKit
import SwiftUI

@MainActor
final class TopWidgetWindowController {
    private let window: NSPanel

    static let pillHeight: CGFloat = 36 + 8 // content + padding
    static let chatGap: CGFloat = 6

    init() {
        let size = NSSize(width: 140, height: Self.pillHeight)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        panel.contentView = NSHostingView(rootView: TopWidgetView())

        self.window = panel
        positionOnActiveScreen()
    }

    var windowFrame: NSRect { window.frame }

    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visible.maxX - window.frame.width - 15,
            y: visible.maxY - window.frame.height - 12
        )
        window.setFrameOrigin(origin)
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
        if window.isVisible { hide() } else { show() }
    }

    var isVisible: Bool { window.isVisible }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }
}
