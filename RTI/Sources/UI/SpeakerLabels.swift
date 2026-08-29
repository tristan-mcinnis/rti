import RTICore
import SwiftUI

/// Single source of truth for mapping Soniox speaker IDs (`self`, `room_1`,
/// `remote_1`, legacy `them_1`, …) to human-readable labels and stable
/// per-speaker chip colors used across the live analysis surfaces.
enum SpeakerLabels {
    static func displayName(for raw: String) -> String {
        if raw == "note" { return "Note" }
        // Raw-id naming lives in RTICore (SpeakerLabelMapping) so the archive
        // layer keys speaker-names.json by the same strings the UI shows.
        if let mapped = SpeakerLabelMapping.displayLabel(forRawKey: raw) { return mapped }
        return raw.capitalized
    }

    static func chipColor(for raw: String) -> Color {
        if raw == "note" { return .orange }
        if raw == "self" { return RTIDesign.Color.speakerPalette[0] }

        let numbered = raw.hasPrefix("them_")
            ? raw.dropFirst("them_".count)
            : raw.hasPrefix("room_")
                ? raw.dropFirst("room_".count)
                : raw.hasPrefix("remote_")
                    ? raw.dropFirst("remote_".count)
                    : nil
        if let numbered, let n = Int(numbered), n >= 1 {
            let palette = RTIDesign.Color.speakerPalette
            guard palette.count > 1 else { return palette[0] }
            return palette[((n - 1) % (palette.count - 1)) + 1]
        }
        return RTIDesign.Color.textSecondary
    }

    static func isNote(_ raw: String) -> Bool { raw == "note" }
}
