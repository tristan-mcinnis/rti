import AppKit
import SwiftUI

/// Owns the single NSWindow hosting `MinimalFirstRunCard`. Shown on first run
/// when the microphone permission (or API keys) aren't set up yet; a normal
/// (capturable) window, unlike the overlay. `onFinish` fires once the user
/// dismisses the card (mic granted) — the caller chains into the settings
/// sheet to collect keys.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(onFinish: @escaping () -> Void = {}) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to RTI"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MinimalFirstRunCard(onFinish: { [weak self] in
            self?.window?.close()
            onFinish()
        }))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
