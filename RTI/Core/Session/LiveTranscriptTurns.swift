import Foundation

extension LiveTranscriptPresentation {
    /// Silence after which the same speaker starts a new turn with its own
    /// label and time.
    public static let turnGapMs = 30_000

    /// Consecutive rows of one speaker under one label line. A row closes on
    /// any one-second pause; a turn closes only on a speaker change, a note,
    /// or `turnGapMs` of silence. Its ID is its first row's, so the reading
    /// anchor holds while the turn grows.
    public struct Turn: Identifiable, Equatable {
        public let rows: [LiveRow]

        public var id: RunID { rows[0].id }
        public var speakerId: String { rows[0].speakerId }
        public var speakerLabel: String { rows[0].speakerLabel }
        public var startMs: Int? { rows[0].startMs }
        public var isNote: Bool { rows[0].isNote }
        public var isSelf: Bool { rows[0].isSelf }
        public var hasPending: Bool { rows.contains(where: \.hasPending) }

        /// The rows' paragraphs, each row's first flowing inline after the
        /// previous row's last. Breaks inside a row stay where they were made.
        public var paragraphs: [[Span]] {
            var result: [[Span]] = []
            for row in rows {
                let own = row.paragraphs.map(\.spans).filter { !$0.isEmpty }
                guard var first = own.first else { continue }
                if let previous = result.popLast() {
                    if needsSpace(after: previous.last?.text.last, before: first[0].text.first) {
                        first[0] = Span(text: " " + first[0].text, isFinal: first[0].isFinal)
                    }
                    result.append(previous + first)
                } else {
                    result.append(first)
                }
                result.append(contentsOf: own.dropFirst())
            }
            return result
        }

        public var text: String {
            paragraphs.map { $0.map(\.text).joined() }.joined(separator: "\n\n")
        }

        public var translation: String {
            rows.map { $0.translation.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        public static func == (lhs: Turn, rhs: Turn) -> Bool { lhs.rows == rhs.rows }
    }

    public static func turns<Rows: Collection>(_ rows: Rows) -> [Turn] where Rows.Element == LiveRow {
        var result: [[LiveRow]] = []
        for row in rows {
            if let previous = result.last?.last, continues(previous, with: row) {
                result[result.count - 1].append(row)
            } else {
                result.append([row])
            }
        }
        return result.map(Turn.init(rows:))
    }

    private static func continues(_ previous: LiveRow, with row: LiveRow) -> Bool {
        guard previous.speakerId == row.speakerId, !row.isNote, !row.speakerId.isEmpty else { return false }
        guard let start = row.startMs, let before = previous.endMs ?? previous.startMs else { return true }
        return start - before <= turnGapMs
    }

    private static func needsSpace(after last: Character?, before first: Character?) -> Bool {
        guard let last, let first else { return false }
        if last.isWhitespace || first.isWhitespace || first.isPunctuation { return false }
        return !(isCJK(last) || isCJK(first))
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } ?? false
    }
}
