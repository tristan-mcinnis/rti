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

    /// Display label for a raw speaker key (`self`, `room_1`, `remote_2`,
    /// legacy `them_N`), or nil when the key is not a raw speaker id (already
    /// a display label, "note", …). Must stay in lockstep with the transcript
    /// renderers: these are the exact strings archived transcripts print, and
    /// `speaker-names.json` is keyed by them.
    public static func displayLabel(forRawKey key: String) -> String? {
        if key == "self" { return "You" }
        if let n = numericSuffix(of: key, afterPrefix: "room_") { return "Room speaker \(n)" }
        if let n = numericSuffix(of: key, afterPrefix: "remote_") { return "Remote speaker \(n)" }
        if let n = numericSuffix(of: key, afterPrefix: "them_") { return "Speaker \(n)" }
        return nil
    }

    /// Re-key a speaker-name map onto display labels for serialization.
    /// Raw ids become their display labels; keys that are already display
    /// labels pass through. `self` is dropped: "You" as a substitution key
    /// would rewrite ordinary prose, and the mic wearer needs no rename to
    /// be identified.
    public static func displayKeyedNames(_ names: [String: String]) -> [String: String] {
        names.reduce(into: [String: String]()) { out, pair in
            if pair.key == "self" { return }
            out[displayLabel(forRawKey: pair.key) ?? pair.key] = pair.value
        }
    }

    /// Speaker labels present in an archived transcript's text, deduped and
    /// ordered mic speakers first ("Speaker N"), then "Room speaker N", then
    /// "Remote speaker N". This is what the post-hoc rename UI lists.
    public static func archivedSpeakerLabels(in text: String) -> [String] {
        let pattern = #"(?:Remote speaker|Room speaker|Speaker) [0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let labels = Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
        func rank(_ label: String) -> Int {
            if label.hasPrefix("Remote") { return 2 }
            if label.hasPrefix("Room") { return 1 }
            return 0
        }
        func number(_ label: String) -> Int {
            Int(label.components(separatedBy: " ").last ?? "") ?? 0
        }
        return labels.sorted { (rank($0), number($0)) < (rank($1), number($1)) }
    }

    private static func numericSuffix(of key: String, afterPrefix prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }
}
