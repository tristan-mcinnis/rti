import Foundation

extension LiveTranscriptPresentation {
    /// Silence after which the same speaker starts a new turn with its own
    /// label and time.
    public static let turnGapMs = 30_000

    /// A long turn is drawn as blocks of at most `blockRows` rows or
    /// `blockMs` of speech, so one speaker talking for an hour (labels off,
    /// or one mic in the room) is not one growing cell that the list must
    /// diff and lay out on every flush (2026-11-13 M1 audit). A block ends
    /// only after a row that ended a sentence, where a paragraph breaks
    /// anyway; after twice the rows it ends regardless.
    public static let blockRows = 12
    public static let blockMs = 120_000

    /// Consecutive rows of one speaker under one label line. A row closes on
    /// any one-second pause; a turn closes only on a speaker change, a note,
    /// or `turnGapMs` of silence. Its ID is its first row's, so the reading
    /// anchor holds while the turn grows. A long turn continues in further
    /// blocks (`isContinuation`), each with its own ID and no label.
    public struct Turn: Identifiable, Equatable, Sendable {
        public let rows: [LiveRow]
        /// A later block of a long turn, drawn without its own label.
        public let isContinuation: Bool
        /// The rows' paragraphs, built once with the block. A row follows a
        /// pause, so it starts a new paragraph when the text before it ended
        /// a sentence; otherwise it flows inline, and a thinking pause never
        /// splits a sentence. Breaks inside a row stay where they were made.
        public let paragraphs: [[Span]]

        public init(rows: [LiveRow], isContinuation: Bool = false) {
            self.rows = rows
            self.isContinuation = isContinuation
            paragraphs = Self.paragraphs(of: rows)
        }

        public var id: RunID { rows[0].id }
        public var speakerId: String { rows[0].speakerId }
        public var speakerLabel: String { rows[0].speakerLabel }
        public var startMs: Int? { rows[0].startMs }
        public var isNote: Bool { rows[0].isNote }
        public var isSelf: Bool { rows[0].isSelf }
        public var hasPending: Bool { rows.contains(where: \.hasPending) }

        private static func paragraphs(of rows: [LiveRow]) -> [[Span]] {
            var result: [[Span]] = []
            for row in rows {
                let own = row.paragraphs.map(\.spans).filter { !$0.isEmpty }
                guard var first = own.first else { continue }
                if let end = result.last?.last?.text.last(where: { !$0.isWhitespace }),
                   LiveTranscriptPresentation.sentenceEnds.contains(end) {
                    result.append(first)
                } else if let previous = result.popLast() {
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

        public static func == (lhs: Turn, rhs: Turn) -> Bool {
            lhs.isContinuation == rhs.isContinuation && lhs.rows == rhs.rows
        }

        /// The same block with its rows replaced.
        func replacing(rows: [LiveRow]) -> Turn {
            Turn(rows: rows, isContinuation: isContinuation)
        }
    }

    /// Group rows into turns and blocks. `previous` is the row just before
    /// `rows` when they resume a list part way, so a block that continues
    /// a turn stays a continuation.
    public static func turns<Rows: Collection>(_ rows: Rows, after previous: LiveRow? = nil) -> [Turn] where Rows.Element == LiveRow {
        var result: [(rows: [LiveRow], continuation: Bool)] = []
        var last = previous
        for row in rows {
            if let before = last, continues(before, with: row) {
                if let block = result.last?.rows, !blockIsFull(block, before: row) {
                    result[result.count - 1].rows.append(row)
                } else {
                    result.append(([row], true))
                }
            } else {
                result.append(([row], false))
            }
            last = row
        }
        return result.map { Turn(rows: $0.rows, isContinuation: $0.continuation) }
    }

    /// True when `row` starts a new block after `block`.
    static func blockIsFull(_ block: [LiveRow], before row: LiveRow) -> Bool {
        let long = block.count >= blockRows
            || (row.startMs.flatMap { start in block.first?.startMs.map { start - $0 >= blockMs } } ?? false)
        guard long else { return false }
        return block.count >= blockRows * 2 || block.last.map(endsSentence) == true
    }

    /// The row's visible text ends with a sentence mark.
    static func endsSentence(_ row: LiveRow) -> Bool {
        guard let end = row.paragraphs.last?.spans.last?.text.last(where: { !$0.isWhitespace }) else { return false }
        return sentenceEnds.contains(end)
    }

    static func continues(_ previous: LiveRow, with row: LiveRow) -> Bool {
        guard previous.streamID == row.streamID, previous.speakerId == row.speakerId, !row.isNote, !row.speakerId.isEmpty else { return false }
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
