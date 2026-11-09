import Foundation

/// Per-channel live transcript aggregation and note buffering. Owns the
/// `TranscriptAggregator`s and the note entry list; produces the combined
/// `liveEntries` and `interimLine` that the UI observes. This module owns only
/// live state; SessionCoordinator snapshots it for the session archive.
public final class TranscriptPipeline {

    private let micAggregator = TranscriptAggregator(channel: "mic")
    private let systemAggregator = TranscriptAggregator(channel: "system")
    private var noteEntries: [LiveEntry] = []

    /// Lazily-rebuilt merge of both channels + notes, sorted by `startMs`,
    /// invalidated only when entries change. A rebuild redoes only the open
    /// part of the session: everything before the settled cut is already
    /// folded into `settled`, so a long call costs no more per final than a
    /// short one.
    private var cachedLiveEntries: [LiveEntry]?

    /// The dedup pass's state after folding the first `notes`, `mic` and
    /// `system` entries, which all start before every open entry. No final
    /// starting at or after `untilMs` can change a folded entry's echo or
    /// coverage verdict: it is a run gap and a dedup window away. An earlier
    /// final resets this; a changed ID shows eviction. System entries before
    /// `skip` are too early to be echo or coverage context for an open one.
    private struct Settled {
        var out: [LiveEntry] = [], forms: [ComparisonForm] = []
        var notes = 0, mic = 0, system = 0, skip = 0, untilMs = Int.min
        var micID: UUID?, systemID: UUID?
    }
    private var settled = Settled()
    /// Settle only this far behind the newest final: one leg's finals can
    /// trail the other's.
    private static let settleLagMs = 30_000

    private struct ComparisonForm {
        let text: String
        let count: Int
        let characters: Set<Character>

        init(_ text: String) {
            self.text = text
            count = text.count
            characters = Set(text)
        }
    }

    public init() {}

    public var liveEntries: [LiveEntry] {
        if let cached = cachedLiveEntries { return cached }
        // Notes are never dedup candidates, so they carry no normalised text.
        let notes = noteEntries.map { NormalizedEntry(entry: $0, dedupText: "", sequenceText: "") }
        let mic = micAggregator.normalizedEntries, system = systemAggregator.normalizedEntries
        var s = settled
        if s.notes > notes.count || s.mic > mic.count || s.system > system.count
            || (s.mic > 0 && mic[s.mic - 1].entry.id != s.micID)
            || (s.system > 0 && system[s.system - 1].entry.id != s.systemID) { s = Settled() }
        let open = Array(mic[s.mic...]), heard = system[s.skip...].sorted { $0.entry.startMs < $1.entry.startMs }
        var merged = Array(notes[s.notes...]) + withoutEcho(open, system: heard) + system[s.system...]
        merged.sort(by: { $0.entry.startMs < $1.entry.startMs })

        // The latest cut before `horizon` that leaves every open mic word a
        // run gap after the folded ones, and splits notes and system by time.
        var later = open.map { Self.earliest($0.entry) } + [.max]
        for i in open.indices.reversed() { later[i] = min(later[i], later[i + 1]) }
        let horizon = max(mic.last?.entry.startMs ?? 0, system.last?.entry.startMs ?? 0) - Self.settleLagMs
        func split(_ list: ArraySlice<NormalizedEntry>, _ beforeMs: Int) -> Int? {
            let count = list.prefix { $0.entry.startMs < beforeMs }.count
            return list.dropFirst(count).allSatisfy { $0.entry.startMs >= beforeMs } ? count : nil
        }
        var micCut: (mic: Int, beforeMs: Int, untilMs: Int)?
        var maxStart = Int.min, maxEnd = Int.min
        for i in later.indices {
            let beforeMs = min(later[i], horizon)
            let untilMs = max(s.untilMs, beforeMs, maxEnd + EchoFilter.runGapMs, maxStart + Self.dedupWindowMs + 1)
            guard untilMs <= horizon else { break }
            if maxStart < beforeMs, later[i] >= maxEnd + EchoFilter.runGapMs { micCut = (i, beforeMs, untilMs) }
            guard i < open.count else { break }
            maxStart = open[i].entry.tokens.reduce(max(maxStart, open[i].entry.startMs)) { max($0, $1.startMs) }
            maxEnd = open[i].entry.tokens.reduce(maxEnd) { max($0, $1.endMs) }
        }
        var cut: (mic: Int, notes: Int, system: Int, beforeMs: Int, untilMs: Int)?
        if let c = micCut, let n = split(notes[s.notes...], c.beforeMs), let y = split(system[s.system...], c.beforeMs) {
            cut = (c.mic, n, y, c.beforeMs, c.untilMs)
        }

        let folded = cut.map { cut in merged.prefix { $0.entry.startMs < cut.beforeMs }.count } ?? 0
        for item in merged[..<folded] where !Self.covered(item, by: heard) { Self.fold(item, into: &s.out, &s.forms) }
        var out = s.out, forms = s.forms
        for item in merged[folded...] where !Self.covered(item, by: heard) { Self.fold(item, into: &out, &forms) }
        if let cut {
            s.notes += cut.notes
            s.mic += cut.mic
            s.system += cut.system
            s.micID = s.mic > 0 ? mic[s.mic - 1].entry.id : nil
            s.systemID = s.system > 0 ? system[s.system - 1].entry.id : nil
            s.untilMs = cut.untilMs
            while s.skip < system.count, system[s.skip].entry.startMs < cut.beforeMs - Self.dedupWindowMs,
                  system[s.skip].entry.tokens.allSatisfy({ $0.startMs < cut.beforeMs - EchoFilter.windowMs }) { s.skip += 1 }
        }
        settled = s
        let untimed = (micAggregator.untimedTranslations + systemAggregator.untimedTranslations)
            .sorted { $0.startMs < $1.startMs }
        let result = Self.slot(untimed, into: out)
        cachedLiveEntries = result
        return result
    }

