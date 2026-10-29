import Foundation

/// Drops the room's echo of the remote voices from the mic leg, word by
/// word, before any batching or presentation. The system leg hears a remote
/// voice directly; the mic hears it again through the speakers, a moment
/// later, cut into other provider batches. Comparing whole batches left the
/// partial overlaps behind, so one remote sentence alternated between
/// "Speaker 1" and "Room speaker 1" and words split at the seams.
///
/// The rule: assemble each leg's tokens into words. A mic run (one speaker,
/// gaps under `runGapMs`) is echo when at least `matchShare` of its words
/// match a system word with the same normalised text within `windowMs`. The
/// whole run goes; the system leg keeps the words. A run of real speech that
/// only shares a few common words with the remote side stays whole.
public enum EchoFilter {
    public static let windowMs = 1_500
    public static let runGapMs = 1_000
    public static let matchShare = 0.5

    /// One leg's timed text: a final entry or an interim segment, with its
    /// words assembled and normalised once. A final entry never changes, so
    /// its owner keeps the source rather than rebuilding it per pass.
    public struct Source {
        public let speakerId: String
        let words: [Word]

        public init(speakerId: String, tokens: [LiveEntry.TimedToken]) {
            self.speakerId = speakerId
            words = EchoFilter.words(tokens)
        }
    }

    /// For each mic source, the indices of its tokens that are echo.
    public static func echoTokens(mic: [Source], system: [Source]) -> [Set<Int>] {
        var heard: [String: [Int]] = [:]
        for source in system {
            for word in source.words where !word.text.isEmpty {
                heard[word.text, default: []].append(word.startMs)
            }
        }
        var result = Array(repeating: Set<Int>(), count: mic.count)
        guard !heard.isEmpty else { return result }

        struct Located {
            let source: Int
            let word: Word
        }
        let micWords = mic.indices
            .flatMap { index in mic[index].words.map { Located(source: index, word: $0) } }
            .sorted { $0.word.startMs < $1.word.startMs }

        var run: [Located] = []
        func close() {
            let counted = run.filter { !$0.word.text.isEmpty }
            let matched = counted.filter { located in
                heard[located.word.text]?.contains { abs($0 - located.word.startMs) <= windowMs } ?? false
            }
            if !counted.isEmpty, Double(matched.count) >= Double(counted.count) * matchShare {
                for located in run { result[located.source].formUnion(located.word.tokens) }
            }
            run = []
        }
        for located in micWords {
            if let last = run.last,
               mic[last.source].speakerId != mic[located.source].speakerId
                || located.word.startMs - last.word.endMs >= runGapMs {
                close()
            }
            run.append(located)
        }
        close()
        return result
    }

    struct Word {
        let text: String
        let startMs: Int
        let endMs: Int
        let tokens: Range<Int>
    }

    /// A token that opens with whitespace, or with a CJK character (which
    /// carries no spaces), starts a new word; anything else continues one.
    static func words(_ tokens: [LiveEntry.TimedToken]) -> [Word] {
        var result: [Word] = []
        var start = 0
        func flush(_ end: Int) {
            guard start < end else { return }
            let text = tokens[start..<end].map(\.text).joined()
            result.append(Word(text: TranscriptTextNormalization.dedup(text), startMs: tokens[start].startMs,
                               endMs: tokens[end - 1].endMs, tokens: start..<end))
        }
        for (index, token) in tokens.enumerated() where index > start {
            if let first = token.text.unicodeScalars.first, first.properties.isWhitespace || isCJK(first) {
                flush(index)
                start = index
            }
        }
        flush(tokens.count)
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }
}
