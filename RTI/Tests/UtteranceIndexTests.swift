import RTICore
import XCTest

/// `TranscriptPipeline.utterances(includeNotes:)` must equal a full
/// `utterances(from:)` regroup at every point of a live call, while doing
/// only the new work. Invented Mandarin-like text only.
final class UtteranceIndexTests: XCTestCase {
    private static let syllables = Array("我们觉得这个品牌很好用但是价格有点贵平时跑步会买")

    /// A two-leg replay: the system leg answers late (2 to 4 s), sometimes
    /// very late (90 s, forcing a rebuild), with sentence ends, questions,
    /// notes, and a few translated tokens.
    private struct Replay {
        var rng = SeededGenerator(seed: 7)
        var clockMs = 0

        mutating func word(_ text: String, at ms: Int, translation: Bool = false) -> SonioxWord {
            SonioxWord(text: text, startMs: ms, endMs: ms + 220, speaker: 0, confidence: 1, isFinal: true,
                       translationStatus: translation ? "translation" : "none",
                       language: translation ? "en" : "zh", sourceLanguage: translation ? "zh" : nil)
        }

        /// One 2-second step of speech, delivered to the pipeline.
        mutating func step(_ pipeline: TranscriptPipeline, lateSystem: Bool = false) {
            let start = clockMs
            clockMs += 2000
            let leg = Int.random(in: 0 ..< 3, using: &rng) == 0 ? "system" : "mic"
            var words: [SonioxWord] = []
            var ms = start
            for index in 0 ..< 8 {
                let syllable = UtteranceIndexTests.syllables[Int.random(in: 0 ..< UtteranceIndexTests.syllables.count, using: &rng)]
                words.append(word(String(syllable), at: ms))
                if index == 7 {
                    words.append(word(Bool.random(using: &rng) ? "。" : "？", at: ms + 200))
                }
                ms += Int.random(in: 150 ... 400, using: &rng)
            }
            if Int.random(in: 0 ..< 10, using: &rng) == 0 {
                words.append(word(" We like it.", at: ms, translation: true))
            }
            if leg == "system" {
                let lag = lateSystem ? 90000 : Int.random(in: 2000 ... 4000, using: &rng)
                pipeline.process(words: words.map { shifted($0, by: -lag) }, channel: leg)
            } else {
                pipeline.process(words: words, channel: leg)
            }
            if Int.random(in: 0 ..< 40, using: &rng) == 0 {
                pipeline.insertNote("note \(start)", startedAt: Date().addingTimeInterval(-Double(start) / 1000))
            }
        }

        private func shifted(_ word: SonioxWord, by ms: Int) -> SonioxWord {
            SonioxWord(text: word.text, startMs: max(0, (word.providerStartMs ?? 0) + ms),
                       endMs: max(0, (word.providerEndMs ?? 0) + ms), speaker: 0, confidence: 1, isFinal: true,
                       translationStatus: word.providerTranslationStatus ?? "none", language: word.language,
                       sourceLanguage: word.sourceLanguage)
        }
    }

    private func describe(_ utterances: [LiveTranscriptPresentation.Utterance]) -> [String] {
        utterances.map { "\($0.speakerId)|\($0.startMs)|\($0.endMs)|\($0.includesPeerCorrection)|\($0.text)" }
    }

    private func full(_ pipeline: TranscriptPipeline, includeNotes: Bool) -> [String] {
        let entries = pipeline.liveEntries.filter {
            $0.translationStatus != "translation" && (includeNotes || $0.speakerId != "note")
        }
        return describe(LiveTranscriptPresentation.utterances(from: entries))
    }

    func testIndexEqualsFullRegroupThroughALongCall() {
        let pipeline = TranscriptPipeline()
        var replay = Replay()
        for step in 1 ... 900 {
            replay.step(pipeline, lateSystem: step == 400)
            if step.isMultiple(of: 7) || step == 400 || step == 401 {
                XCTAssertEqual(describe(pipeline.utterances(includeNotes: false)), full(pipeline, includeNotes: false), "step \(step)")
                XCTAssertEqual(describe(pipeline.utterances(includeNotes: true)), full(pipeline, includeNotes: true), "step \(step)")
            }
        }
        // One build each, plus one each for the 90 s late packet; the rest
        // of the half hour is incremental.
        XCTAssertLessThanOrEqual(pipeline.utteranceIndexRebuilds, 4)
    }

    func testResetAndNotesReplayRebuild() {
        let pipeline = TranscriptPipeline()
        var replay = Replay()
        for _ in 0 ..< 50 {
            replay.step(pipeline)
        }
        XCTAssertEqual(describe(pipeline.utterances(includeNotes: true)), full(pipeline, includeNotes: true))
        pipeline.replaceNotes([])
        pipeline.reset()
        XCTAssertTrue(pipeline.utterances(includeNotes: true).isEmpty)
        for _ in 0 ..< 20 {
            replay.step(pipeline)
        }
        XCTAssertEqual(describe(pipeline.utterances(includeNotes: true)), full(pipeline, includeNotes: true))
    }

    /// Pass prep reads the index every 120 s. At two hours a read must cost
    /// about what it costs at 30 minutes, not four times as much, and far
    /// less than a full regroup. Timing assertions are opt-in
    /// (`RTI_TIMING_TESTS=1`); the numbers always go to the test log.
    func testReadCostStaysFlatOverTwoHours() {
        let pipeline = TranscriptPipeline()
        var replay = Replay()
        var incremental: [Int: Double] = [:]
        var regroup: [Int: Double] = [:]
        _ = pipeline.utterances(includeNotes: false)
        for step in 1 ... 3600 {
            replay.step(pipeline)
            guard step.isMultiple(of: 60) else { continue }
            let minute = step * 2 / 60
            let start = DispatchTime.now().uptimeNanoseconds
            _ = pipeline.utterances(includeNotes: false)
            let middle = DispatchTime.now().uptimeNanoseconds
            if minute == 30 || minute == 120 {
                _ = LiveTranscriptPresentation.utterances(from: pipeline.liveEntries.filter { $0.speakerId != "note" && $0.translationStatus != "translation" })
                regroup[minute] = Double(DispatchTime.now().uptimeNanoseconds - middle) / 1_000_000
            }
            incremental[minute] = Double(middle - start) / 1_000_000
        }
        let at30 = incremental[30] ?? 0
        let at120 = incremental[120] ?? 0
        print("UtteranceIndex read ms: min30 \(at30), min120 \(at120); full regroup ms: min30 \(regroup[30] ?? 0), min120 \(regroup[120] ?? 0)")
        XCTAssertEqual(pipeline.utteranceIndexRebuilds, 1)
        guard ProcessInfo.processInfo.environment["RTI_TIMING_TESTS"] == "1" else { return }
        XCTAssertLessThan(at120, (regroup[120] ?? 0) / 4)
        XCTAssertLessThan(at120, 5)
    }
}

/// A small deterministic generator, so a failing step can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
