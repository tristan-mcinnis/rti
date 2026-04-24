import AppKit
import SwiftUI

@MainActor
final class DebugConsoleWindowController {
    private var window: NSWindow?

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 800)
        let w = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "RTI Debug — Transcript"
        w.setFrameAutosaveName("rti.debugConsole")
        w.contentView = NSHostingView(rootView: DebugConsoleView().environmentObject(SessionCoordinator.shared))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
