import Foundation

/// Per-channel live transcript aggregation and note buffering. Owns the
/// `TranscriptAggregator`s and the note entry list; produces the combined
/// `liveEntries` and `interimLine` that the UI observes. Ephemeral build:
/// nothing is written to disk — the in-memory entries are the only record.
public final class TranscriptPipeline {

    private let micAggregator = TranscriptAggregator(channel: "mic")
    private let systemAggregator = TranscriptAggregator(channel: "system")
    private var noteEntries: [LiveEntry] = []

    /// Lazily-rebuilt merge of both channels + notes, sorted by `startMs`.
    /// Before this cache, `liveEntries` re-concatenated and re-sorted the ENTIRE
    /// transcript on *every* read — and `SessionCoordinator.publishState` read
    /// it on every inbound Soniox frame (tens of thousands in a 2-hour session).
    /// That O(N log N)-per-frame cost, rising with N, was the dominant CPU sink
    /// behind the long-session slowdown. Now the merge happens once per finals
    /// batch (cache invalidated only when entries actually change), and reads in
    /// between are free.
    private var cachedLiveEntries: [LiveEntry]?

    public init() {}

    public var liveEntries: [LiveEntry] {
        if let cached = cachedLiveEntries { return cached }
        let merged = (noteEntries + micAggregator.entries + systemAggregator.entries)
            .sorted(by: { $0.startMs < $1.startMs })
        let deduped = Self.dedupedAcrossChannels(merged)
        cachedLiveEntries = deduped
        return deduped
    }

    // MARK: - Cross-channel echo dedup

    /// When the mic leg and the system-audio (tap) leg both capture the same
    /// voices — e.g. a Zoom call with echo cancellation off, where the remote
    /// audio comes out the speakers AND is tapped directly — the same utterance
    /// is transcribed twice and diarized as two different speakers, littering
    /// the transcript with near-identical pairs. This collapses those: when a
    /// later entry is a near-duplicate of a recent one from a *different*
    /// speaker, it's dropped and the more complete text is kept in place.
    ///
    /// Deliberately conservative — only fires on different-speaker, non-note,
    /// non-translation entries of ≥6 normalised chars, within a 5s window, with
    /// high text overlap — so two people genuinely saying the same short thing
    /// aren't merged.
    private static let dedupWindowMs = 5000
    private static let dedupMinChars = 6
    private static let dedupJaccard = 0.8

