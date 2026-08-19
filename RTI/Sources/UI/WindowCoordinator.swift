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

    var overlayIsVisible: Bool { overlayController?.isVisible ?? false }

    func install() {
        let controller = OverlayWindowController()
        overlayController = controller
        controller.show(initialLaunch: true)
    }

    func setSharingInvisible(_ invisible: Bool) {
        overlayController?.setSharingInvisible(invisible)
    }

    // MARK: - Overlay

    func showOverlay() { overlayController?.show() }
    func hideOverlay() { overlayController?.hide() }
    func toggleOverlay() { overlayController?.toggle() }
}
