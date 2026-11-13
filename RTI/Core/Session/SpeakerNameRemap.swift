import Foundation

/// Carries typed speaker names across a transcript upgrade.
///
/// The live transcript and the after-call file transcript number the other
/// side's voices on their own. "Remote speaker 1" in the upgrade can be a
/// different person from the live "Remote speaker 1" the user named, so
/// `speaker-names.json` put that name on the wrong voice (2026-11-12
/// replay). After an upgrade each named live speaker moves to the upgraded
/// speaker heard at the same times. A name without a clear match is dropped
/// from the upgraded map: no name is better than the wrong one. The live map
/// is kept beside it as `speaker-names.live.json`.
public enum SpeakerNameRemap {
    public static let liveFileName = "speaker-names.live.json"
    /// Overlap shorter than this decides nothing.
    public static let minimumOverlapMs = 5000
    /// The chosen speaker must hold more than this share of the overlap.
    public static let minimumShare = 0.5
    /// A turn with no later turn on its leg lasts at most this long.
    private static let lastTurnMs = 30000

    /// Each live system-leg label with a clear upgraded match, mapped to
    /// that upgraded label. Only `Remote speaker N` and `Speaker N` labels
    /// take part: the mic leg is not renumbered.
    public static func mapping(live: [TranscriptUpgradeSegment], upgraded: [TranscriptUpgradeSegment]) -> [String: String] {
        let liveSpans = spans(live.filter { isNumberedRemote($0.speaker) })
        let upgradedSpans = spans(upgraded.filter { isNumberedRemote($0.speaker) })
        var overlap: [String: [String: Int]] = [:]
        for span in liveSpans {
            for other in upgradedSpans where other.start < span.end && span.start < other.end {
                let shared = min(span.end, other.end) - max(span.start, other.start)
                overlap[span.speaker, default: [:]][other.speaker, default: 0] += shared
            }
        }
        var best: [String: (target: String, overlap: Int)] = [:]
        for (speaker, targets) in overlap {
            let total = targets.values.reduce(0, +)
            guard let top = targets.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                  top.value >= minimumOverlapMs, Double(top.value) > Double(total) * minimumShare else { continue }
            best[speaker] = (top.key, top.value)
        }
        // Two live speakers cannot share one upgraded voice: the larger
        // overlap keeps it, the other is dropped.
        var result: [String: String] = [:]
        for (speaker, choice) in best {
            let rivals = best.filter { $0.key != speaker && $0.value.target == choice.target }
            if rivals.contains(where: { $0.value.overlap > choice.overlap || ($0.value.overlap == choice.overlap && $0.key < speaker) }) {
                continue
            }
            result[speaker] = choice.target
        }
        return result
    }

    /// The names re-keyed onto upgraded labels. Names on other labels (a
    /// room speaker on the mic leg) and guide assignments stay as they were.
    public static func remap(_ archive: SpeakerNameArchive, mapping: [String: String]) -> SpeakerNameArchive {
        var names: [String: String] = [:]
        for (raw, name) in archive.names {
            let label = SpeakerLabelMapping.displayLabel(forRawKey: raw) ?? raw
            if isNumberedRemote(label) {
                if let target = mapping[label] {
                    names[target] = name
                }
            } else {
                names[label] = name
            }
        }
        return SpeakerNameArchive(names: names, assignments: archive.assignments)
    }

    /// Re-key `speaker-names.json` in `directory` after an upgrade. The
    /// first upgrade copies the live map to `speaker-names.live.json`; a
    /// later upgrade starts from that copy again. Returns true when the
    /// names file was rewritten.
    @discardableResult
    public static func apply(in directory: URL, live: [TranscriptUpgradeSegment],
                             upgraded: [TranscriptUpgradeSegment]) throws -> Bool
    {
        let current = directory.appendingPathComponent("speaker-names.json")
        let kept = directory.appendingPathComponent(liveFileName)
        let manager = FileManager.default
        let source = manager.fileExists(atPath: kept.path) ? kept : current
        guard manager.fileExists(atPath: source.path), !live.isEmpty else { return false }
        let archive = try JSONDecoder().decode(SpeakerNameArchive.self, from: Data(contentsOf: source))
        guard archive.names.keys.contains(where: { isNumberedRemote(SpeakerLabelMapping.displayLabel(forRawKey: $0) ?? $0) })
        else { return false }
        if source == current {
            try manager.copyItem(at: current, to: kept)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
        }
        let remapped = remap(archive, mapping: mapping(live: live, upgraded: upgraded))
        try JSONEncoder().encode(remapped).write(to: current, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        return true
    }

    private static func isNumberedRemote(_ label: String) -> Bool {
        guard let raw = SpeakerLabelMapping.rawKey(forDisplayLabel: label) else { return false }
        return raw.hasPrefix("remote_") || raw.hasPrefix("them_")
    }

    private struct Span {
        let speaker: String
        let start: Int
        let end: Int
    }

    /// Each turn lasts until the next turn on the same leg starts.
    private static func spans(_ segments: [TranscriptUpgradeSegment]) -> [Span] {
        let sorted = segments.sorted { $0.startMs < $1.startMs }
        return sorted.enumerated().map { index, segment in
            let next = index + 1 < sorted.count ? sorted[index + 1].startMs : segment.startMs + lastTurnMs
            return Span(speaker: segment.speaker, start: segment.startMs, end: max(segment.startMs, min(next, segment.startMs + lastTurnMs)))
        }
    }
}