    /// Untimed translations (`TranscriptAggregator.untimedTranslations`) sit
    /// at their stream's start, after notes and mic entries of the same
    /// `startMs` when they come from the system leg, and after the timed
    /// entries of their own leg.
    private static func slot(_ untimed: [LiveEntry], into out: [LiveEntry]) -> [LiveEntry] {
        func key(_ e: LiveEntry) -> (Int, Int) { (e.startMs, e.speakerId == "note" ? 0 : isMicEntry(e) ? 1 : 2) }
        var result: [LiveEntry] = [], next = 0
        result.reserveCapacity(out.count + untimed.count)
        for entry in out {
            while next < untimed.count, key(untimed[next]) < key(entry) {
                result.append(untimed[next])
                next += 1
            }
            result.append(entry)
        }
        return result + untimed[next...]
    }

    // MARK: - Cross-channel echo dedup

    /// Final entries never change, so each keeps its assembled words here
    /// rather than normalising the whole session on every pass.
    private var echoSources: [UUID: EchoFilter.Source] = [:]

    private func echoSource(_ entry: LiveEntry) -> EchoFilter.Source {
        if let cached = echoSources[entry.id] { return cached }
        let source = EchoFilter.Source(speakerId: entry.speakerId, tokens: entry.tokens)
        echoSources[entry.id] = source
        return source
    }

    /// The mic entries with the room's echo of the system leg removed, word
    /// by word (`EchoFilter`). The batch dedup below remains for entries
    /// without timed tokens.
    private func withoutEcho(_ mic: [NormalizedEntry], system: [NormalizedEntry]) -> [NormalizedEntry] {
        let echo = EchoFilter.echoTokens(mic: mic.map { echoSource($0.entry) },
                                         system: system.map { echoSource($0.entry) })
        return zip(mic, echo).compactMap { merged, dropped in
            guard !dropped.isEmpty else { return merged }
            let entry = merged.entry
            let kept = entry.tokens.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
            guard let first = kept.first else { return nil }
            let text = kept.map(\.text).joined()
            let trimmed = LiveEntry(
                speakerId: entry.speakerId, text: text, startMs: first.startMs, confidence: entry.confidence,
                translationStatus: entry.translationStatus, language: entry.language, sourceLanguage: entry.sourceLanguage,
                id: entry.id, textOrigin: entry.textOrigin, streamID: entry.streamID, tokens: kept
            )
            return NormalizedEntry(entry: trimmed, dedupText: TranscriptTextNormalization.dedup(text),
                                   sequenceText: TranscriptTextNormalization.sequence(text))
        }
    }

