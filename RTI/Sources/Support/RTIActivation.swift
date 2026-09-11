// Copied from quick-launch@8ee19aa Sources/App/AppActivation.swift (bringToFront only)
import AppKit

/// Brings RTI to the front for one of its windows.
///
/// macOS lets an app activate itself only when it is already active, so a
/// plain request can leave typing going to the app behind (for example after
/// the global show/hide key from another app). When `NSApp.activate()` is
/// not enough, this asks LaunchServices to open RTI's own bundle, which the
/// system honours the same way as `open -a`.
///
/// RTI is always a regular Dock app, so Quick Launch's activation-policy
/// switching (`becomeRegularApp`, `settleAfterClosing`) is not ported. Use
/// this in place of the deprecated `NSApp.activate(ignoringOtherApps:)`.
@MainActor
enum RTIActivation {
    /// Order `window` front, make it key, and make RTI the active app.
    static func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }

    /// Make RTI the active app when there is no window of its own to order
    /// front (the About panel, a notification tap before a window opens).
    static func activateApp() {
        NSApp.activate()
        guard !NSApp.isActive else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
