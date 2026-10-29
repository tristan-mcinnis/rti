import Foundation

public extension Notification.Name {
    public static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    public static let rtiClearChat = Notification.Name("rti.clearChat")
    /// Object is the saved chat ID. Missing or damaged threads are reported,
    /// never silently replaced with a new conversation.
    public static let rtiResumeChat = Notification.Name("rtiResumeChat")
    public static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    public static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    /// Posted when the light/dark setting flips so the live panel re-applies its
    /// NSAppearance immediately.
    public static let rtiOverlayAppearanceChanged = Notification.Name("rti.overlayAppearanceChanged")
    public static let rtiShowLogs = Notification.Name("rti.showLogs")
    public static let rtiSelectSessionsControlTab = Notification.Name("rti.selectSessionsControlTab")
    /// Posted (object = session folder name String) to focus the Sessions
    /// browser on a specific archived session.
    public static let rtiOpenSessionInBrowser = Notification.Name("rti.openSessionInBrowser")
    /// Posted when a session stops, so per-session UI state (e.g. an unsent
    /// draft in the composer) can reset before the next meeting.
    public static let rtiSessionDidStop = Notification.Name("rti.sessionDidStop")
    /// Posted (object = OverlayTab rawValue String) to switch the overlay's
    /// active tab from a global hotkey or command.
    public static let rtiSelectTab = Notification.Name("rti.selectTab")
    /// Posted (object = vault-relative path String, under `databases/`) to
    /// seed the overlay chat composer with an `@file` mention — e.g. the
    /// Sessions browser's "Ask about this session" action.
    public static let rtiSeedChatMention = Notification.Name("rti.seedChatMention")
}
