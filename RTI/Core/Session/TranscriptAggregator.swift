import Foundation

/// One provider socket's token feed on one physical input. Each final token
/// arrives once; every packet replaces the provisional suffix for this leg.
/// TimedToken.provider is the untouched wire token. Display labels and times
/// are separate projections so an empty speaker or unknown clock remains known.
public final class TranscriptAggregator {
    public private(set) var entries: [LiveEntry] = []
    public private(set) var interimSegments: [LiveTranscriptPresentation.InterimSegment] = []
    public private(set) var streamID = UUID()
    public var startMsOffset = 0
    var labelsEnabled = true
    private let channel: String
    private var nextOrdinal = 0
    private var lastTime = 0
    private var largestCluster = 0
    private var clusterOffset = 0
    private var labels: [String: Int] = [:]
    private var usedNumbers: Set<Int> = []

    public init(channel: String) { self.channel = channel }

    public var interimText: String? {
        guard !interimSegments.isEmpty else { return nil }
        return interimSegments.map { "\($0.speakerId): \($0.text)" }.joined(separator: "  ")
    }

    private func speakerKey(_ raw: String?) -> String {
        guard channel == "system" else { return "self" }
        guard labelsEnabled, let raw, !raw.isEmpty else { return "remote" }
        if let number = labels[raw] { return "remote_\(number)" }
        let preferred = Int(raw).flatMap { index -> Int? in
            guard index > 0, index < Int.max - clusterOffset else { return nil }
            let number = index + clusterOffset
            return usedNumbers.contains(number) ? nil : number
        }
        let number = preferred ?? (largestCluster + 1)
        usedNumbers.insert(number)
        labels[raw] = number
        largestCluster = max(largestCluster, number)
        return "remote_\(number)"
    }

    /// A run is only a view over adjacent tokens from the same packet and
    /// source. Every token retains its optional provider fields and ordinal.
    private func rows(_ words: [SonioxWord], final: Bool) -> [LiveEntry] {
        var rows: [LiveEntry] = []
        var tokens: [LiveEntry.TimedToken] = []
        var speaker = ""
        var first: SonioxWord?
        var ordinal = nextOrdinal
        var anchor = lastTime

        func flush() {
            guard let first, let start = tokens.first?.startMs else { return }
            let scores = tokens.compactMap { $0.provider?.providerConfidence }
            let confidence = scores.count == tokens.count ? scores.reduce(0, +) / Double(scores.count) : nil
            rows.append(LiveEntry(speakerId: speaker, text: tokens.map(\.text).joined(),
                                  startMs: start, confidence: confidence, translationStatus: first.translationStatus,
                                  language: first.language, sourceLanguage: first.sourceLanguage,
                                  textOrigin: .providerTokens, streamID: streamID, tokens: tokens))
            tokens.removeAll(keepingCapacity: true)
        }

        for word in words where word.isFinal == final {
            defer { ordinal += 1 }
            // Retained in the packet journal, omitted only from spoken lines.
            if word.isStreamBoundary { flush(); first = nil; continue }
            let label = speakerKey(word.providerSpeaker)
            if first?.providerSpeaker != word.providerSpeaker || speaker != label ||
                first?.providerTranslationStatus != word.providerTranslationStatus ||
                first?.language != word.language || first?.sourceLanguage != word.sourceLanguage {
                flush()
                first = nil
            }
            if first == nil { first = word; speaker = label }
            let start = word.providerStartMs ?? anchor
            let end = word.providerEndMs ?? start
            tokens.append(.init(text: word.text, startMs: start + startMsOffset, endMs: end + startMsOffset,
                                provider: word, ordinal: ordinal, leg: channel, streamOffsetMs: startMsOffset))
            anchor = max(anchor, end)
        }
        flush()
        if final {
            lastTime = anchor
            nextOrdinal = ordinal
        }
        return rows
    }

    @discardableResult
    public func process(_ words: [SonioxWord]) -> Bool {
        let final = receive(words)
        entries.append(contentsOf: final)
        return !final.isEmpty
    }

    /// The pipeline owns its merged history; its per-leg decoder only holds
    /// provisional state and never retains a second final history.
    func receive(_ words: [SonioxWord]) -> [LiveEntry] {
        let final = rows(words, final: true)
        interimSegments = rows(words, final: false).map { row in
            .init(speakerId: row.speakerId, text: row.text, textOrigin: .providerTokens, startMs: row.startMs,
                  translationStatus: row.translationStatus, language: row.language, streamID: streamID, tokens: row.tokens)
        }
        return final
    }

    public func prepareForReconnect() { restartStream(atMs: startMsOffset + lastTime) }

    public func restartStream(atMs: Int) {
        startMsOffset = atMs
        clusterOffset = largestCluster
        labels.removeAll()
        usedNumbers.removeAll()
        streamID = UUID()
        interimSegments.removeAll()
        lastTime = 0
        nextOrdinal = 0
    }

    public func reset() {
        entries.removeAll()
        largestCluster = 0
        restartStream(atMs: 0)
    }
}

enum TranscriptTextNormalization {
    /// Whitespace, punctuation and symbols, dropped before comparison. Built
    /// once: `CharacterSet.union` computes full Unicode plane bitmaps, so
    /// rebuilding this three-way union on every comparison was, on its own,
    /// more than half of a long session's main-thread cost (measured
    /// 2026-09-22, 1h45m session: 55% of the busy thread).
    private static let dropSet: CharacterSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    static func dedup(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !dropSet.contains($0) })).lowercased()
    }

    static func sequence(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
