import AppKit
import SwiftUI

@MainActor
final class TopWidgetWindowController {
    private let window: NSPanel

    /// Pill height (28) + outer 4pt padding ⨉ 2.
    static let pillHeight: CGFloat = 36
    static let chatGap: CGFloat = 6

    /// Bag of actions the right-click menu fires. Plumbed in from
    /// `WindowCoordinator` so the view layer doesn't reach into singletons
    /// for window/screen operations.
    struct Actions {
        let onOpenChat: () -> Void
        let onOpenSessionHome: () -> Void
        let onToggleOverlay: () -> Void
        let onCaptureScreen: () -> Void
        let onToggleInvisibility: () -> Void
        let onOpenSettings: () -> Void
        let onQuit: () -> Void
    }

    init(actions: Actions) {
        // Width is generous enough that the wider idle state ("Record" + Smart
        // badge) fits without truncation. The pill is right-anchored within
        // the panel via a leading Spacer so the visual position stays glued
        // to whichever frame edge the parent (or screen) provides.
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

        panel.contentView = NSHostingView(rootView: TopWidgetView(actions: actions))

        self.window = panel
    }

    /// The underlying NSWindow — handed to `OverlayWindowController.attachPill`
    /// so the pill becomes a child window of the overlay (tracks move +
    /// visibility automatically).
    var nsWindow: NSWindow { window }

    var windowFrame: NSRect { window.frame }

    var isVisible: Bool { window.isVisible }

    func setSharingInvisible(_ invisible: Bool) {
        window.sharingType = invisible ? .none : .readOnly
    }
}
