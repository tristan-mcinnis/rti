import AppKit
import SwiftUI

@MainActor
final class SessionHistoryWindowController: ObservableObject {
    private var window: NSWindow?

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Session History"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.sessionhistory")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 400)
        w.backgroundColor = NSColor(calibratedRed: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        // Match SessionDetailWindowController: force aqua because the design
        // tokens were built for a light surface.
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: SessionHistoryView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
