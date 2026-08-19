import Foundation

/// Single source of truth for mapping Soniox speaker IDs (`self`, `room_1`,
/// `remote_1`, legacy `them_1`, …) to human-readable default labels. Callers
/// that want a live rename applied (the transcript chip, the archived
/// transcript) check `SpeakerNameStore` first and fall back to this.
enum SpeakerLabels {
    static func displayName(for raw: String) -> String {
        switch raw {
        case "self": return "You"
        case "note": return "Note"
        case let other where other.hasPrefix("room_"):
            return "Room speaker \(other.dropFirst("room_".count))"
        case let other where other.hasPrefix("remote_"):
            return "Remote speaker \(other.dropFirst("remote_".count))"
        case let other where other.hasPrefix("them_"):
            return "Speaker \(other.dropFirst("them_".count))"
        default:
            return raw.capitalized
        }
    }

    static func isNote(_ raw: String) -> Bool { raw == "note" }
}
