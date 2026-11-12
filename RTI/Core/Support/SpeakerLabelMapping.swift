import Foundation

/// Single source of truth for mapping Soniox speaker indices + channels to
/// raw speaker label strings (`"self"`, `"room_1"`, `"remote_1"`, …).
public enum SpeakerLabelMapping {

    /// Live capture knows the audio leg. Only the system socket requests clusters.
    public static func rawLabel(speaker: Int, channel: String) -> String {
        guard channel == "system" else { return "self" }
        return speaker > 0 ? "remote_\(speaker)" : "remote"
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
        if key == "remote" { return "Them" }
        if let n = numericSuffix(of: key, afterPrefix: "room_") { return "Room speaker \(n)" }
        if let n = numericSuffix(of: key, afterPrefix: "remote_") { return "Remote speaker \(n)" }
        if let n = numericSuffix(of: key, afterPrefix: "them_") { return "Speaker \(n)" }
        return nil
    }

    /// The raw speaker id behind a display label (the inverse of
    /// `displayLabel(forRawKey:)`), or nil for a name or any other text. The
    /// Sessions browser uses it to give an archived speaker the dot colour
    /// the live transcript gave them.
    public static func rawKey(forDisplayLabel label: String) -> String? {
        if label == "You" || label == "Me" { return "self" }
        if label == "Them" || label == "Remote speaker" { return "remote" }
        for (prefix, raw) in [("Room speaker ", "room_"), ("Remote speaker ", "remote_"), ("Speaker ", "them_")] {
            if let n = numericSuffix(of: label, afterPrefix: prefix), n >= 1 { return "\(raw)\(n)" }
        }
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


/// A leg is observed by RTI. A numbered cluster is a provider hypothesis.
public enum SpeakerEvidence: String, Codable, Sendable {
    case legOnly
    case unverified
    case confirmed

    public static func leg(for speakerID: String) -> String {
        switch speakerID {
        case "note": return "Note"
        case "self", "Me", "You": return "Me"
        default: return speakerID.hasPrefix("room_") || speakerID.hasPrefix("Room speaker ") ? "Me" : "Them"
        }
    }

    public static func resolve(speakerID: String, named: Bool) -> Self {
        if speakerID == "remote" || speakerID == "Them" || speakerID == "Remote speaker" || speakerID == "note" {
            return .legOnly
        }
        if named { return .confirmed }
        return speakerID == "self" || speakerID == "You" || speakerID == "Me" ? .legOnly : .unverified
    }
}

public struct SessionSpeakerPolicy: Codable, Equatable, Sendable {
    public var labelsEnabled: Bool
    /// A local review hint. It never creates a speaker or verifies a name.
    public var expectedCount: Int?

    public init(labelsEnabled: Bool = true, expectedCount: Int? = nil) {
        self.labelsEnabled = labelsEnabled
        self.expectedCount = expectedCount.flatMap { $0 > 0 ? $0 : nil }
    }
}
