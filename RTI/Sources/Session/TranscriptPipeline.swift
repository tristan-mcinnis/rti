import Foundation

/// Per-channel live transcript aggregation, note buffering, and JSONL
/// writing. Owns the `TranscriptAggregator`s and the note entry list;
/// produces the combined `liveEntries` and `interimLine` that the UI
/// observes.
@MainActor
final class TranscriptPipeline {

    private let micAggregator = TranscriptAggregator(channel: "mic")
    private let systemAggregator = TranscriptAggregator(channel: "system")
    private var noteEntries: [LiveEntry] = []

    var liveEntries: [LiveEntry] {
        (noteEntries + micAggregator.entries + systemAggregator.entries)
            .sorted(by: { $0.startMs < $1.startMs })
    }

    var interimLine: String? {
        let parts = [micAggregator.interimText, systemAggregator.interimText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    init() {
        micAggregator.onTurnsProcessed = { [weak self] turns in
            self?.writeJSONL(turns, channel: "mic")
        }
        systemAggregator.onTurnsProcessed = { [weak self] turns in
            self?.writeJSONL(turns, channel: "system")
        }
    }

    func process(words: [SonioxWord], channel: String) {
        switch channel {
        case "mic": micAggregator.process(words)
        case "system": systemAggregator.process(words)
        default: break
        }
    }

    @discardableResult
    func insertNote(_ text: String, sessionId: String, startedAt: Date) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let offsetMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
        let writer = CorpusManager.shared.liveWriter(sessionId: sessionId)
            ?? CorpusManager.shared.openLive(sessionId: sessionId)
        writer.append(.note(ts: offsetMs, text: trimmed))
        let entry = LiveEntry(
            speakerId: "note",
            text: trimmed,
            startMs: offsetMs,
            confidence: 1.0
        )
        noteEntries.append(entry)
        if noteEntries.count > 500 { noteEntries.removeFirst(noteEntries.count - 500) }
        return true
    }

    func reset() {
        micAggregator.reset()
        systemAggregator.reset()
        noteEntries = []
    }

    private func writeJSONL(_ turns: [SpeakerTurn], channel: String) {
        guard let sessionId = SessionCoordinator.shared.currentSessionId,
              let writer = CorpusManager.shared.liveWriter(sessionId: sessionId) else { return }
        for turn in turns {
            writer.append(.word(
                ts: turn.startMs,
                speaker: turn.speaker,
                text: turn.text,
                isFinal: true,
                confidence: turn.confidence,
                channel: channel
            ))
        }
    }
}
