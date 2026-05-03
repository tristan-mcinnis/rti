import Foundation

/// Pure renderer: takes the inputs of a session and produces a `CorpusEntry`
/// ready to be written by `CorpusWriter`. No DB access, no IO; everything
/// the renderer needs is on the function signatures so the test surface is
/// the function input/output.
enum MarkdownRenderer {

    /// One transcript turn as it lands in the body.
    struct TurnLine {
        let speakerId: String        // "self" | "them_1" | "note" | …
        let startMs: Int
        let text: String
    }

    struct Inputs {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let title: String?
        let modeId: String?
        let transcriptQuality: String?
        let wavPath: String?
        let attendees: [String]?
        let speakerMap: [String: CorpusEntry.SpeakerMapEntry]?
        let keyTopics: [String]?
        let summaryMarkdown: String?     // SummaryController.summaryText
        let turns: [TurnLine]
    }

    static func make(_ inputs: Inputs) -> CorpusEntry {
        let frontmatter = CorpusEntry.Frontmatter(
            id: inputs.id,
            date: inputs.startedAt,
            capturedAt: inputs.startedAt,
            duration: inputs.endedAt.map { duration(from: inputs.startedAt, to: $0) },
            title: inputs.title,
            mode: inputs.modeId,
            attendees: inputs.attendees,
            speakerMap: inputs.speakerMap,
            keyTopics: inputs.keyTopics,
            transcriptQuality: inputs.transcriptQuality,
            wavPath: inputs.wavPath
        )
        var bodyParts: [String] = []
        if let summary = inputs.summaryMarkdown,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // SummaryController emits its own `## Summary` heading; if it
            // doesn't, we add one so the file always has a discoverable
            // section structure.
            if summary.contains("## ") {
                bodyParts.append(summary)
            } else {
                bodyParts.append("## Summary\n\(summary)")
            }
        }
        bodyParts.append("## Transcript")
        bodyParts.append(renderTranscript(inputs.turns))
        let body = bodyParts.joined(separator: "\n\n")
        return CorpusEntry(frontmatter: frontmatter, body: body)
    }

    /// Format a list of transcript turns as `[<speaker> <m:ss>] <text>`.
    /// Notes (speaker_id == "note") get a `[note <m:ss>]` prefix.
    static func renderTranscript(_ turns: [TurnLine]) -> String {
        turns.map { turn in
            let stamp = formatTimestamp(turn.startMs)
            return "[\(turn.speakerId) \(stamp)] \(turn.text)"
        }.joined(separator: "\n")
    }

    /// Convert a sequence of live JSONL events into rendered turns. Groups
    /// consecutive same-speaker word events; notes become standalone turns
    /// labelled `note`; chat events are skipped (chat is not part of the
    /// transcript). Exposed as a pure function so the session-end render
    /// pipeline can be tested without a running session.
    static func turns(from events: [LiveJSONLWriter.Event]) -> [TurnLine] {
        var out: [TurnLine] = []
        var pending: (speaker: String, startMs: Int, text: String)?
        func flush() {
            if let p = pending {
                out.append(TurnLine(speakerId: p.speaker, startMs: p.startMs, text: p.text))
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
                out.append(TurnLine(speakerId: "note", startMs: ts, text: text))
            case .chat:
                continue
            }
        }
        flush()
        return out
    }

    // MARK: - private

    private static func duration(from start: Date, to end: Date) -> String {
        let total = Int(end.timeIntervalSince(start))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        // Always show at least 1m to avoid "0m" for sub-minute sessions.
        return "\(max(1, m))m"
    }

    private static func formatTimestamp(_ ms: Int) -> String {
        TimeFormat.stampMs(ms)
    }
}
