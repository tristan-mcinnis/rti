import Foundation

/// A stretch of the call one leg did not record (AUD-4). The WAVs keep both
/// legs on one timeline by filling such stretches with silence, so without
/// this record the transcript, the notes and `/meeting` cannot tell a
/// one-sided stretch from a quiet one. Times are milliseconds from the start
/// of the recording, the same clock as the live transcript.
public struct CaptureGap: Codable, Equatable, Sendable {
    public enum Leg: String, Codable, Sendable {
        case mic
        case system
    }

    public enum Reason: String, Codable, Sendable {
        /// The device delivered no audio; the file holds silence there.
        case noAudio = "no_audio"
        /// The microphone delivered only exact zeros (another app held it).
        case silentInput = "silent_input"
        /// System audio capture failed, never started or never carried sound.
        case captureFailed = "capture_failed"
        /// Audio could not be written to disk; the file holds silence there.
        case writeFailed = "write_failed"
    }

    public var leg: Leg
    public var reason: Reason
    public var startMs: Int
    /// Nil while the gap is still open: the archive was saved mid-call.
    public var endMs: Int?

    public init(leg: Leg, reason: Reason, startMs: Int, endMs: Int?) {
        self.leg = leg
        self.reason = reason
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// The capture gaps of one recording, collected from the watchdogs and the
/// WAV writer's gap fills. Several sources can report the same stretch (a
/// mic outage, then the writer's silence fill when the mic returns), so the
/// list is merged per leg when read.
public struct CaptureGapLog: Equatable, Sendable {
    /// Gaps closer than this on one leg are reported as one.
    public static let mergeToleranceMs = 1000
    private var entries: [CaptureGap] = []

    public init() {}

    public func isOpen(_ leg: CaptureGap.Leg, _ reason: CaptureGap.Reason) -> Bool {
        entries.contains { $0.leg == leg && $0.reason == reason && $0.endMs == nil }
    }

    /// Open a gap unless one of this leg and reason is already open.
    public mutating func begin(_ leg: CaptureGap.Leg, _ reason: CaptureGap.Reason, atMs: Int) {
        guard !isOpen(leg, reason) else { return }
        entries.append(CaptureGap(leg: leg, reason: reason, startMs: max(0, atMs), endMs: nil))
    }

    public mutating func end(_ leg: CaptureGap.Leg, _ reason: CaptureGap.Reason, atMs: Int) {
        guard let index = entries.lastIndex(where: { $0.leg == leg && $0.reason == reason && $0.endMs == nil }) else { return }
        entries[index].endMs = max(entries[index].startMs, atMs)
    }

    public mutating func add(_ leg: CaptureGap.Leg, _ reason: CaptureGap.Reason, startMs: Int, endMs: Int) {
        guard endMs > startMs else { return }
        entries.append(CaptureGap(leg: leg, reason: reason, startMs: max(0, startMs), endMs: endMs))
    }

    /// The recording stopped: every open gap ends now.
    public mutating func closeAll(atMs: Int) {
        for index in entries.indices where entries[index].endMs == nil {
            entries[index].endMs = max(entries[index].startMs, atMs)
        }
    }

    /// Merged per leg, in time order. A merged gap keeps the reason of its
    /// earliest part and stays open if any part is open.
    public var gaps: [CaptureGap] {
        var merged: [CaptureGap] = []
        for leg in [CaptureGap.Leg.mic, .system] {
            var current: CaptureGap?
            for gap in entries.filter({ $0.leg == leg }).sorted(by: { $0.startMs < $1.startMs }) {
                guard var open = current else {
                    current = gap
                    continue
                }
                if let end = open.endMs, gap.startMs > end + Self.mergeToleranceMs {
                    merged.append(open)
                    current = gap
                } else {
                    if let openEnd = open.endMs, let gapEnd = gap.endMs {
                        open.endMs = max(openEnd, gapEnd)
                    } else {
                        open.endMs = nil
                    }
                    current = open
                }
            }
            if let current {
                merged.append(current)
            }
        }
        return merged.sorted { ($0.startMs, $0.leg.rawValue) < ($1.startMs, $1.leg.rawValue) }
    }

    // MARK: Rendering

    /// The visible block for `transcript.md` and the `-rti.md` sidecar.
    /// Empty when nothing is missing.
    static let heading = "**Recording gaps.**"

    public static func markdown(_ gaps: [CaptureGap]) -> [String] {
        guard !gaps.isEmpty else { return [] }
        return ["> \(heading) Part of this call was not recorded. The transcript and notes have nothing from these stretches; do not read them as silence."]
            + gaps.map { "> - " + describe($0) }
    }

    /// `markdown` with the gaps block after its first `# ` title (or at the
    /// top), unless it already carries one.
    public static func annotate(_ markdown: String, gaps: [CaptureGap]) -> String {
        let block = Self.markdown(gaps)
        guard !block.isEmpty, !markdown.contains(heading) else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        if let title = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            lines.insert(contentsOf: [""] + block, at: title + 1)
        } else {
            lines.insert(contentsOf: block + [""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ gap: CaptureGap) -> String {
        let side = gap.leg == .mic ? "Your microphone" : "The other side (system audio)"
        let span = gap.endMs.map { "\(clock(gap.startMs)) to \(clock($0)) (\(length($0 - gap.startMs)))" }
            ?? "from \(clock(gap.startMs)), still missing when this was saved"
        let why = switch gap.reason {
        case .noAudio: "No audio arrived from the device; the audio file holds silence there."
        case .silentInput: "The microphone sent only silence. Another app may have held it."
        case .captureFailed: "System audio capture stopped or carried no sound."
        case .writeFailed: "Audio could not be saved to disk; the audio file holds silence there."
        }
        return "\(side): \(span). \(why)"
    }

    private static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static func length(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        if seconds < 60 {
            return "\(seconds) s"
        }
        let minutes = seconds / 60
        return seconds % 60 == 0 ? "\(minutes) min" : "\(minutes) min \(seconds % 60) s"
    }
}
