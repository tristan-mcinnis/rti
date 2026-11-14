import Foundation

public extension Notification.Name {
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    /// Object is the saved chat ID. Missing or damaged threads are reported,
    /// never silently replaced with a new conversation.
    static let rtiResumeChat = Notification.Name("rtiResumeChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    /// Posted when the light/dark setting flips so the live panel re-applies its
    /// NSAppearance immediately.
    static let rtiOverlayAppearanceChanged = Notification.Name("rti.overlayAppearanceChanged")
    /// Posted when a session stops, so per-session UI state (e.g. an unsent
    /// draft in the composer) can reset before the next meeting.
    static let rtiSessionDidStop = Notification.Name("rti.sessionDidStop")
    /// Posted (object = OverlayTab rawValue String) to switch the overlay's
    /// active tab from a global hotkey or command.
    static let rtiSelectTab = Notification.Name("rti.selectTab")
    /// RTI Lite: open the full guide in a sheet over the call.
    static let rtiLiteShowGuide = Notification.Name("rti.lite.showGuide")
    /// Posted (object = vault-relative path String, under `databases/`) to
    /// seed the overlay chat composer with an `@file` mention — e.g. the
    /// Sessions browser's "Ask about this session" action.
    static let rtiSeedChatMention = Notification.Name("rti.seedChatMention")
}
