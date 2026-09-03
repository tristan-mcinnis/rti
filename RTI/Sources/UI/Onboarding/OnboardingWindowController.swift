import AppKit
import SwiftUI

/// Owns the single NSWindow hosting `OnboardingView`. Shown on first run when
/// setup is incomplete; a normal (capturable) window, unlike the overlay.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to RTI"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = House.NSColorToken.surface
        w.appearance = OverlayAppearanceDefaults.nsAppearance()
        w.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in self?.window?.close() }))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
