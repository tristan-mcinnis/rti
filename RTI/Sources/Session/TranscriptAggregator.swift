import Foundation
import RTICore

/// Per-channel live transcript aggregation: watermark dedup, ZeroMs dedup,
/// interim text tracking, and SpeakerTurn collapse.
///
/// Each channel (mic / system) gets its own instance so the dedup state
/// stays isolated. SessionCoordinator owns two instances and feeds words
/// from each Soniox connection into the correct one.
@MainActor
final class TranscriptAggregator {

    private(set) var entries: [LiveEntry] = []
    private(set) var interimText: String? = nil
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
    var startMsOffset: Int = 0

    init(channel: String) {
        self.channel = channel
    }

    /// Callback that fires with each new batch of `SpeakerTurn`s that
    /// were just collapsed from final words. Callers can use the raw
    /// speaker indices for JSONL writing.
    var onTurnsProcessed: (([SpeakerTurn]) -> Void)?

    func process(_ words: [SonioxWord]) {
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
            }
            if entries.count > 500 {
                entries.removeFirst(entries.count - 500)
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
    }

    func reset() {
        entries = []
        interimText = nil
        lastEndMs = 0
        zeroSeen = []
        startMsOffset = 0
    }
}
