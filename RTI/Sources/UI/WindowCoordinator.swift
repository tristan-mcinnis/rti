import AppKit
import SwiftUI
import HouseDesign
import RTICore

/// Owns every window in the app. Centralises presentation policy so
/// AppDelegate doesn't need to know about `NSWindow` or `NSHostingView`.
@MainActor
final class WindowCoordinator {
    /// App-wide singleton so panel views, hotkeys, and stores can drive
    /// window state without threading a coordinator reference through every
    /// init. AppDelegate still calls `install` once at launch.
    static let shared = WindowCoordinator()

    private var overlayController: OverlayWindowController?

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }

    func install(onOpenSettings: @Sendable @escaping () -> Void) {
        let controller = OverlayWindowController(onOpenSettings: onOpenSettings)
        overlayController = controller
        controller.show(initialLaunch: true)

    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.sharingType = invisible ? .none : .readOnly
        }
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

    func showOverlay() {
        WorkspaceModel.shared.select(.live)
        overlayController?.show()
    }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }

    // MARK: - Sessions and Preferences

    /// Compatibility callers use the same main workspace and settings shell.
    func showSessionsControl(tab: SessionsControlView.Tab = .sessions) {
        if tab == .sessions {
            showSessions()
        } else if let pane = SettingsView.SettingsTab(rawValue: tab.rawValue.lowercased()) {
            openSettings(pane: pane)
        }
    }

    func showSessions() {
        WorkspaceModel.shared.showSession()
        overlayController?.show()
    }

    func showSession(folder: String) {
        WorkspaceModel.shared.showSession(folder: folder)
        overlayController?.show()
    }

    /// Open the read-only pre-meeting brief browser (Hermes-authored briefs).
    func showMeetingBrief(brief: URL? = nil) {
        WorkspaceModel.shared.showBrief(brief)
        overlayController?.show()
    }

    // MARK: - Convenience wrappers used by AppDelegate / menu

    func openSettings(pane: SettingsView.SettingsTab = .providers) {
        WorkspaceModel.shared.showSettings(pane)
        overlayController?.show()
    }

    // MARK: - About

    func showAbout() { openSettings(pane: .about) }

}

extension NSWindow {
    /// Apply the persisted invisibility setting (default on) to a window at
    /// creation, so Settings, Preferences, Brief and Onboarding are excluded
    /// from screen capture like the overlay.
    func applyRTISharingPolicy() {
        let invisible = UserDefaults.standard.object(forKey: OverlayAppearanceDefaults.invisibilityKey) as? Bool ?? true
        sharingType = invisible ? .none : .readOnly
    }
}
