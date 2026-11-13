import RTICore
import XCTest

/// A long turn is drawn as bounded blocks, and the live projection builds
/// the same blocks incrementally as a full regroup does. Invented text only.
final class LiveTranscriptBlockTests: XCTestCase {
    private let stream = UUID()

    /// One row: a sentence of four words, 100 ms apart.
    private func entry(_ index: Int, endsSentence: Bool = true, speaker: String = "remote") -> LiveEntry {
        let start = index * 3000
        let words = ["Row", " \(index)", " says", endsSentence ? " this." : " this"]
        let tokens = words.enumerated().map { offset, word in
            LiveEntry.TimedToken(text: word, startMs: start + offset * 100, endMs: start + offset * 100 + 80)
        }
        return LiveEntry(speakerId: speaker, text: words.joined(), startMs: start, confidence: 1, translationStatus: "none",
                         language: nil, sourceLanguage: nil, textOrigin: .providerTokens, streamID: stream, tokens: tokens)
    }

    private func rows(_ entries: [LiveEntry]) -> LiveTranscriptPresentation.LiveRows {
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(entries)
        return projection.updateInterims([])
    }

    func testALongTurnSplitsIntoLabelledHeadAndContinuationBlocks() {
        let all = rows((0 ..< 40).map { entry($0) })
        let blocks = LiveTranscriptPresentation.turns(all)
        XCTAssertEqual(blocks.map(\.rows.count), [12, 12, 12, 4])
        XCTAssertEqual(blocks.map(\.isContinuation), [false, true, true, true])
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, "each block has its own id")
        // Blocks break only where a paragraph breaks anyway.
        let single = LiveTranscriptPresentation.Turn(rows: Array(all))
        XCTAssertEqual(blocks.map(\.text).joined(separator: "\n\n"), single.text)
    }

    func testABlockWaitsForASentenceEndThenForcesABreak() {
        let open = (0 ..< 30).map { entry($0, endsSentence: $0 == 14) }
        let blocks = LiveTranscriptPresentation.turns(rows(open))
        XCTAssertEqual(blocks.map(\.rows.count), [15, 15], "past 12 rows the block ends after the first sentence end")
        let never = (0 ..< 30).map { entry($0, endsSentence: false) }
        XCTAssertEqual(LiveTranscriptPresentation.turns(rows(never)).map(\.rows.count), [24, 6], "no sentence end: forced at 24 rows")
    }

    func testABlockAlsoEndsAfterTwoMinutes() {
        // Rows 20 s apart: the seventh row is two minutes after the first.
        let spaced = (0 ..< 10).map { index -> LiveEntry in
            let base = entry(index)
            let shift = index * 17000
            return LiveEntry(speakerId: base.speakerId, text: base.text, startMs: base.startMs + shift, confidence: 1,
                             translationStatus: "none", language: nil, sourceLanguage: nil, textOrigin: .providerTokens,
                             streamID: stream, tokens: base.tokens.map {
                                 LiveEntry.TimedToken(text: $0.text, startMs: $0.startMs + shift, endMs: $0.endMs + shift)
                             })
        }
        XCTAssertEqual(LiveTranscriptPresentation.turns(rows(spaced)).map(\.rows.count), [6, 4])
    }

    /// The live projection adds rows one flush at a time. Its blocks must
    /// equal a full regroup of the same rows at every step.
    func testIncrementalProjectionMatchesAFullRegroup() {
        let pipeline = TranscriptPipeline()
        var projection = LiveTranscriptPresentation.Projection()
        for index in 0 ..< 45 {
            let speaker = index == 30 ? "self" : "remote"
            let start = index * 3000
            let words = ["Row", " \(index)", index % 5 == 0 ? " ends" : " goes", index % 3 == 0 ? " on" : " here."]
            pipeline.process(words: words.enumerated().map { offset, word in
                SonioxWord(text: word, startMs: start + offset * 100, endMs: start + offset * 100 + 80, speaker: 0,
                           confidence: 1, isFinal: true, translationStatus: "none", language: "en", sourceLanguage: nil)
            }, channel: speaker == "self" ? "mic" : "system")
            projection.updateLiveFinals(pipeline, labelsEnabled: false)
            let live = projection.updateInterims([])
            let incremental = projection.turns(for: live)
            let full = LiveTranscriptPresentation.turns(live)
            XCTAssertEqual(incremental.map(\.id), full.map(\.id), "step \(index)")
            XCTAssertEqual(incremental.map(\.isContinuation), full.map(\.isContinuation), "step \(index)")
            XCTAssertEqual(incremental.map(\.text), full.map(\.text), "step \(index)")
        }
    }
}
