import Foundation

/// Pure rules for the overlay's non-fatal notice banners.
public enum MuteBannerRule {
    /// The mute banner shows only for an in-call mute while a recording is
    /// live. The Listening-only preset is a choice, not a warning: no banner.
    public static func shows(isRunning: Bool, mic: MicControl) -> Bool { isRunning && mic.bannerVisible }
}

/// Which shortcut-failure message to show, given the failed titles and the
/// signature the user last dismissed. Empty list or a dismissed identical
/// list yields nil.
public enum HotkeyNoticeRule {
    public static func signature(_ titles: [String]) -> String { titles.sorted().joined(separator: "|") }

    public static func message(failedTitles: [String], dismissedSignature: String) -> String? {
        guard !failedTitles.isEmpty, signature(failedTitles) != dismissedSignature else { return nil }
        return "These shortcuts are unavailable, another app may use them: \(failedTitles.joined(separator: ", "))."
    }
}
