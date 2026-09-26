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

    // MARK: - A leg that reconnects starts a new stream

    /// Every Soniox socket is a new stream whose word timestamps restart at 0.
    /// A mic leg that reconnects after a drop (or a Soniox 408 in a long pause),
    /// and a system leg that parks while nothing plays and rejoins when the
    /// other party speaks, both open one. The aggregator's watermark used to
    /// drop every final of the new stream until its clock passed the old one,
    /// so a reconnect 30 minutes in lost the next 30 minutes of live speech.
    func test_restartStream_keepsTheNewStreamsFinalsOnTheSessionTimeline() {
        let p = TranscriptPipeline()
        p.process(words: [word("before the drop", speaker: 0, start: 1_799_000, end: 1_800_000)], channel: "mic")

        // The reconnected socket opened 1_805_000 ms into the session.
        p.restartStream(channel: "mic", atMs: 1_805_000)
        p.process(words: [word("after the drop", speaker: 0, start: 500, end: 1_500)], channel: "mic")

        XCTAssertEqual(p.liveEntries.map(\.text), ["before the drop", "after the drop"])
        XCTAssertEqual(p.liveEntries.map(\.startMs), [1_799_000, 1_805_500])
    }

    func test_restartStream_onTheSystemLeg_leavesTheMicLegAlone() {
        let p = TranscriptPipeline()
        p.setSystemStartOffset(ms: 8_000)
        p.process(words: [word("them early", speaker: 0, start: 1_000, end: 60_000)], channel: "system")
        p.process(words: [word("me", speaker: 0, start: 70_000, end: 71_000)], channel: "mic")

        p.restartStream(channel: "system", atMs: 300_000)
        p.process(words: [word("them after rejoining", speaker: 0, start: 200, end: 900)], channel: "system")
        p.process(words: [word("me again", speaker: 0, start: 400_000, end: 401_000)], channel: "mic")

        XCTAssertEqual(
            p.liveEntries.map(\.text),
            ["them early", "me", "them after rejoining", "me again"]
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

    // MARK: - Cost against transcript length

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    /// A 13-letter slice of the alphabet, striding by 7 (coprime with 26), so
    /// neighbouring entries share about 2 letters of 13. The dedupe's 0.8
    /// character-set Jaccard is never approached, which matters: if the fixture
    /// collapsed into near-duplicates the transcript would shrink and hide the
    /// very cost this measures.
    private func distinctText(_ index: Int) -> String {
        String((0..<13).map { Self.alphabet[(index + $0 * 7) % 26] })
    }

    /// Interleaves mic and system finals one second apart, then times single
    /// `liveEntries` rebuilds and returns the fastest, so machine load does not
    /// decide the result. Every timed read follows an append, because the
    /// pipeline caches the merged list and only rebuilds when entries changed;
    /// and nothing is read while the transcript is being built, because a read
    /// per append would itself be the quadratic cost.
    private func rebuildMilliseconds(entries: Int) -> Double {
        let p = TranscriptPipeline()
        var ms = 0
        for index in 0..<entries {
            p.process(
                words: [word(distinctText(index), speaker: 0, start: ms, end: ms + 900)],
                channel: index.isMultiple(of: 2) ? "mic" : "system"
            )
            ms += 1000
        }
        XCTAssertEqual(
            p.liveEntries.count,
            entries,
            "every fixture entry is a distinct line, so none may dedupe away"
        )

        var fastest = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            ms += 1000
            p.process(
                words: [word(distinctText(entries), speaker: 0, start: ms, end: ms + 900)],
                channel: "mic"
            )
            let started = DispatchTime.now().uptimeNanoseconds
            _ = p.liveEntries
            fastest = min(fastest, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        return fastest
    }

    /// Regression guard for 2026-09-22. In a 1h45m session the cross-channel
    /// dedupe pinned a core on the main thread and the app went sluggish: it
    /// normalised both sides of every pair from scratch (rebuilding a
    /// three-way `CharacterSet` union each time) and re-scanned the whole
    /// transcript once per mic entry. Quadrupling the transcript must cost
    /// roughly 4x, not 16x.
    func test_mergeCost_tracksTranscriptLength_notItsSquare() {
        let small = rebuildMilliseconds(entries: 4_000)
        let large = rebuildMilliseconds(entries: 16_000)
        XCTAssertLessThan(
            large,
            1_000,
            "a rebuild at 16k entries is tens of milliseconds; a second means the pass is quadratic again"
        )
        XCTAssertLessThan(
            large,
            small * 12,
            "4x the transcript must not cost ~16x: the quadratic term is back"
        )
    }
}