    private static func dedupedAcrossChannels(_ entries: [LiveEntry]) -> [LiveEntry] {
        guard entries.count > 1 else { return entries }
        let echoMicIndices = Set(entries.indices.filter { index in
            micEntryIsCoveredBySystemContext(entries[index], in: entries)
        })
        var out: [LiveEntry] = []
        out.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if echoMicIndices.contains(index) { continue }
            guard isDedupCandidate(entry) else { out.append(entry); continue }
            var matchedIndex: Int? = nil
            var i = out.count - 1
            while i >= 0 {
                let prev = out[i]
                if entry.startMs - prev.startMs > dedupWindowMs { break }   // outside window (sorted asc)
                if isDedupCandidate(prev),
                   prev.speakerId != entry.speakerId,
                   nearDuplicate(prev.text, entry.text) {
                    matchedIndex = i
                    break
                }
                i -= 1
            }
            if let m = matchedIndex {
                // Keep the more complete transcription, in the earlier slot.
                if entry.text.count > out[m].text.count {
                    let kept = out[m]
                    out[m] = LiveEntry(
                        speakerId: kept.speakerId,
                        text: entry.text,
                        startMs: kept.startMs,
                        confidence: kept.confidence,
                        translationStatus: kept.translationStatus,
                        language: kept.language,
                        sourceLanguage: kept.sourceLanguage
                    )
                }
                // else: keep what we have, drop the duplicate.
            } else {
                out.append(entry)
            }
        }
        return out
    }

    /// A single mic echo can span two or more Soniox final batches from the
    /// direct system-audio leg. Pairwise comparison misses that shape and
    /// leaves alternating, repeated "speakers" in the transcript. Compare
    /// each mic fragment with the nearby direct-system context for one remote
    /// speaker before the existing pairwise fallback.
    private static func micEntryIsCoveredBySystemContext(
        _ entry: LiveEntry,
        in entries: [LiveEntry]
    ) -> Bool {
        guard isMicEntry(entry), isDedupCandidate(entry) else { return false }
        let needle = normalizeForSequenceMatch(entry.text)
        guard needle.count >= dedupMinChars else { return false }

        var systemContextBySpeaker: [String: [String]] = [:]
        for candidate in entries where isSystemEntry(candidate) && isDedupCandidate(candidate) {
            guard abs(candidate.startMs - entry.startMs) <= dedupWindowMs else { continue }
            systemContextBySpeaker[candidate.speakerId, default: []].append(candidate.text)
        }

        return systemContextBySpeaker.values.contains { fragments in
            let context = normalizeForSequenceMatch(fragments.joined(separator: " "))
            return context.contains(needle)
        }
    }

    private static func isDedupCandidate(_ e: LiveEntry) -> Bool {
        e.speakerId != "note" && e.translationStatus != "translation"
    }

    private static func isMicEntry(_ entry: LiveEntry) -> Bool {
        entry.speakerId == "self" || entry.speakerId.hasPrefix("room_")
    }

    private static func isSystemEntry(_ entry: LiveEntry) -> Bool {
        entry.speakerId.hasPrefix("remote_")
    }

    private static func nearDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalizeForDedup(a)
        let nb = normalizeForDedup(b)
        guard na.count >= dedupMinChars, nb.count >= dedupMinChars else { return false }
        let (shortStr, longStr) = na.count <= nb.count ? (na, nb) : (nb, na)
        if longStr.contains(shortStr) { return true }          // one is a truncation of the other
        let setA = Set(na), setB = Set(nb)                      // char-set Jaccard for STT variance
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 && Double(inter) / Double(union) >= dedupJaccard
    }

    private static func normalizeForSequenceMatch(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizeForDedup(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !drop.contains($0) })).lowercased()
    }

    public var interimLine: String? {
        let parts = [micAggregator.interimText, systemAggregator.interimText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Returns `true` when new final entries were appended (so the caller can
    /// republish the live list); `false` for interim-only frames, where only
    /// `interimLine` changed and the expensive `liveEntries` republish can be
    /// skipped.
    @discardableResult
    public func process(words: [SonioxWord], channel: String) -> Bool {
        let appended: Bool
        switch channel {
        case "mic": appended = micAggregator.process(words)
        case "system": appended = systemAggregator.process(words)
        default: appended = false
        }
        if appended { cachedLiveEntries = nil }
        return appended
    }

    /// Align the system channel's entries onto the mic timeline. `ms` is how
    /// much later the system-audio leg started than the mic leg; see
    /// `TranscriptAggregator.startMsOffset`.
    public func setSystemStartOffset(ms: Int) {
        systemAggregator.startMsOffset = ms
        cachedLiveEntries = nil
    }

    @discardableResult
    public func insertNote(_ text: String, startedAt: Date) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let offsetMs = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
        let entry = LiveEntry(
            speakerId: "note",
            text: trimmed,
            startMs: offsetMs,
            confidence: 1.0,
            translationStatus: "none",
            language: nil,
            sourceLanguage: nil
        )
        noteEntries.append(entry)
        if noteEntries.count > 500 { noteEntries.removeFirst(noteEntries.count - 500) }
        cachedLiveEntries = nil
        return true
    }

    public func reset() {
        micAggregator.reset()
        systemAggregator.reset()
        noteEntries = []
        cachedLiveEntries = nil
    }

    /// Keep the transcript across a Soniox reconnect (translation toggle),
    /// continuing the timeline so new finals append after the existing ones
    /// instead of being dropped or reordered. Notes are untouched.
    public func prepareForReconnect() {
        micAggregator.prepareForReconnect()
        systemAggregator.prepareForReconnect()
        cachedLiveEntries = nil
    }
}
