import AppKit
import SwiftUI

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    /// App-wide singleton so panel views, hotkeys, and stores can drive
    /// window state without threading a coordinator reference through every
    /// init. AppDelegate still calls `install` once at launch.
    static let shared = WindowCoordinator()

    private var overlayController: OverlayWindowController?
    private var sessionsControl: SessionsControlWindowController?
    private let sessionsWindow = SessionsWindowController()
    private var meetingBrief: MeetingBriefWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        sessionsControl = SessionsControlWindowController()
        meetingBrief = MeetingBriefWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller
        controller.show(initialLaunch: true)

    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
    }

    /// Toggle the persisted invisibility flag and apply it to every panel.
    func toggleInvisibility() {
        let key = OverlayAppearanceDefaults.invisibilityKey
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        let next = !current
        UserDefaults.standard.set(next, forKey: key)
        setSharingInvisible(next)
    }

    // MARK: - Overlay

    func showOverlay() { overlayController?.show() }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }

    // MARK: - Sessions and Preferences

    /// `.sessions` opens the Sessions window; every other tab opens the
    /// Preferences window on that pane (until the settings shell replaces it).
    func showSessionsControl(tab: SessionsControlView.Tab = .sessions) {
        if tab == .sessions {
            showSessions()
        } else {
            sessionsControl?.show(tab: tab)
        }
    }

    /// The Sessions window, on the last session it showed.
    func showSessions() {
        sessionsWindow.show()
    }

    /// Open the Sessions window on one archived session folder, with the
    /// list hidden (the "summary ready" notification, the overlay's "Notes
    /// ready" control).
    func showSession(folder: String) {
        sessionsWindow.show(folder: folder)
    }

    /// Open the read-only pre-meeting brief browser (Hermes-authored briefs).
    func showMeetingBrief() {
        meetingBrief?.show()
    }

    // MARK: - Convenience wrappers used by AppDelegate / menu

    func openSettings() { SettingsWindowController.shared.show() }

    // MARK: - About

    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Real-time meeting intelligence.\nAudio is transcribed by Soniox; transcripts and prompts are answered by your configured LLM provider. Everything else stays on this Mac.\n\nhttps://github.com/tristan-mcinnis/rti",
            attributes: [
                .foregroundColor: House.NSColorToken.textSecondary,
                .font: NSFont.systemFont(ofSize: House.TypeToken.Size.caption)
            ]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Tristan McInnis"
        ]
        RTIActivation.activateApp()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
