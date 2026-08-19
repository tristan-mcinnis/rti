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
    private var recordingHUD: RecordingHUDWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        sessionsControl = SessionsControlWindowController()
        recordingHUD = RecordingHUDWindowController()

        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller
        controller.show(initialLaunch: true)
        recordingHUD?.sync(with: SessionCoordinator.shared.phase)

    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
        recordingHUD?.setSharingInvisible(invisible)
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

    func syncRecordingHUD() {
        recordingHUD?.sync(with: SessionCoordinator.shared.phase)
    }

    // MARK: - Library & Preferences

    func showSessionsControl(tab: SessionsControlView.Tab = .sessions) {
        sessionsControl?.show(tab: tab)
    }

    /// Open the Sessions browser focused on one archived session folder (e.g.
    /// from the "summary ready" notification or the overlay's "Notes ready"
    /// control). Shows the window on the Sessions tab, then tells the browser
    /// which folder to select. The post is deferred a tick so a freshly-created
    /// browser has mounted its observer before the selection lands.
    func showSession(folder: String) {
        showSessionsControl(tab: .sessions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .rtiOpenSessionInBrowser, object: folder)
        }
    }

    // MARK: - Convenience wrappers used by AppDelegate / menu

    func openSettings() { showSessionsControl(tab: .providers) }

    // MARK: - About

    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Real-time meeting intelligence.\nAudio is transcribed by Soniox; transcripts and prompts are answered by your configured LLM provider. Everything else stays on this Mac.\n\nhttps://github.com/tristan-mcinnis/rti",
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
