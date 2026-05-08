import AppKit
import SwiftUI

@MainActor
final class TopWidgetWindowController {
    private let window: NSPanel

    /// Pill height (28) + outer 4pt padding ⨉ 2.
    static let pillHeight: CGFloat = 36
    static let chatGap: CGFloat = 6

    init(onOpenChat: @escaping () -> Void, onOpenSessionHome: @escaping () -> Void) {
        // Width is generous enough that the wider idle state ("Record" + Smart
        // badge) fits without truncation. The pill is right-anchored within
        // the panel via a leading Spacer so the visual position stays glued
        // to the screen edge regardless of state.
        let size = NSSize(width: 180, height: Self.pillHeight)
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

        panel.contentView = NSHostingView(rootView: TopWidgetView(
            onOpenChat: onOpenChat,
            onOpenSessionHome: onOpenSessionHome
        ))

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
