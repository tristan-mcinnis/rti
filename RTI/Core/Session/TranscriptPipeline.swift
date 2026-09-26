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
    ///
    /// That cache still left the merge itself rebuilding from scratch, and the
    /// 2026-09-22 1h45m profile put the merge at 86% of the busy main thread.
    /// Normalising each entry's text is the only allocation-heavy step in it,
    /// and it is done once per entry by the aggregator that owns the entry
    /// (`TranscriptAggregator.normalizedEntries`), then reused by every later
    /// merge instead of being recomputed on each of up to eight publishes a
    /// second.
    private var cachedLiveEntries: [LiveEntry]?

    public init() {}

    public var liveEntries: [LiveEntry] {
        if let cached = cachedLiveEntries { return cached }
        let micEntries = micAggregator.normalizedEntries
        let systemEntries = systemAggregator.normalizedEntries
        var merged: [NormalizedEntry] = []
        merged.reserveCapacity(noteEntries.count + micEntries.count + systemEntries.count)
        // Notes are never dedup candidates, so they carry no normalised text.
        for note in noteEntries {
            merged.append(NormalizedEntry(entry: note, dedupText: "", sequenceText: ""))
        }
        merged.append(contentsOf: micEntries)
        merged.append(contentsOf: systemEntries)
        merged.sort(by: { $0.entry.startMs < $1.entry.startMs })
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

    private static func dedupedAcrossChannels(_ entries: [NormalizedEntry]) -> [LiveEntry] {
        guard entries.count > 1 else { return entries.map(\.entry) }

        // Direct-system entries, in `entries` order (already sorted by
        // `startMs`), so each mic entry's ±5s echo window is a bisected slice
        // of this list instead of a re-scan of the whole transcript. That scan
        // was the pass's quadratic term (2026-09-22).
        var systemPositions: [Int] = []
        for (index, entry) in entries.enumerated() where isSystemEntry(entry.entry) {
            systemPositions.append(index)
        }

        let echoMicIndices = Set(entries.indices.filter { index in
            micEntryIsCoveredBySystemContext(
                entries[index],
                systemPositions: systemPositions,
                entries: entries
            )
        })
        var out: [LiveEntry] = []
        var outDedupText: [String] = []
        out.reserveCapacity(entries.count)
        outDedupText.reserveCapacity(entries.count)
        for (index, merged) in entries.enumerated() {
            let entry = merged.entry
            if echoMicIndices.contains(index) { continue }
            guard isDedupCandidate(entry) else {
                out.append(entry)
                outDedupText.append(merged.dedupText)
                continue
            }
            var matchedIndex: Int? = nil
            var i = out.count - 1
            while i >= 0 {
                let prev = out[i]
                if entry.startMs - prev.startMs > dedupWindowMs { break }   // outside window (sorted asc)
                if isDedupCandidate(prev),
                   prev.speakerId != entry.speakerId,
                   nearDuplicate(outDedupText[i], merged.dedupText) {
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
                    // That slot's text just changed, so its cached normal form
                    // must follow it: later entries compare against this one.
                    outDedupText[m] = merged.dedupText
                }
                // else: keep what we have, drop the duplicate.
            } else {
                out.append(entry)
                outDedupText.append(merged.dedupText)
            }
        }
        return out
    }

    /// A single mic echo can span two or more Soniox final batches from the
    /// direct system-audio leg. Pairwise comparison misses that shape and
    /// leaves alternating, repeated "speakers" in the transcript. Compare
    /// each mic fragment with the nearby direct-system context for one remote
    /// speaker before the existing pairwise fallback.
    /// `systemPositions` holds every direct-system entry's index in `entries`,
    /// in ascending `startMs`, so this compares against the ±5s window only:
    /// scanning every entry once per mic entry was the pass's other quadratic
    /// term.
    private static func micEntryIsCoveredBySystemContext(
        _ merged: NormalizedEntry,
        systemPositions: [Int],
        entries: [NormalizedEntry]
    ) -> Bool {
        let entry = merged.entry
        guard isMicEntry(entry), isDedupCandidate(entry) else { return false }
        guard merged.sequenceText.count >= dedupMinChars else { return false }

        let upperMs = entry.startMs + dedupWindowMs
        var systemContextBySpeaker: [String: [String]] = [:]
        var slot = firstSystemSlot(systemPositions, entries: entries, atOrAfter: entry.startMs - dedupWindowMs)
        while slot < systemPositions.count {
            let candidate = entries[systemPositions[slot]].entry
            if candidate.startMs > upperMs { break }
            if isDedupCandidate(candidate) {
                systemContextBySpeaker[candidate.speakerId, default: []].append(candidate.text)
            }
            slot += 1
        }

        return systemContextBySpeaker.values.contains { fragments in
            let context = TranscriptTextNormalization.sequence(fragments.joined(separator: " "))
            return context.contains(merged.sequenceText)
        }
    }

    /// Bisects `systemPositions` (ascending `startMs`) for the first slot whose
    /// entry starts at or after `ms`.
    private static func firstSystemSlot(
        _ systemPositions: [Int],
        entries: [NormalizedEntry],
        atOrAfter ms: Int
    ) -> Int {
        var low = 0
        var high = systemPositions.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[systemPositions[mid]].entry.startMs < ms {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
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

    /// Both sides arrive already normalised: the caller normalises each entry
    /// once per pass rather than once per pair.
    private static func nearDuplicate(_ na: String, _ nb: String) -> Bool {
        guard na.count >= dedupMinChars, nb.count >= dedupMinChars else { return false }
        let (shortStr, longStr) = na.count <= nb.count ? (na, nb) : (nb, na)
        if longStr.contains(shortStr) { return true }          // one is a truncation of the other
        let setA = Set(na), setB = Set(nb)                      // char-set Jaccard for STT variance
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 && Double(inter) / Double(union) >= dedupJaccard
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

    /// One leg opened a new stream `atMs` into the session; see
    /// `TranscriptAggregator.restartStream(atMs:)`.
    public func restartStream(channel: String, atMs: Int) {
        switch channel {
        case "mic": micAggregator.restartStream(atMs: atMs)
        case "system": systemAggregator.restartStream(atMs: atMs)
        default: return
        }
        cachedLiveEntries = nil
    }
}
