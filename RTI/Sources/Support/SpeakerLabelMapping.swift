import Foundation

/// Single source of truth for mapping Soniox speaker indices + channels to
/// raw speaker label strings (`"self"`, `"them"`, `"them_1"`, …).
enum SpeakerLabelMapping {

    /// Map a Soniox speaker index + channel to a raw label string.
    /// - mic channel: always returns `"self"` (the user's own voice)
    /// - system channel: `"them"` for speaker 0, `"them_N"` for others
    static func rawLabel(speaker: Int, channel: String) -> String {
        switch channel {
        case "system":
            return speaker == 0 ? "them" : "them_\(speaker)"
        default:
            return "self"
        }
    }

    /// Map a Soniox speaker index (no channel info — file mode / mic mode)
    /// to a raw label string. Speaker 0 is "self"; others are "them_N".
    static func rawLabel(speaker: Int) -> String {
        speaker == 0 ? "self" : "them_\(speaker)"
    }
}
