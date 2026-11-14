import Foundation

/// How much of the live transcript a turn reads. A question about the call as
/// a whole (themes, patterns, "so far", a summary) reads all of it; anything
/// else reads the recent window (2026-11-14: "what are the themes" saw only
/// the last 15 minutes of a two-hour group).
public enum TranscriptScope {
    /// Whole-call transcripts longer than this keep their newest part. A
    /// two-hour Mandarin group runs about 50,000 to 80,000 characters.
    public static let wholeCallCharacterCap = 90000

    static let wholeCallTerms = [
        "theme", "pattern", "so far", "overall", "whole", "entire", "throughout",
        "across", "summar", "recap", "since the start", "from the start", "big picture",
        "takeaway", "tension", "contradict", "consensus", "everyone", "all of them",
        "主题", "总体", "整体", "到目前", "目前为止", "总结", "全程", "整场", "大家都",
    ]

    /// True when a typed question asks about the call as a whole.
    public static func wantsWholeCall(_ question: String) -> Bool {
        let text = question.lowercased()
        return wholeCallTerms.contains { text.contains($0) }
    }

    /// The newest part of `text` that fits `cap`, cut at a line start, behind
    /// a line that says earlier talk was left out. `text` when it fits.
    public static func fitted(_ text: String, cap: Int = wholeCallCharacterCap) -> String {
        guard text.count > cap else { return text }
        let tail = text.suffix(cap)
        let start = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
        return "[Earlier talk left out to fit; this is the newest part of the call.]\n" + tail[start...]
    }
}
