import Foundation

/// A user-editable transcript turn from RTI's archived Markdown record.
/// The archive remains Markdown, but treating its timestamped rows as turns
/// lets the session reader correct text and speaker assignment safely.
public struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var timestamp: String
    public var speaker: String
    public var text: String
    public let isNote: Bool

    public init(
        id: UUID = UUID(),
        timestamp: String,
        speaker: String,
        text: String,
        isNote: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
        self.isNote = isNote
    }
}

/// Parses and rewrites the timestamped turn rows RTI stores in transcript.md.
/// Non-turn Markdown (frontmatter, headings, provenance) is deliberately left
/// alone; only the transcript body rows are replaced.
public enum SessionTranscriptReview {
    public static func turns(from markdown: String) -> [SessionTranscriptTurn] {
        markdown.components(separatedBy: .newlines).compactMap(turn(from:))
    }

    public static func speakerLabels(from markdown: String) -> [String] {
        Array(Set(turns(from: markdown)
            .filter { !$0.isNote }
            .map(\.speaker)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func replacingTurns(in markdown: String, with turns: [SessionTranscriptTurn]) -> String {
        let replacement = turns.map(render).joined(separator: "\n\n")
        let lines = markdown.components(separatedBy: .newlines)
        guard let first = lines.firstIndex(where: { turn(from: $0) != nil }) else { return markdown }

        var last = first
        while last + 1 < lines.count {
            let next = lines[last + 1]
            if turn(from: next) != nil || next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                last += 1
            } else {
                break
            }
        }

        var output = Array(lines[..<first])
        if !output.isEmpty, !output.last!.isEmpty { output.append("") }
        output.append(contentsOf: replacement.components(separatedBy: .newlines))
        if last + 1 < lines.count {
            if !output.last!.isEmpty { output.append("") }
            output.append(contentsOf: lines[(last + 1)...])
        }
        return output.joined(separator: "\n")
    }

    private static func turn(from line: String) -> SessionTranscriptTurn? {
        let pattern = #"^`([^`]+)` \*\*(.+?):\*\*\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let timestampRange = Range(match.range(at: 1), in: line),
              let speakerRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line)
        else { return nil }

        let speaker = String(line[speakerRange])
        return SessionTranscriptTurn(
            timestamp: String(line[timestampRange]),
            speaker: speaker,
            text: String(line[textRange]),
            isNote: speaker == "📝 Note"
        )
    }

    private static func render(_ turn: SessionTranscriptTurn) -> String {
        let speaker = turn.isNote ? "📝 Note" : turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(turn.timestamp)` **\(speaker):** \(text)"
    }
}
