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
        let notesMarkdown: String?       // Concatenated GeneratedNote bodies
        let entitiesMarkdown: String?    // Grouped EntityDossier list
        let turns: [TurnLine]
        let projectId: String?
        let projectName: String?

        init(
            id: String,
            startedAt: Date,
            endedAt: Date?,
            title: String?,
            modeId: String?,
            transcriptQuality: String?,
            wavPath: String?,
            attendees: [String]?,
            speakerMap: [String: CorpusEntry.SpeakerMapEntry]?,
            keyTopics: [String]?,
            summaryMarkdown: String?,
            notesMarkdown: String? = nil,
            entitiesMarkdown: String? = nil,
            turns: [TurnLine],
            projectId: String? = nil,
            projectName: String? = nil
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.title = title
            self.modeId = modeId
            self.transcriptQuality = transcriptQuality
            self.wavPath = wavPath
            self.attendees = attendees
            self.speakerMap = speakerMap
            self.keyTopics = keyTopics
            self.summaryMarkdown = summaryMarkdown
            self.notesMarkdown = notesMarkdown
            self.entitiesMarkdown = entitiesMarkdown
            self.turns = turns
            self.projectId = projectId
            self.projectName = projectName
        }
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
            wavPath: inputs.wavPath,
            project: inputs.projectName,
            projectId: inputs.projectId
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
        if let notes = inputs.notesMarkdown,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append("## Notes\n\n\(notes)")
        }
        if let entities = inputs.entitiesMarkdown,
           !entities.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyParts.append("## Entities\n\n\(entities)")
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

    /// Convert a sequence of live JSONL events into rendered turns.
    /// Delegates to `TranscriptRender` so the format contract is centralised.
    static func turns(from events: [LiveJSONLWriter.Event]) -> [TurnLine] {
        TranscriptRender.turns(from: events)
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
