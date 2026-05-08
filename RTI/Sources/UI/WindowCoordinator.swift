import AppKit
import SwiftUI

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    private var overlayController: OverlayWindowController?
    private var topWidget: TopWidgetWindowController?
    private var sessionsControl: SessionsControlWindowController?
    private var onboarding: OnboardingWindowController?
    private var shortcutsController: ShortcutsWindowController?
    private var commandPalette: CommandPaletteWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }
    var topWidgetIsVisible: Bool { topWidget?.isVisible ?? false }

    func install(onOpenSettings: @escaping () -> Void) {
        shortcutsController = ShortcutsWindowController()
        sessionsControl = SessionsControlWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        controller.show()
        overlayController = controller

        let top = TopWidgetWindowController(
            onOpenChat: { [weak self] in self?.positionOverlayBelowWidget() },
            onOpenSessionHome: { [weak self] in self?.showSessionsControl(tab: .sessions) }
        )
        top.show()
        topWidget = top

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

    // MARK: - Sessions Control (unified: Live Transcript, Sessions, Settings, Logs)

    func showSessionsControl(tab: SessionsControlView.Tab = .liveTranscript) {
        sessionsControl?.show(tab: tab)
    }

    func showSessionInSessionsControl(id: String) {
        sessionsControl?.show(sessionId: id)
    }

    // MARK: - Legacy convenience wrappers used by AppDelegate / menu

    func showDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func toggleDebugConsole() { showSessionsControl(tab: .liveTranscript) }
    func openSettings() { showSessionsControl(tab: .settings) }
    func showSessionHistory() { showSessionsControl(tab: .sessions) }
    func openSessionDetail(for id: String) { showSessionInSessionsControl(id: id) }

    // MARK: - Shortcuts

    func showShortcuts() { shortcutsController?.show() }

    // MARK: - Command Palette

    func toggleCommandPalette() { commandPalette?.toggle() }

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
