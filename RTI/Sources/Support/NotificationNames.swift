import AppKit
import Foundation

extension Notification.Name {
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    /// Posted when the light/dark setting flips so the live panel re-applies its
    /// NSAppearance immediately.
    static let rtiOverlayAppearanceChanged = Notification.Name("rti.overlayAppearanceChanged")
    static let rtiShowLogs = Notification.Name("rti.showLogs")
    static let rtiSelectSessionsControlTab = Notification.Name("rti.selectSessionsControlTab")
    /// Posted (object = session folder name String) to focus the Sessions
    /// browser on a specific archived session — e.g. tapping the "summary
    /// ready" notification or the overlay's "Notes ready" control.
    static let rtiOpenSessionInBrowser = Notification.Name("rti.openSessionInBrowser")
    /// Posted when a session stops, so per-session UI state (e.g. an unsent
    /// draft in the composer) can reset before the next meeting.
    static let rtiSessionDidStop = Notification.Name("rti.sessionDidStop")
    /// Posted (object = OverlayTab rawValue String) to switch the overlay's
    /// active tab from a global hotkey or command.
    static let rtiSelectTab = Notification.Name("rti.selectTab")
    /// Posted (object = vault-relative path String, under `databases/`) to
    /// seed the overlay chat composer with an `@file` mention — e.g. the
    /// Sessions browser's "Ask about this session" action.
    static let rtiSeedChatMention = Notification.Name("rti.seedChatMention")
}
