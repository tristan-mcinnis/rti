import AppKit

/// Explicit user navigation activates the running process. An asynchronous
/// LaunchServices reopen could restore a window the user has since minimized.
@MainActor
enum RTIActivation {
    static func bringToFront(_ window: NSWindow) {
        activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    static func activateApp() {
        NSApp.activate()
    }
}
