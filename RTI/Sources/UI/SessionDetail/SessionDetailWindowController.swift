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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Session Detail"
        w.setFrameAutosaveName("rti.sessiondetail")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 360)
        let view = SessionDetailView(sessionId: sessionId)
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