    /// Mic interims judged against everything the system leg has said
    /// nearby: its interims and its recent finals.
    private static func interimsWithoutEcho(
        mic: [LiveTranscriptPresentation.InterimSegment],
        system: [LiveTranscriptPresentation.InterimSegment],
        systemFinals: [LiveEntry]
    ) -> [LiveTranscriptPresentation.InterimSegment] {
        guard !mic.isEmpty else { return mic }
        let earliest = mic.compactMap { $0.tokens.first?.startMs }.min() ?? 0
        // A final batch rarely runs a minute; older ones cannot overlap.
        let recent = systemFinals.reversed().prefix { $0.startMs >= earliest - 60_000 }
        let heard = system.map { EchoFilter.Source(speakerId: $0.speakerId, tokens: $0.tokens) }
            + recent.map { EchoFilter.Source(speakerId: $0.speakerId, tokens: $0.tokens) }
        let echo = EchoFilter.echoTokens(mic: mic.map { EchoFilter.Source(speakerId: $0.speakerId, tokens: $0.tokens) },
                                         system: heard)
        return zip(mic, echo).compactMap { segment, dropped in
            guard !dropped.isEmpty else { return segment }
            let kept = segment.tokens.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
            guard let first = kept.first else { return nil }
            return LiveTranscriptPresentation.InterimSegment(
                speakerId: segment.speakerId, text: kept.map(\.text).joined(), textOrigin: segment.textOrigin,
                startMs: first.startMs, translationStatus: segment.translationStatus, language: segment.language,
                streamID: segment.streamID, tokens: kept
            )
        }
    }

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

    /// One step of the dedup pass, in `startMs` order: `entry` joins `out`
    /// unless it duplicates a recent one, whose slot then keeps the more
    /// complete text.
    private static func fold(_ merged: NormalizedEntry, into out: inout [LiveEntry], _ forms: inout [ComparisonForm]) {
        let entry = merged.entry, form = ComparisonForm(merged.dedupText)
        let window = out.indices.reversed().prefix { entry.startMs - out[$0].startMs <= dedupWindowMs }
        guard isDedupCandidate(entry), let m = window.first(where: {
            isDedupCandidate(out[$0]) && out[$0].speakerId != entry.speakerId && nearDuplicate(forms[$0], form)
        }) else {
            out.append(entry)
            forms.append(form)
            return
        }
        // Keep the more complete transcription, in the earlier slot.
        guard entry.text.count > out[m].text.count else { return }
        let kept = out[m]
        // The peer's token boundaries belong to another socket.
        // Replace the interior, retaining the canonical fragment's
        // exact edges so neither neighbour gains or loses spacing.
        let leading = kept.text.prefix(while: \.isWhitespace)
        let trailing = kept.text.reversed().prefix(while: \.isWhitespace).reversed()
        let correctedText = String(leading)
            + entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            + String(trailing)
        // No word alignment was established for this substitution.
        // Leave timed tokens empty rather than inventing timestamps.
        out[m] = LiveEntry(
            speakerId: kept.speakerId,
            text: correctedText,
            startMs: kept.startMs,
            confidence: kept.confidence,
            translationStatus: kept.translationStatus,
            language: kept.language,
            sourceLanguage: kept.sourceLanguage,
            id: kept.id,
            textOrigin: .providerCorrection(continuingStreamID: kept.displayStreamID),
            streamID: entry.streamID
        )
        // That slot's text just changed, so its normal form must follow it:
        // later entries compare against this one.
        forms[m] = form
    }

