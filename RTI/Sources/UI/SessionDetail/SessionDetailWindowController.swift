import AppKit
import SwiftUI

@MainActor
final class SessionDetailWindowController: ObservableObject {
    private var window: NSWindow?
    private var sessionId: String?

    func show(for sessionId: String) {
        self.sessionId = sessionId
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Session"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.sessiondetail")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)
        w.backgroundColor = NSColor(calibratedRed: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        // RTIDesign tokens are calibrated for light mode (textPrimary near
        // black on textBackground near white). Force aqua so dark-mode users
        // don't end up with invisible dark text on dark List rows.
        w.appearance = NSAppearance(named: .aqua)
        let view = SessionDetailView(sessionId: sessionId)
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
