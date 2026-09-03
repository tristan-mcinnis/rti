import AppKit
import SwiftUI

/// Owns the Library & Preferences window: completed meetings, durable
/// configuration, and diagnostics. The live meeting belongs in the overlay.
@MainActor
final class SessionsControlWindowController {
    private var window: NSWindow?

    func show(tab: SessionsControlView.Tab = .sessions) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Notify the existing view to switch tabs.
            NotificationCenter.default.post(name: .rtiSelectSessionsControlTab, object: tab)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "RTI Library & Preferences"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.sessionscontrol")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 860, height: 560)
        w.backgroundColor = House.NSColorToken.surface
        w.appearance = OverlayAppearanceDefaults.nsAppearance()
        w.contentView = NSHostingView(rootView: SessionsControlView(initialTab: tab))
        w.center()
        keepWindowVisible(w)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            self.keepWindowVisible(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func keepWindowVisible(_ window: NSWindow) {
        let currentFrame = window.frame
        if NSScreen.screens.contains(where: { screen in
            screen.visibleFrame.intersects(currentFrame)
        }) {
            return
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        guard let visibleFrame else { return }

        let x = visibleFrame.midX - currentFrame.width / 2
        let y = visibleFrame.midY - currentFrame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
