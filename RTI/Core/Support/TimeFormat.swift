import Foundation

/// Shared time-formatting utilities so transcript timestamps and elapsed
/// durations render identically everywhere. In RTICore so the control
/// socket's status readout renders the same way the menu bar does.
public enum TimeFormat {

    /// `M:SS` or `H:MM:SS` — used for live-duration displays and transcript
    /// timestamps in the debug console.
    public static func elapsedMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// `M:SS` only — compact transcript timestamp (no hour support needed
    /// for the typical sub-hour session).
    public static func stampMs(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// `H:MM:SS` / `M:SS` variant that takes a `TimeInterval` (seconds).
    public static func elapsed(_ interval: TimeInterval) -> String {
        elapsedMs(Int(interval * 1000))
    }

    /// Human-readable duration string: `"Xm Xs"` or `"Xs"`.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let mins = total / 60
        let secs = total % 60
        if mins > 0 { return "\(mins)m \(secs)s" }
        return "\(secs)s"
    }
}
