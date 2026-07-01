import AppKit
import SwiftUI

/// Owns the single NSWindow that hosts the tabbed SessionsControlView,
/// replacing the five separate windows (Live Transcript, Session History,
/// Session Detail, Settings, Logs).
@MainActor
final class SessionsControlWindowController {
    private var window: NSWindow?

    func show(tab: SessionsControlView.Tab = .liveTranscript) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Notify the existing view to switch tabs.
            NotificationCenter.default.post(name: .rtiSelectSessionsControlTab, object: tab)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "RTI Sessions Control"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.sessionscontrol")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)
        w.backgroundColor = NSColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        w.appearance = NSAppearance(named: .aqua)
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
