import RTICore
import SwiftUI

/// Maps Soniox speaker IDs (`self`, `room_1`, `remote_1`, legacy `them_1`, …)
/// to the live labels (`LiveTranscriptPresentation.label`) and stable
/// per-speaker colours used across the live analysis surfaces.
enum SpeakerLabels {
    /// The label the live Transcript tab shows for a speaker id, the user's
    /// live names included, so other tabs name speakers the same way.
    @MainActor
    static func displayName(for raw: String) -> String {
        let label = LiveTranscriptPresentation.label(for: raw, names: SpeakerNameStore.shared.names)
        return label == raw ? raw.capitalized : label
    }

    static func chipColor(for raw: String) -> Color {
        // Notes are not a speaker; they take the warning token, not a raw hue.
        if raw == "note" { return RTIDesign.Color.warning }
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
