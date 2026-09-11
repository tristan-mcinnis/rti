import AppKit
import SwiftUI

/// Owns the single window hosting `OnboardingView`. Shown on first run when
/// setup is incomplete; a normal (capturable) window, unlike the RTI window.
/// The title bar is transparent and its title hidden, so the welcome reads
/// as one card.
@MainActor
final class OnboardingWindowController {
    /// The RTI answer measure wide; tall enough for the welcome, both
    /// setup cards, and Get Started on a 13-inch display.
    static let size = NSSize(
        width: House.Layout.answerMaxWidth,
        height: House.Layout.settingsHeight + House.Layout.settingsRail
    )

    private var window: NSWindow?

    func show() {
        if let window {
            RTIActivation.bringToFront(window)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to RTI"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.backgroundColor = House.NSColorToken.surface
        let hosting = NSHostingController(rootView: OnboardingView(onDone: { [weak self] in self?.window?.close() }))
        hosting.sizingOptions = []
        w.contentViewController = hosting
        w.setContentSize(Self.size)
        // A short screen gets a shorter window; the setup cards scroll.
        if let visible = NSScreen.main?.visibleFrame, visible.height < w.frame.height {
            w.setContentSize(NSSize(width: Self.size.width, height: visible.height - House.Spacing.xxxl))
        }
        w.center()
        window = w
        RTIActivation.bringToFront(w)
    }
}
