import XCTest

@MainActor
final class TranscriptAggregatorTests: XCTestCase {

    private func word(_ text: String, speaker: Int, start: Int, end: Int, isFinal: Bool = true) -> SonioxWord {
        SonioxWord(text: text, startMs: start, endMs: end, speaker: speaker, confidence: 1.0, isFinal: isFinal, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    func test_noOffset_emitsRawStartMs() {
        let agg = TranscriptAggregator(channel: "system")
        agg.process([word("hi", speaker: 0, start: 200, end: 400)])
        XCTAssertEqual(agg.entries.map(\.startMs), [200])
    }

    func test_offset_shiftsEmittedStartMs() {
        let agg = TranscriptAggregator(channel: "system")
        agg.startMsOffset = 1000
        agg.process([word("hi", speaker: 0, start: 200, end: 400)])
        XCTAssertEqual(agg.entries.map(\.startMs), [1200])
    }

    // The offset must not interfere with the end-ms watermark dedup, which
    // operates on raw word timestamps. A second batch whose end-ms advances
    // past the first should still be appended.
    func test_offset_doesNotBreakWatermarkDedup() {
        let agg = TranscriptAggregator(channel: "system")
        agg.startMsOffset = 1000
        agg.process([word("hi", speaker: 0, start: 0, end: 400)])
        agg.process([word("there", speaker: 0, start: 400, end: 800)])
        XCTAssertEqual(agg.entries.map(\.text), ["hi", "there"])
        XCTAssertEqual(agg.entries.map(\.startMs), [1000, 1400])
    }

    func test_reset_clearsOffset() {
        let agg = TranscriptAggregator(channel: "system")
        agg.startMsOffset = 1000
        agg.reset()
        agg.process([word("hi", speaker: 0, start: 200, end: 400)])
        XCTAssertEqual(agg.entries.map(\.startMs), [200])
    }
}
