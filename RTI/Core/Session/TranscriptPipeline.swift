import Foundation

/// Per-channel live transcript aggregation and note buffering. Owns the
/// `TranscriptAggregator`s and the note entry list; produces the combined
/// `liveEntries` and `interimLine` that the UI observes. Ephemeral build:
/// nothing is written to disk — the in-memory entries are the only record.
public final class TranscriptPipeline {

    private let micAggregator = TranscriptAggregator(channel: "mic")
    private let systemAggregator = TranscriptAggregator(channel: "system")
    private var noteEntries: [LiveEntry] = []

    public init() {}

    public var liveEntries: [LiveEntry] {
        (noteEntries + micAggregator.entries + systemAggregator.entries)
            .sorted(by: { $0.startMs < $1.startMs })
    }

    public var interimLine: String? {
        let parts = [micAggregator.interimText, systemAggregator.interimText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    public func process(words: [SonioxWord], channel: String) {
        switch channel {
        case "mic": micAggregator.process(words)
        case "system": systemAggregator.process(words)
        default: break
        }
    }

    /// Align the system channel's entries onto the mic timeline. `ms` is how
    /// much later the system-audio leg started than the mic leg; see
    /// `TranscriptAggregator.startMsOffset`.
    public func setSystemStartOffset(ms: Int) {
        systemAggregator.startMsOffset = ms
    }

    @discardableResult
    public func insertNote(_ text: String, startedAt: Date) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let offsetMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
        let entry = LiveEntry(
            speakerId: "note",
            text: trimmed,
            startMs: offsetMs,
            confidence: 1.0,
            translationStatus: "none",
            language: nil,
            sourceLanguage: nil
        )
        noteEntries.append(entry)
        if noteEntries.count > 500 { noteEntries.removeFirst(noteEntries.count - 500) }
        return true
    }

    public func reset() {
        micAggregator.reset()
        systemAggregator.reset()
        noteEntries = []
    }
}
