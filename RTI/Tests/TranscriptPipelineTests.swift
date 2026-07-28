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

    // MARK: - Cross-channel echo dedup

    func test_crossChannel_echo_collapsesNearDuplicate() {
        let p = TranscriptPipeline()
        // System tap captures the full line; the mic re-hears the same audio a
        // beat later, slightly truncated, diarized as a different speaker.
        p.process(words: [word("我下了班的时候会进行力量训练", speaker: 0, start: 1000, end: 2000)], channel: "system")
        p.process(words: [word("下了班的时候会进行力量训练", speaker: 2, start: 1300, end: 2200)], channel: "mic")
        XCTAssertEqual(p.liveEntries.count, 1, "echo pair should collapse to one entry")
        XCTAssertEqual(p.liveEntries.first?.text, "我下了班的时候会进行力量训练", "the more complete text is kept")
    }

    func test_crossChannel_keepsLongerTextInEarlierSlot() {
        let p = TranscriptPipeline()
        // The earlier (mic) leg is truncated; the later (system) leg is fuller.
        p.process(words: [word("下了班会进行力量训练", speaker: 2, start: 1000, end: 2000)], channel: "mic")
        p.process(words: [word("我下了班会进行力量训练", speaker: 0, start: 1200, end: 2100)], channel: "system")
        XCTAssertEqual(p.liveEntries.count, 1)
        XCTAssertEqual(p.liveEntries.first?.text, "我下了班会进行力量训练", "fuller transcription wins")
    }

    func test_crossChannel_distinctContent_isKept() {
        let p = TranscriptPipeline()
        p.process(words: [word("我每天早上都会去跑步", speaker: 0, start: 1000, end: 1100)], channel: "system")
        p.process(words: [word("我比较喜欢撸铁和普拉提", speaker: 2, start: 1200, end: 1300)], channel: "mic")
        XCTAssertEqual(p.liveEntries.count, 2, "genuinely different lines must not be merged")
    }

    func test_crossChannel_outsideTimeWindow_isKept() {
        let p = TranscriptPipeline()
        p.process(words: [word("我下了班的时候会进行力量训练", speaker: 0, start: 1000, end: 2000)], channel: "system")
        // Same text but 6s later — beyond the 5s echo window, so a real repeat.
        p.process(words: [word("我下了班的时候会进行力量训练", speaker: 2, start: 8000, end: 9000)], channel: "mic")
        XCTAssertEqual(p.liveEntries.count, 2, "matches outside the echo window are not deduped")
    }

    func test_crossChannel_echoSplitAcrossFinalBatches_collapsesMicFragment() {
        let p = TranscriptPipeline()
        // This is the shape seen in the live transcript: the direct system leg
        // splits one utterance into two finals while the mic echo spans both.
        p.process(words: [word("So like, they keep", speaker: 0, start: 1000, end: 1800)], channel: "system")
        p.process(words: [word("like, they keep adding more stuff.", speaker: 2, start: 1300, end: 2300)], channel: "mic")
        p.process(words: [word(" adding more stuff.", speaker: 0, start: 1800, end: 2400)], channel: "system")

        XCTAssertEqual(
            p.liveEntries.map(\.text),
            ["So like, they keep", " adding more stuff."],
            "one mic echo spanning multiple system finals should not become a fake speaker turn"
        )
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
