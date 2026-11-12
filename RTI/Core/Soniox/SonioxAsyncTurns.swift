import Foundation

/// A locator into the immutable provider response. Indices are zero-based in
/// its original tokens array, including any intervening non-speech tokens.
public struct SonioxAsyncTurnSource: Codable, Equatable, Sendable {
    public let responseFile: String
    public let tokenIndices: [Int]
    public let providerSpeaker: String?
    public let providerStartMs: Int?
    public let providerEndMs: Int?
    public let legOffsetMs: Int
}

public enum SonioxAsyncTurns {
    public static func segments(data: Data, system: Bool, policy: SessionSpeakerPolicy, offsetMs: Int) throws -> [TranscriptUpgradeSegment] {
        let raw = try JSONDecoder().decode(SonioxTranscriptMessage.self, from: data)
        guard let tokens = raw.tokens else { throw CocoaError(.fileReadCorruptFile) }
        let file = system ? "soniox-async-system.json" : "soniox-async-mic.json"
        var turns: [TranscriptUpgradeSegment] = []
        var indices: [Int] = []
        var words = ""
        var cluster: String?
        var reportedStart: Int?
        var reportedEnd: Int?
        var displayStart = 0
        var previousEnd = 0

        func flush() {
            guard !indices.isEmpty else { return }
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = if !system {
                    "Me"
                } else if policy.labelsEnabled, let cluster {
                    "Remote speaker " + cluster
                } else {
                    "Them"
                }
                let source = SonioxAsyncTurnSource(responseFile: file, tokenIndices: indices, providerSpeaker: cluster,
                                                   providerStartMs: reportedStart, providerEndMs: reportedEnd, legOffsetMs: offsetMs)
                turns.append(.init(speaker: label, startMs: displayStart + offsetMs, text: words, source: source))
            }
            indices.removeAll(keepingCapacity: true)
            words = ""
            cluster = nil
            reportedStart = nil
            reportedEnd = nil
        }

        for (index, token) in tokens.enumerated() {
            if token.isStreamBoundary {
                flush(); continue
            }
            guard token.translationStatus != "translation", !token.text.isEmpty else { continue }
            let wordSpeaker = token.providerSpeaker.flatMap { $0.isEmpty ? nil : $0 }
            let hasLexicalText = token.text.rangeOfCharacter(from: .alphanumerics) != nil
            // Punctuation often carries neither a speaker nor a timestamp. It
            // still belongs to the original run in the display projection.
            let nextSpeaker = !hasLexicalText && wordSpeaker == nil ? cluster : wordSpeaker
            let time = token.providerStartMs ?? previousEnd
            let finishedSentence = words.last.map { "。！？.!?".contains($0) } == true
            if !indices.isEmpty, (system && policy.labelsEnabled && cluster != nextSpeaker) ||
                (hasLexicalText && (finishedSentence || time - previousEnd > 1500 || time - displayStart > 20000))
            {
                flush()
            }
            if indices.isEmpty {
                displayStart = time
                reportedStart = token.providerStartMs
                cluster = wordSpeaker
            }
            indices.append(index)
            words += token.text
            reportedEnd = token.providerEndMs
            previousEnd = max(time, token.providerEndMs ?? time)
        }
        flush()
        return turns
    }
}
