import AppKit
import SwiftUI

/// Owns the single NSWindow hosting `MeetingBriefView`. Mirrors
/// `SessionsControlWindowController`'s presentation policy.
@MainActor
final class MeetingBriefWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
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
        w.title = "Meeting Brief"
        w.titlebarAppearsTransparent = true
        w.setFrameAutosaveName("rti.meetingbrief")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 420)
        w.backgroundColor = NSColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: MeetingBriefView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
