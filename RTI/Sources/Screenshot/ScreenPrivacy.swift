import Foundation

/// Apps whose windows must never appear in RTI's screen captures. Enforced at
/// the ScreenCaptureKit content filter (the single choke point every capture
/// path shares — ambient trail, manual attach, and the chat's capture tool),
/// so an excluded app's windows are simply absent from the captured image:
/// no pixels, no OCR text, no frames, nothing downstream in notes, summaries,
/// the sidecar, or the vault meeting note.
///
/// Rationale (2026-08-30): captures are per-display, not per-window. Chatting
/// in WeChat during a meeting — or a 1Password window or notification banner
/// merely being visible — would otherwise OCR personal content straight into
/// the meeting record.
enum ScreenPrivacy {
    static let excludedAppsKey = "screenPrivacy.excludedBundleIds"

    /// Password managers, personal chat apps, and notification banners.
    static let defaultExcludedBundleIds: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.MobileSMS",           // Messages
        "com.apple.notificationcenterui", // banners leak whatever just arrived
        "com.tencent.xinWeChat",          // WeChat
        "com.tencent.WeWorkMac",          // WeCom
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
    ]

    /// The active exclusion list. Defaults apply until the user edits the
    /// list in Settings › General; an explicitly emptied list is respected.
    static var excludedBundleIds: [String] {
        get {
            UserDefaults.standard.array(forKey: excludedAppsKey) as? [String]
                ?? defaultExcludedBundleIds
        }
        set {
            UserDefaults.standard.set(newValue, forKey: excludedAppsKey)
        }
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: excludedAppsKey)
    }

    static func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedBundleIds.contains(bundleIdentifier)
    }
}
