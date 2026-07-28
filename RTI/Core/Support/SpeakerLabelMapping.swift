import Foundation

/// Single source of truth for mapping Soniox speaker indices + channels to
/// raw speaker label strings (`"self"`, `"room_1"`, `"remote_1"`, …).
public enum SpeakerLabelMapping {

    /// Map a Soniox speaker index + channel to a raw label string.
    /// - mic channel: speaker 1 (first identified voice, typically the user
    ///   wearing the mic) → `"self"`; additional speakers → `"room_N"`. A
    ///   missing diarization label (speaker 0) also falls back to `"self"`.
    /// - system channel: `"remote_N"` for every diarized speaker. Its speaker 0
    ///   is unrelated to mic speaker 0, so it must not share any mic label.
    ///
    /// Why the mic branch isn't hard-coded to "self": Soniox diarization fires
    /// on the mic stream too, so in-person meetings or speakerphone calls
    /// surface multiple speakers on the same physical input. Collapsing them
    /// all to "self" loses that signal.
    public static func rawLabel(speaker: Int, channel: String) -> String {
        switch channel {
        case "system":
            return "remote_\(speaker + 1)"
        default:
            if speaker <= 1 { return "self" }
            return "room_\(speaker - 1)"
        }
    }

    /// Map a Soniox speaker index (no channel info — file mode / mic mode)
    /// to a raw label string. Speaker 0 is "self"; others are "them_N".
    public static func rawLabel(speaker: Int) -> String {
        speaker == 0 ? "self" : "them_\(speaker)"
    }
}
