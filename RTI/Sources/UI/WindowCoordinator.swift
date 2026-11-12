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

    func toggleInvisibility() {
        let next = !OverlayAppearanceDefaults.hidesWindowsFromScreenCapture()
        UserDefaults.standard.set(next, forKey: OverlayAppearanceDefaults.invisibilityKey)
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.applyRTISharingPolicy()
        }
    }

    // MARK: - Overlay

    func showWorkspace() {
        overlayController?.show()
    }

    func showOverlay() {
        WorkspaceModel.shared.select(.live)
        overlayController?.show()
    }
    func toggleOverlay() { overlayController?.toggle() }

    // MARK: - Sessions and Preferences

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
    func configureRTITitledWindow(defaults: UserDefaults = .standard) {
        level = .normal
        isOpaque = true
        applyRTISharingPolicy(defaults: defaults)
    }

    /// Refresh only sharing when the user toggles capture visibility or reopens a window.
    func applyRTISharingPolicy(defaults: UserDefaults = .standard) {
        sharingType = OverlayAppearanceDefaults.hidesWindowsFromScreenCapture(in: defaults) ? .none : .readOnly
    }
}
