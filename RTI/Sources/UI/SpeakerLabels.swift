import SwiftUI

/// Single source of truth for mapping Soniox speaker IDs (`self`, `them_1`, …)
/// to human-readable labels and stable per-speaker chip colors.
///
/// Used by `SessionDetailView` (transcript tab) and `DebugConsoleView` (live
/// transcript) so the label format never drifts between them.
enum SpeakerLabels {

    /// Convert a raw speaker ID to a display label.
    /// - `self` → "You"
    /// - `note` → "Note"
    /// - `them_1`, `them_2`, … → "Speaker 1", "Speaker 2", …
    /// - anything else → passthrough capitalized
    static func displayName(for raw: String) -> String {
        switch raw {
        case "self": return "You"
        case "note": return "Note"
        case let other where other.hasPrefix("them_"):
            let n = String(other.dropFirst("them_".count))
            return "Speaker \(n)"
        default:
            return raw.capitalized
        }
    }

    /// Stable chip color per speaker. Uses the trailing digit of `them_N` to
    /// index into the palette so Speaker 1 always gets the same color.
    static func chipColor(for raw: String) -> Color {
        if raw == "note" {
            return .orange
        }
        if raw == "self" {
            return RTIDesign.Color.speakerPalette[0]
        }
        if raw.hasPrefix("them_"),
           let n = Int(raw.dropFirst("them_".count)),
           n >= 1 {
            // Reserve index 0 for "self"; them_1 → palette[1], them_2 → palette[2]…
            let palette = RTIDesign.Color.speakerPalette
            let paletteCount = palette.count
            guard paletteCount > 1 else { return palette[0] }
            return palette[((n - 1) % (paletteCount - 1)) + 1]
        }
        return RTIDesign.Color.textSecondary
    }

    /// `true` for the orange-tinted "Note" branch — callers may want italic +
    /// note icon styling for these rows.
    static func isNote(_ raw: String) -> Bool {
        raw == "note"
    }
}
