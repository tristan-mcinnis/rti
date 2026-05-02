import Foundation

/// A contiguous stretch of `SonioxWord`s attributed to a single speaker,
/// collapsed into one block. The runtime aggregate that becomes a
/// `TranscriptEntry` row when persisted.
///
/// See `CONTEXT.md` for the domain definition.
struct SpeakerTurn {
    let speaker: Int
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Double
}

extension SpeakerTurn {
    /// Walk the word stream and start a new turn whenever the speaker id
    /// changes. Confidence is the unweighted mean over the words in the turn.
    static func collapse(_ words: [SonioxWord]) -> [SpeakerTurn] {
        guard !words.isEmpty else { return [] }
        var groups: [[SonioxWord]] = []
        for word in words {
            if groups.last?.last?.speaker == word.speaker {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.map { group in
            let confidenceAvg = group.map(\.confidence).reduce(0, +) / Double(group.count)
            return SpeakerTurn(
                speaker: group[0].speaker,
                text: group.map(\.text).joined(),
                startMs: group.first?.startMs ?? 0,
                endMs: group.last?.endMs ?? 0,
                confidence: confidenceAvg
            )
        }
    }
}
