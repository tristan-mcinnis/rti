import Foundation

/// A contiguous stretch of `SonioxWord`s attributed to a single speaker,
/// collapsed into one block. The runtime aggregate used to build the live
/// in-memory transcript entries.
struct SpeakerTurn {
    let speaker: Int
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Double
    let translationStatus: String
    let language: String?
    let sourceLanguage: String?
}

extension SpeakerTurn {
    /// Walk the word stream and start a new turn whenever the speaker id
    /// changes. Confidence is the unweighted mean over the words in the turn.
    static func collapse(_ words: [SonioxWord]) -> [SpeakerTurn] {
        guard !words.isEmpty else { return [] }
        var groups: [[SonioxWord]] = []
        for word in words {
            let last = groups.last?.last
            // Start a new group on speaker change OR when crossing
            // original ↔ translation boundaries (they need separate
            // visual entries).
            let sameRun = last?.speaker == word.speaker
                && last?.translationStatus == word.translationStatus
                && last?.language == word.language
            if sameRun {
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
                confidence: confidenceAvg,
                translationStatus: group[0].translationStatus,
                language: group[0].language,
                sourceLanguage: group[0].sourceLanguage
            )
        }
    }
}
