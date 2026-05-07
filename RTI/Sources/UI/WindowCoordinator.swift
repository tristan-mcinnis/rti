import AppKit
import SwiftUI

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var debugConsole: DebugConsoleWindowController?
    private var settingsWindow: SettingsWindowController?
    private var sessionDetailWindow: NSWindow?
    private var sessionHistory: SessionHistoryWindowController?
    private var onboarding: OnboardingWindowController?
    private var shortcutsController: ShortcutsWindowController?
    private var commandPalette: CommandPaletteWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }
    var topWidgetIsVisible: Bool { topWidget?.isVisible ?? false }

    func install(onOpenSettings: @escaping () -> Void) {
        settingsWindow = SettingsWindowController()
        shortcutsController = ShortcutsWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        controller.show()
        overlayController = controller

        let top = TopWidgetWindowController(onTap: { [weak self] in
            guard let self, let overlay = self.overlayController else { return }
            if overlay.isVisible {
                overlay.hide()
            } else {
                overlay.showBelow(pillFrame: self.topWidget?.windowFrame ?? .zero)
            }
        })
        top.show()
        topWidget = top

        debugConsole = DebugConsoleWindowController()
        commandPalette = CommandPaletteWindowController()
    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
        topWidget?.setSharingInvisible(invisible)
    }

    // MARK: - Overlay

    func showOverlay() { overlayController?.show() }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }
    func positionOverlayBelowWidget() {
        guard let overlay = overlayController, let widget = topWidget else { return }
        overlay.showBelow(pillFrame: widget.windowFrame)
    }

    // MARK: - Top Widget

    func showTopWidget() { topWidget?.show() }
    func hideTopWidget() { topWidget?.hide() }
    func toggleTopWidget() { topWidget?.toggle() }

    // MARK: - Settings / Shortcuts

    func openSettings() { settingsWindow?.show() }
    func showShortcuts() { shortcutsController?.show() }

    // MARK: - Debug Console

    func showDebugConsole() { debugConsole?.show() }
    func toggleDebugConsole() { debugConsole?.toggle() }

    // MARK: - Command Palette

    func toggleCommandPalette() { commandPalette?.toggle() }

    // MARK: - Session Detail

    func openSessionDetail(for id: String) {
        if let window = sessionDetailWindow {
            window.contentView = NSHostingView(rootView: SessionDetailView(sessionId: id))
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
        w.backgroundColor = NSColor(red: 0.969, green: 0.969, blue: 0.973, alpha: 1)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: SessionDetailView(sessionId: id))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sessionDetailWindow = w
    }

    // MARK: - Session History

    func showSessionHistory() {
        if sessionHistory == nil {
            sessionHistory = SessionHistoryWindowController()
        }
        sessionHistory?.show()
    }

    // MARK: - Onboarding

    func showOnboardingIfNeeded() -> Bool {
        guard !OnboardingDefaults.hasCompleted else { return false }
        let controller = OnboardingWindowController()
        controller.showIfNeeded()
        onboarding = controller
        return true
    }

    // MARK: - About

    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Real-time meeting intelligence.\nAll session data stays on this Mac.\n\nhttps://github.com/tristan-mcinnis/rti",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Tristan McInnis"
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
