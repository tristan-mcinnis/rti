import Foundation

/// Per-channel live transcript aggregation: watermark dedup, ZeroMs dedup,
/// interim text tracking, and SpeakerTurn collapse.
///
/// Each channel (mic / system) gets its own instance so the dedup state
/// stays isolated. SessionCoordinator owns two instances and feeds words
/// from each Soniox connection into the correct one.
public final class TranscriptAggregator {

    public private(set) var entries: [LiveEntry] = []

    /// `entries` paired with the normalised text the live merge compares them
    /// by, positionally in step by construction: this type is the only place
    /// either collection is appended to, trimmed or cleared. Normalising
    /// belongs here rather than in the merge because the merge republishes up
    /// to eight times a second over a transcript that grows all session, and
    /// recomputing it per pass was 86% of the busy main thread in a 1h45m
    /// session (2026-09-22).
    private(set) var normalizedEntries: [NormalizedEntry] = []
    public private(set) var interimText: String? = nil
    private var lastEndMs: Int = 0
    private var zeroSeen: Set<String> = []
    private let channel: String

    /// Added to each emitted entry's `startMs` to put this channel on a
    /// common session timeline. Each Soniox stream counts `startMs` from its
    /// own first audio, but the system-audio leg starts later than the mic
    /// leg (it spins up after the CoreAudio tap / SCK is ready), so without
    /// this its entries would sort earlier than they actually occurred when
    /// merged with the mic channel. Set externally once the system leg
    /// starts; raw word timestamps (dedup watermark, zero-ms detection) are
    /// left untouched.
    public var startMsOffset: Int = 0

    public init(channel: String) {
        self.channel = channel
    }

    /// Callback that fires with each new batch of `SpeakerTurn`s that
    /// were just collapsed from final words. Callers can use the raw
    /// speaker indices for JSONL writing.
    var onTurnsProcessed: (([SpeakerTurn]) -> Void)?

    /// Returns `true` when new FINAL entries were appended to `entries` (so the
    /// owning pipeline knows to invalidate its merged cache and republish the
    /// live list). Interim-only frames return `false` — they update
    /// `interimText` but leave `entries` untouched, so callers can skip the
    /// expensive full-transcript republish on the bulk of frames.
    @discardableResult
    public func process(_ words: [SonioxWord]) -> Bool {
        let regularFinals = words.filter { $0.isFinal && $0.endMs > lastEndMs }
        let zeroMsFinals: [SonioxWord] = words.compactMap { word in
            guard word.isFinal, word.endMs == 0 else { return nil }
            let key = "\(word.speaker)|\(word.text)|\(word.startMs)"
            return zeroSeen.insert(key).inserted ? word : nil
        }
        let finals = regularFinals + zeroMsFinals
        let interims = words.filter { !$0.isFinal }

        if !finals.isEmpty {
            let runs = SpeakerTurn.collapse(finals)
            let newEntries = runs.map { run in
                LiveEntry(
                    speakerId: SpeakerLabelMapping.rawLabel(speaker: run.speaker, channel: channel),
                    text: run.text,
                    startMs: run.startMs + startMsOffset,
                    confidence: run.confidence,
                    translationStatus: run.translationStatus,
                    language: run.language,
                    sourceLanguage: run.sourceLanguage
                )
            }
            for entry in newEntries {
                entries.append(entry)
                normalizedEntries.append(NormalizedEntry(
                    entry: entry,
                    dedupText: TranscriptTextNormalization.dedup(entry.text),
                    sequenceText: TranscriptTextNormalization.sequence(entry.text)
                ))
            }
            // Soft safety bound only — was 500, which silently evicted all
            // but the last ~11 minutes of a 2-hour session (2026-06-11) and
            // truncated the archived transcript. Long sessions are the whole
            // point; text entries are tiny, so the bound exists purely as a
            // runaway guard.
            if entries.count > 50_000 {
                let dropped = entries.count - 50_000
                entries.removeFirst(dropped)
                normalizedEntries.removeFirst(dropped)
            }
            let nonZeroMax = finals.compactMap({ $0.endMs > 0 ? $0.endMs : nil }).max()
            if let m = nonZeroMax { lastEndMs = m }

            onTurnsProcessed?(runs)
        }

        if interims.isEmpty {
            interimText = nil
        } else {
            let runs = SpeakerTurn.collapse(interims)
            interimText = runs.map {
                "\(SpeakerLabelMapping.rawLabel(speaker: $0.speaker, channel: channel)): \($0.text)"
            }.joined(separator: "  ")
        }

        return !finals.isEmpty
    }

    public func reset() {
        entries = []
        normalizedEntries = []
        interimText = nil
        lastEndMs = 0
        zeroSeen = []
        startMsOffset = 0
    }

    /// Prepare for a mid-session Soniox reconnect (e.g. a translation toggle).
    /// Keeps the accumulated `entries`, but rolls the timeline offset forward to
    /// where we left off and resets the raw watermark — because the new stream
    /// restarts its word timestamps at ~0. Without this, the new stream's finals
    /// would be dropped by the `endMs > lastEndMs` watermark and/or sort to the
    /// top of the transcript.
    public func prepareForReconnect() {
        startMsOffset += lastEndMs
        lastEndMs = 0
        zeroSeen = []
        interimText = nil
    }

    /// A new stream opened on this channel `atMs` into the session: an
    /// automatic reconnect after a drop, or the system leg rejoining after it
    /// was parked while nothing played. Its word timestamps restart at 0, so
    /// place them at the moment the stream opened and reset the raw watermark.
    /// Without this, every final of the new stream was dropped until its clock
    /// passed the old stream's last `endMs`.
    public func restartStream(atMs: Int) {
        startMsOffset = atMs
        lastEndMs = 0
        zeroSeen = []
        interimText = nil
    }
}

/// One transcript entry plus the two normalised forms the live merge compares
/// it by. Built where the entry is appended, so the text is normalised once per
/// entry instead of once per merge pass.
struct NormalizedEntry {
    let entry: LiveEntry
    let dedupText: String
    let sequenceText: String
}

/// The text forms the live merge compares on. `dedup` drops whitespace,
/// punctuation and symbols for the near-duplicate test; `sequence` keeps only
/// alphanumerics as single-spaced words for the echo-containment test.
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
