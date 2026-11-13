import Foundation

/// Reads `soniox-live.jsonl` back. The journal receives every final token as
/// it arrives, so after a crash it is newer than the last 5-minute
/// checkpoint. The transcript upgrade uses it when one leg transcribes to
/// nothing and the live lines of that leg must stand in for it.
public enum SonioxLiveJournalReplay {
    /// Every batch that decodes. A kill mid-write leaves a truncated last
    /// line; it and any other unreadable line are skipped, never fatal.
    public static func batches(in directory: URL) -> [SonioxLiveJournal.Batch] {
        let url = directory.appendingPathComponent(SonioxLiveJournal.filename)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(SonioxLiveJournal.Batch.self, from: Data(line))
        }
    }

    /// Live lines of one leg (`mic` or `system`) that start at or after
    /// `fromMs` on the session timeline, labelled `Me` or `Them` like the
    /// evidence turns. A line ends after a sentence mark, at a pause of more
    /// than 1.5 s, or where a new stream starts. Translation tokens are not
    /// original speech and are left out.
    public static func segments(in directory: URL, leg: String, fromMs: Int) -> [TranscriptUpgradeSegment] {
        let speaker = leg == "system" ? "Them" : "Me"
        var lines: [TranscriptUpgradeSegment] = []
        var text = ""
        var startMs = 0
        var lastEndMs: Int?
        var stream = ""
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(TranscriptUpgradeSegment(speaker: speaker, startMs: startMs, text: trimmed))
            }
            text = ""
        }
        for batch in batches(in: directory) where batch.leg == leg {
            for token in batch.tokens where token.translationStatus != "translation" {
                let start = batch.baseMs + token.startMs
                guard start >= fromMs else { continue }
                if batch.stream != stream || start - (lastEndMs ?? start) > 1500 {
                    flush()
                }
                if text.isEmpty {
                    startMs = start
                }
                text += token.text
                stream = batch.stream
                lastEndMs = batch.baseMs + max(token.endMs, token.startMs)
                if let last = token.text.trimmingCharacters(in: .whitespaces).last, ".?!。？！".contains(last) {
                    flush()
                }
            }
        }
        flush()
        return lines
    }
}
