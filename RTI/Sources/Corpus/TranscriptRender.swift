import Foundation

/// Canonical transcript conversion module. All paths from raw sources
/// (JSONL events, Soniox words, markdown body) to typed turns or entries
/// route through here so the format contract lives in one place.
enum TranscriptRender {

    // MARK: - JSONL events → TurnLine

    static func turns(from events: [LiveJSONLWriter.Event]) -> [MarkdownRenderer.TurnLine] {
        var out: [MarkdownRenderer.TurnLine] = []
        var pending: (speaker: String, startMs: Int, text: String)?
        func flush() {
            if let p = pending {
                out.append(MarkdownRenderer.TurnLine(speakerId: p.speaker, startMs: p.startMs, text: p.text))
                pending = nil
            }
        }
        for event in events {
            switch event {
            case .word(let ts, let speaker, let text, let isFinal, _, let channel):
                guard isFinal else { continue }
                let label = SpeakerLabelMapping.rawLabel(speaker: speaker, channel: channel)
                if pending?.speaker == label {
                    pending?.text += text
                } else {
                    flush()
                    pending = (label, ts, text)
                }
            case .note(let ts, let text):
                flush()
                out.append(MarkdownRenderer.TurnLine(speakerId: "note", startMs: ts, text: text))
            case .chat:
                continue
            }
        }
        flush()
        return out
    }

    // MARK: - SonioxWord → TurnLine

    static func turns(from words: [SonioxWord]) -> [MarkdownRenderer.TurnLine] {
        let collapsed = SpeakerTurn.collapse(words)
        return collapsed.map { run in
            MarkdownRenderer.TurnLine(
                speakerId: SpeakerLabelMapping.rawLabel(speaker: run.speaker),
                startMs: run.startMs,
                text: run.text
            )
        }
    }

    // MARK: - Markdown body → TranscriptEntry

    static func entries(from body: String, sessionId: String, createdAt: Date) -> [TranscriptEntry] {
        let marker = "## Transcript"
        let transcript: String
        if let r = body.range(of: marker) {
            transcript = String(body[r.upperBound...])
        } else {
            transcript = ""
        }
        var entries: [TranscriptEntry] = []
        for line in transcript.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            guard let close = trimmed.firstIndex(of: "]") else { continue }
            let header = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let speaker = String(parts[0])
            let stamp = String(parts[1])
            let startMs = parseTimestamp(stamp)
            entries.append(TranscriptEntry(
                id: UUID().uuidString,
                sessionId: sessionId,
                speakerId: speaker == "note" ? "note" : speaker,
                startMs: startMs,
                endMs: startMs,
                text: rest,
                confidence: 1.0,
                isFinal: true,
                createdAt: createdAt
            ))
        }
        return entries
    }

    // MARK: - JSONL events → TranscriptEntry

    static func entries(from events: [LiveJSONLWriter.Event], sessionId: String) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        for event in events {
            switch event {
            case .word(let ts, let speaker, let text, let isFinal, let confidence, let channel):
                guard isFinal else { continue }
                let label = SpeakerLabelMapping.rawLabel(speaker: speaker, channel: channel)
                out.append(TranscriptEntry(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    speakerId: label,
                    startMs: ts,
                    endMs: ts,
                    text: text,
                    confidence: confidence,
                    isFinal: true,
                    createdAt: Date()
                ))
            case .note(let ts, let text):
                out.append(TranscriptEntry(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    speakerId: "note",
                    startMs: ts,
                    endMs: ts,
                    text: text,
                    confidence: 1.0,
                    isFinal: true,
                    createdAt: Date()
                ))
            case .chat:
                continue
            }
        }
        return out
    }

    // MARK: - TurnLine → canonical markdown string

    static func render(turns: [MarkdownRenderer.TurnLine]) -> String {
        turns.map { turn in
            let stamp = TimeFormat.stampMs(turn.startMs)
            return "[\(turn.speakerId) \(stamp)] \(turn.text)"
        }.joined(separator: "\n")
    }

    // MARK: - private

    private static func parseTimestamp(_ stamp: String) -> Int {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return (parts[0] * 60 + parts[1]) * 1000
        case 3: return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        default: return 0
        }
    }
}
