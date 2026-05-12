import Foundation

/// Splits long transcript / summary text into chunks suitable for embedding.
/// Strategy: greedy by paragraph (double-newline split), packing paragraphs
/// into windows up to `maxWords`, with `overlapWords` of trailing context
/// re-emitted into the next chunk so semantic boundaries don't drop
/// information.
///
/// Tunable in one place so future eval work can sweep these without
/// touching the indexer.
enum ChunkPolicy {
    /// Target chunk size. NLEmbedding handles long text fine, but smaller
    /// chunks → finer-grained matches and tighter snippets.
    static let maxWords = 500

    /// Trailing words from chunk N re-prepended to chunk N+1. Smooths the
    /// boundary so a concept split across two chunks is still discoverable.
    static let overlapWords = 60

    /// A single chunk of text plus the byte range it came from in the
    /// source so we could later jump back to it. Range is unused for v1
    /// retrieval but kept for future "show me where" features.
    struct Chunk {
        let idx: Int
        let text: String
    }

    /// Split `body` into chunks. Returns at least one chunk per non-empty
    /// input — even very short text becomes a single chunk. Empty input
    /// returns an empty array.
    static func split(_ body: String) -> [Chunk] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Split on blank lines. Keeps each paragraph atomic — we never
        // break inside a paragraph (most transcript paragraphs are short
        // speaker turns, so this rarely matters).
        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [Chunk] = []
        var current: [String] = []
        var currentWords = 0

        func emit() {
            guard !current.isEmpty else { return }
            let text = current.joined(separator: "\n\n")
            chunks.append(Chunk(idx: chunks.count, text: text))
            // Seed the next chunk with overlap from the tail of this one.
            let words = text.split(whereSeparator: { $0.isWhitespace })
            if words.count > overlapWords {
                let tail = words.suffix(overlapWords).joined(separator: " ")
                current = [tail]
                currentWords = overlapWords
            } else {
                current = []
                currentWords = 0
            }
        }

        for p in paragraphs {
            let pWords = p.split(whereSeparator: { $0.isWhitespace }).count
            // A single paragraph longer than the window: emit it as its
            // own oversize chunk (NLEmbedding handles it) rather than
            // hard-splitting mid-sentence.
            if pWords > maxWords && current.isEmpty {
                chunks.append(Chunk(idx: chunks.count, text: p))
                continue
            }
            if currentWords + pWords > maxWords {
                emit()
            }
            current.append(p)
            currentWords += pWords
        }
        emit()

        return chunks
    }
}
