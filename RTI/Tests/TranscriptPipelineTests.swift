import RTICore
import XCTest

/// Pins TranscriptPipeline's cross-channel merge, note buffering, and offset
/// behavior — the combined live transcript the UI observes.
final class TranscriptPipelineTests: XCTestCase {
    private func word(_ text: String, speaker: Int, start: Int, end: Int) -> SonioxWord {
        SonioxWord(
            text: text,
            startMs: start,
            endMs: end,
            speaker: speaker,
            confidence: 1.0,
            isFinal: true,
            translationStatus: "none",
            language: nil,
            sourceLanguage: nil
        )
    }

    func test_process_micWords_appearInLiveEntries() {
        let p = TranscriptPipeline()
        p.process(words: [word("hello", speaker: 0, start: 0, end: 100)], channel: "mic")
        XCTAssertEqual(p.liveEntries.map(\.text), ["hello"])
    }

    func test_liveEntries_mergedAcrossChannelsSortedByStartMs() {
        let p = TranscriptPipeline()
        p.process(words: [word("later-mic", speaker: 0, start: 1000, end: 1100)], channel: "mic")
        p.process(words: [word("earlier-sys", speaker: 0, start: 200, end: 300)], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.text), ["earlier-sys", "later-mic"])
    }

    func test_setSystemStartOffset_shiftsSystemEntriesOntoMicTimeline() {
        let p = TranscriptPipeline()
        p.setSystemStartOffset(ms: 5000)
        p.process(words: [word("mic", speaker: 0, start: 1000, end: 1100)], channel: "mic")
        p.process(words: [word("sys", speaker: 0, start: 200, end: 300)], channel: "system")
        // System entry started at 200 but the leg began 5000ms late → 5200,
        // so it now sorts after the mic entry at 1000.
        XCTAssertEqual(p.liveEntries.map(\.text), ["mic", "sys"])
    }

    func test_insertNote_addsNoteEntry() {
        let p = TranscriptPipeline()
        XCTAssertTrue(p.insertNote("  remember this  ", startedAt: Date()))
        let notes = p.liveEntries.filter { $0.speakerId == "note" }
        XCTAssertEqual(notes.map(\.text), ["remember this"]) // trimmed
    }

    func test_insertNote_blankText_isRejected() {
        let p = TranscriptPipeline()
        XCTAssertFalse(p.insertNote("   \n ", startedAt: Date()))
        XCTAssertTrue(p.liveEntries.isEmpty)
    }

    func test_reset_clearsEverything() {
        let p = TranscriptPipeline()
        p.process(words: [word("x", speaker: 0, start: 0, end: 100)], channel: "mic")
        _ = p.insertNote("note", startedAt: Date())
        p.reset()
        XCTAssertTrue(p.liveEntries.isEmpty)
        XCTAssertNil(p.interimLine)
    }
}
