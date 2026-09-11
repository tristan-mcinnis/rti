import AppKit
import SwiftUI

/// The one way to open Settings on a pane: its own window with the house
/// settings shell (`SettingsView`, `Layout.settingsWidth` ×
/// `settingsHeight`, a 220 pt rail).
///
/// A normal titled window, as Quick Launch's Settings: the title bar shows
/// "RTI Settings", the frame is kept between launches, and `esc` (with an
/// empty search) or `⌘W` closes it. Closing only hides it; the next `show`
/// brings the same window back on the asked pane.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    static let autosaveName = "rti.settings"
    static let standardSize = NSSize(width: House.Layout.settingsWidth, height: House.Layout.settingsHeight)

    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    /// Open Settings on `pane`, or bring the open window forward and switch
    /// it to `pane`.
    func show(pane: SettingsView.SettingsTab = .providers) {
        navigation.pane = pane
        navigation.query = ""
        let window = window ?? makeWindow()
        RTIActivation.bringToFront(window)
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.standardSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RTI Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.standardSize
        window.backgroundColor = House.NSColorToken.surface

        let hosting = NSHostingController(rootView: SettingsView(
            onClose: { [weak self] in self?.close() },
            navigation: navigation
        ))
        // The window sizes the view: the frame is the user's (autosaved),
        // from the minimum up.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.standardSize)

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        // A frame saved smaller than today's minimum, or off every screen,
        // comes back at the standard size, centred.
        let content = window.contentRect(forFrameRect: window.frame).size
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if content.width < Self.standardSize.width || content.height < Self.standardSize.height || !onScreen {
            window.setContentSize(Self.standardSize)
            window.center()
        }

        self.window = window
        return window
    }
}