    /// A single mic echo can span two or more Soniox final batches from the
    /// direct system-audio leg. Pairwise comparison misses that shape and
    /// leaves alternating, repeated "speakers" in the transcript. Compare
    /// each mic fragment with the nearby direct-system context for one remote
    /// speaker before the existing pairwise fallback.
    private static func covered(_ merged: NormalizedEntry, by system: [NormalizedEntry]) -> Bool {
        let entry = merged.entry
        guard isMicEntry(entry), isDedupCandidate(entry), merged.sequenceText.count >= dedupMinChars else { return false }
        // `system` is sorted by `startMs`: bisect to the window's first entry.
        var low = 0, high = system.count
        while low < high {
            let mid = (low + high) / 2
            if system[mid].entry.startMs < entry.startMs - dedupWindowMs { low = mid + 1 } else { high = mid }
        }
        var systemContextBySpeaker: [String: [String]] = [:]
        for candidate in system[low...].lazy.map(\.entry).prefix(while: { $0.startMs <= entry.startMs + dedupWindowMs })
        where isDedupCandidate(candidate) {
            systemContextBySpeaker[candidate.speakerId, default: []].append(candidate.text)
        }
        return systemContextBySpeaker.values.contains { fragments in
            TranscriptTextNormalization.sequence(fragments.joined(separator: " ")).contains(merged.sequenceText)
        }
    }

    private static func earliest(_ entry: LiveEntry) -> Int {
        entry.tokens.reduce(entry.startMs) { min($0, $1.startMs) }
    }

    private static func isDedupCandidate(_ e: LiveEntry) -> Bool {
        e.speakerId != "note" && e.translationStatus != "translation"
    }

    private static func isMicEntry(_ entry: LiveEntry) -> Bool {
        entry.speakerId == "self" || entry.speakerId.hasPrefix("room_")
    }

    private static func nearDuplicate(_ a: ComparisonForm, _ b: ComparisonForm) -> Bool {
        if a.count < dedupMinChars || b.count < dedupMinChars { return false }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if long.text.contains(short.text) { return true }
        let intersection = a.characters.reduce(0) { $0 + (b.characters.contains($1) ? 1 : 0) }
        let union = a.characters.count + b.characters.count - intersection
        return union > 0 && Double(intersection) / Double(union) >= dedupJaccard
    }

    public var interimLine: String? {
        let parts = [micAggregator.interimText, systemAggregator.interimText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Native presentation consumes the raw fragments, not the legacy labelled
    /// line: encoding and parsing that line loses provider whitespace.
    public var interimSegments: [LiveTranscriptPresentation.InterimSegment] {
        let mic = Self.interimsWithoutEcho(mic: micAggregator.interimSegments,
                                           system: systemAggregator.interimSegments,
                                           systemFinals: systemAggregator.entries)
        return (mic + systemAggregator.interimSegments)
            .sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
    }

    /// Returns `true` when new final entries were appended (so the caller can
    /// republish the live list); `false` for interim-only frames, where only
    /// `interimLine` changed and the expensive `liveEntries` republish can be
    /// skipped.
    @discardableResult
    public func process(words: [SonioxWord], channel: String) -> Bool {
        let aggregator: TranscriptAggregator
        switch channel {
        case "mic": aggregator = micAggregator
        case "system": aggregator = systemAggregator
        default: return false
        }
        let before = (aggregator.entries.count, aggregator.untimedTranslations.count)
        guard aggregator.process(words) else { return false }
        cachedLiveEntries = nil
        // A timed final that starts before the settled cut reopens the session.
        let untimed = Set(aggregator.untimedTranslations.dropFirst(before.1).map(\.id))
        if aggregator.entries.dropFirst(before.0).contains(where: { !untimed.contains($0.id) && Self.earliest($0) < settled.untilMs }) {
            settled = Settled()
        }
        return true
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
        if noteEntries.count > 500 || offsetMs < settled.untilMs { settled = Settled() }
        if noteEntries.count > 500 { noteEntries.removeFirst(noteEntries.count - 500) }
        cachedLiveEntries = nil
        return true
    }

    public func reset() {
        micAggregator.reset()
        systemAggregator.reset()
        noteEntries = []
        echoSources = [:]
        settled = Settled()
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
