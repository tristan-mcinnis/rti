import RTICore
import XCTest

/// Pins TranscriptPipeline's cross-channel merge, note buffering, and offset
/// behavior — the combined live transcript the UI observes.
final class TranscriptPipelineTests: XCTestCase {
    private func word(
        _ text: String,
        speaker: Int,
        start: Int,
        end: Int,
        final: Bool = true,
        translationStatus: String = "none",
        language: String? = nil
    ) -> SonioxWord {
        SonioxWord(
            text: text,
            startMs: start,
            endMs: end,
            speaker: speaker,
            confidence: 1.0,
            isFinal: final,
            translationStatus: translationStatus,
            language: language,
            sourceLanguage: nil
        )
    }

    func test_process_micWords_appearInLiveEntries() {
        let p = TranscriptPipeline()
        p.process(words: [word("hello", speaker: 0, start: 0, end: 100)], channel: "mic")
        XCTAssertEqual(p.liveEntries.map(\.text), ["hello"])
    }

    /// A provider's token boundaries are not word boundaries. The same words
    /// must display identically however the provider batches its final tokens.
    func test_displayText_preservesProviderSpacingAcrossFinalPacketBoundaries() {
        let sequences = [
            ["Hello", ",", " world", "!"],
            ["你", "好", "世界", "。"],
            ["some", "thing", " works", "."],
            ["one ", "  two", "\nthree"],
            ["half", " ", "and", " ", "half"],
        ]

        for fragments in sequences {
            // Every partition of the same token sequence, including one batch
            // and one token per batch, exercises the production aggregation.
            for boundaries in 0..<(1 << (fragments.count - 1)) {
                let p = TranscriptPipeline()
                var batch: [SonioxWord] = []
                for (index, fragment) in fragments.enumerated() {
                    batch.append(word(fragment, speaker: 0, start: index * 100, end: (index + 1) * 100))
                    if index == fragments.count - 1 || boundaries & (1 << index) != 0 {
                        p.process(words: batch, channel: "mic")
                        batch = []
                    }
                }
                let rows = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: false)
                XCTAssertEqual(rows.map(\.original), [fragments.joined()], "packet boundaries: \(boundaries), tokens: \(fragments)")
            }
        }
    }

    func test_displayTranslation_preservesProviderSpacingAcrossFinalPacketBoundaries() {
        let fragments = ["你", "好", "。", "Hello", ",", " world", "!"]
        for boundaries in 0..<(1 << (fragments.count - 1)) {
            let p = TranscriptPipeline()
            var batch: [SonioxWord] = []
            for (index, fragment) in fragments.enumerated() {
                batch.append(SonioxWord(
                    text: fragment,
                    startMs: index * 100,
                    endMs: (index + 1) * 100,
                    speaker: 1,
                    confidence: 1,
                    isFinal: true,
                    translationStatus: index < 3 ? "original" : "translation",
                    language: index < 3 ? "zh" : "en",
                    sourceLanguage: index < 3 ? nil : "zh"
                ))
                if index == fragments.count - 1 || boundaries & (1 << index) != 0 {
                    p.process(words: batch, channel: "system")
                    batch = []
                }
            }
            let rows = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: true)
            XCTAssertEqual(rows.map(\.original), ["你好。"], "packet boundaries: \(boundaries)")
            XCTAssertEqual(rows.map(\.translation), ["Hello, world!"], "packet boundaries: \(boundaries)")
        }
    }

    func test_interimSegments_preserveRawSpacingTimelineAndTranslationMetadata() {
        let p = TranscriptPipeline()
        p.setSystemStartOffset(ms: 8000)
        p.process(words: [
            word(" Hello", speaker: 1, start: 100, end: 200, final: false, language: "en"),
            word(", ", speaker: 1, start: 200, end: 300, final: false, language: "en"),
            word("你好。", speaker: 1, start: 300, end: 400, final: false, translationStatus: "translation", language: "zh"),
        ], channel: "system")

        XCTAssertEqual(p.interimSegments.map(\.text), [" Hello, ", "你好。"])
        XCTAssertEqual(p.interimSegments.map(\.speakerId), ["remote_1", "remote_1"])
        XCTAssertEqual(p.interimSegments.map(\.startMs), [8100, 8300])
        XCTAssertEqual(p.interimSegments.map(\.translationStatus), ["none", "translation"])
        XCTAssertEqual(p.interimSegments.map(\.language), ["en", "zh"])
        XCTAssertTrue(p.interimSegments.allSatisfy { $0.textOrigin == .providerTokens })
        XCTAssertNotNil(p.interimLine, "the labelled-line compatibility surface remains available")
    }

    func test_interimSegments_shareFinalStreamIdentityAndRotateOnReconnect() {
        let p = TranscriptPipeline()
        p.process(words: [word("hel", speaker: 0, start: 0, end: 100, final: false)], channel: "mic")
        let stream = p.interimSegments.first?.streamID
        XCTAssertNotNil(stream)

        p.process(words: [word("hello", speaker: 0, start: 0, end: 100, final: false)], channel: "mic")
        XCTAssertEqual(p.interimSegments.first?.streamID, stream)
        p.process(words: [word("hello", speaker: 0, start: 0, end: 100)], channel: "mic")
        XCTAssertEqual(p.liveEntries.first?.streamID, stream)
        XCTAssertTrue(p.interimSegments.isEmpty)

        p.restartStream(channel: "mic", atMs: 5000)
        p.process(words: [word("after", speaker: 0, start: 0, end: 100, final: false)], channel: "mic")
        let restartedStream = p.interimSegments.first?.streamID
        XCTAssertNotNil(restartedStream)
        XCTAssertNotEqual(restartedStream, stream)
        XCTAssertEqual(p.interimSegments.first?.startMs, 5000)
        p.process(words: [word("after", speaker: 0, start: 0, end: 100)], channel: "mic")
        XCTAssertEqual(p.liveEntries.last?.streamID, restartedStream)
    }

    func test_liveProjectionPreservesWordTimingAcrossLegsAndFinalPacketShapes() {
        let p = TranscriptPipeline()
        p.process(words: [
            word("Alpha ", speaker: 1, start: 0, end: 500, final: false),
            word("again.", speaker: 1, start: 2000, end: 2500, final: false),
        ], channel: "mic")
        p.process(words: [word("Other voice.", speaker: 1, start: 1000, end: 1500)], channel: "system")
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(p.liveEntries)
        let pendingRows = projection.updateInterims(p.interimSegments)
        XCTAssertEqual(pendingRows.map(\.speakerId), ["self", "remote_1", "self"])
        XCTAssertEqual(pendingRows.map(\.visibleText), ["Alpha", "Other voice.", "again."])

        p.process(words: [
            word("Alpha ", speaker: 1, start: 0, end: 500),
            word("again.", speaker: 1, start: 2000, end: 2500, final: false),
        ], channel: "mic")
        projection.updateFinals(p.liveEntries)
        let partialRows = projection.updateInterims(p.interimSegments)
        XCTAssertEqual(partialRows.map(\.id), pendingRows.map(\.id))
        XCTAssertEqual(partialRows.map(\.visibleText), pendingRows.map(\.visibleText))

        p.process(words: [word("again.", speaker: 1, start: 2000, end: 2500)], channel: "mic")
        projection.updateFinals(p.liveEntries)
        XCTAssertEqual(projection.updateInterims([]).map(\.id), pendingRows.map(\.id))

        for onePacket in [true, false] {
            let packets = TranscriptPipeline()
            packets.process(words: [word("Other voice.", speaker: 1, start: 1000, end: 1500)], channel: "system")
            let words = [word("Alpha ", speaker: 1, start: 0, end: 500), word("again.", speaker: 1, start: 2000, end: 2500)]
            if onePacket {
                packets.process(words: words, channel: "mic")
                XCTAssertEqual(packets.liveEntries.first?.text, "Alpha again.", "the archive/notes batch text is unchanged")
            } else {
                words.forEach { packets.process(words: [$0], channel: "mic") }
            }
            var packetProjection = LiveTranscriptPresentation.Projection()
            packetProjection.updateFinals(packets.liveEntries)
            XCTAssertEqual(packetProjection.updateInterims([]).map(\.visibleText), pendingRows.map(\.visibleText))
        }
    }

    func test_liveProjectionCopyUsesCommittedTokenOrderNamesAndTranslationSetting() {
        let p = TranscriptPipeline()
        p.process(words: [
            word("Alpha ", speaker: 1, start: 0, end: 500),
            word("again.", speaker: 1, start: 2000, end: 2500),
        ], channel: "mic")
        p.process(words: [word("Other voice.", speaker: 1, start: 1000, end: 1500)], channel: "system")
        p.process(words: [word("别的声音。", speaker: 1, start: 1100, end: 1600,
                               translationStatus: "translation", language: "zh")], channel: "system")
        p.process(words: [word(" Never copy this.", speaker: 1, start: 3000, end: 3500, final: false)], channel: "mic")
        let names = ["self": "Sam", "remote_1": "Lee"]
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(p.liveEntries, names: names, showTranslations: true)
        _ = projection.updateInterims(p.interimSegments)
        let before = projection.committedRows
        let copied = LiveTranscriptPresentation.copyText(rows: projection.committedRows)
        XCTAssertEqual(copied, "[00:00] Sam: Alpha\n\n[00:01] Lee: Other voice.\n[00:01] Translation ZH: 别的声音。\n\n[00:02] Sam: again.")
        XCTAssertFalse(copied.contains("Never copy"))
        XCTAssertEqual(before.map(\.revision), projection.committedRows.map(\.revision))
        XCTAssertEqual(before.map(\.id), projection.committedRows.map(\.id))

        projection.updateFinals(p.liveEntries, names: names, showTranslations: false)
        XCTAssertEqual(LiveTranscriptPresentation.copyText(rows: projection.committedRows),
                       "[00:00] Sam: Alpha\n\n[00:01] Lee: Other voice.\n\n[00:02] Sam: again.")
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

    func test_lateSystemContextInvalidatesPreviouslyPublishedMicCoverage() {
        let p = TranscriptPipeline()
        p.process(words: [word("alpha beta gamma", speaker: 2, start: 2_000, end: 2_400)], channel: "mic")
        XCTAssertEqual(p.liveEntries.map(\.text), ["alpha beta gamma"])

        p.process(words: [word("alpha beta", speaker: 0, start: 1_800, end: 2_100)], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.text), ["alpha beta gamma"])
        p.process(words: [word(" gamma", speaker: 0, start: 2_250, end: 2_600)], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.text), ["alpha beta", " gamma"])
        XCTAssertTrue(p.liveEntries.allSatisfy { $0.speakerId.hasPrefix("remote_") })
    }

    func test_outOfOrderReconnectedSystemContextRechecksOldMicWindow() {
        let p = TranscriptPipeline()
        p.process(words: [word("alpha beta gamma", speaker: 2, start: 2_000, end: 2_400)], channel: "mic")
        p.process(words: [word("a later unrelated system contribution", speaker: 0, start: 10_000, end: 10_400)], channel: "system")
        XCTAssertEqual(p.liveEntries.count, 2)

        p.restartStream(channel: "system", atMs: 1_500)
        p.process(words: [word("alpha beta gamma delta", speaker: 0, start: 0, end: 400)], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.text), ["alpha beta gamma delta", "a later unrelated system contribution"])
        XCTAssertTrue(p.liveEntries.allSatisfy { $0.speakerId.hasPrefix("remote_") })
    }

    func test_echoTrimmingRechecksComparisonForSameEntryIdentity() {
        let p = TranscriptPipeline()
        p.process(words: [
            word("echo", speaker: 2, start: 0, end: 100),
            word(" room contribution", speaker: 2, start: 3_000, end: 3_100)
        ], channel: "mic")
        p.process(words: [word("unrelated distant system speech", speaker: 0, start: 10_000, end: 10_100)], channel: "system")
        let micID = p.liveEntries.first?.id
        XCTAssertEqual(p.liveEntries.first?.text, "echo room contribution")
        p.restartStream(channel: "system", atMs: 0)
        p.process(words: [word("echo", speaker: 0, start: 0, end: 100)], channel: "system")
        let remainingMic = p.liveEntries.first { $0.speakerId == "room_1" }
        XCTAssertEqual(remainingMic?.id, micID)
        XCTAssertEqual(remainingMic?.text, " room contribution")
        XCTAssertEqual(remainingMic?.startMs, 3_000)
        XCTAssertEqual(remainingMic?.tokens.map(\.text), [" room contribution"])
    }

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

    func test_crossChannel_longerTextKeepsCanonicalIdentityAcrossLaterMerges() {
        let p = TranscriptPipeline()
        p.process(words: [word("agree on design", speaker: 0, start: 0, end: 100)], channel: "mic")
        let canonicalID = p.liveEntries.first?.id
        let canonicalStreamID = p.liveEntries.first?.streamID

        // Near-duplicate, not exact containment: takes the longer-text
        // replacement branch instead of dropping the mic echo outright.
        p.process(words: [word("agree on the design", speaker: 1, start: 500, end: 600)], channel: "system")
        XCTAssertEqual(p.liveEntries.count, 1)
        XCTAssertEqual(p.liveEntries.first?.text, "agree on the design")
        XCTAssertEqual(p.liveEntries.first?.id, canonicalID)
        XCTAssertEqual(p.liveEntries.first?.displayStreamID, canonicalStreamID)
        let replacementStreamID = p.liveEntries.first?.streamID
        XCTAssertNotEqual(replacementStreamID, canonicalStreamID, "source stream and display lineage are distinct after a peer correction")
        let priorRow = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: false).first

        p.process(words: [word("a completely separate later contribution", speaker: 2, start: 10_000, end: 10_100)], channel: "system")
        let rows = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: false)
        XCTAssertEqual(p.liveEntries.first?.id, canonicalID)
        XCTAssertEqual(p.liveEntries.first?.displayStreamID, canonicalStreamID)
        XCTAssertEqual(p.liveEntries.first?.streamID, replacementStreamID)
        XCTAssertEqual(rows.first?.id, priorRow?.id)
        XCTAssertEqual(rows.first?.original, priorRow?.original)
        XCTAssertEqual(rows.first?.speakerId, priorRow?.speakerId)
        XCTAssertEqual(rows.first?.startMs, priorRow?.startMs)
    }

    func test_crossChannel_correctionPreservesCanonicalBoundariesOnBothSides() {
        let cases = [
            ("Let’s discuss", " the design", "the design today", " next.", "Let’s discuss the design today next."),
            ("我们讨论", "今天的设计方案", "今天的设计方案已经完成", "请继续", "我们讨论今天的设计方案已经完成请继续"),
            ("Let’s discuss ", "the design ", "the design today", "next.", "Let’s discuss the design today next."),
            ("Let’s discuss", "  the design\t", "\nthe design today  ", "next.", "Let’s discuss  the design today\tnext."),
        ]
        for (prefix, canonical, replacement, suffix, expected) in cases {
            let p = TranscriptPipeline()
            p.process(words: [word(prefix, speaker: 1, start: 0, end: 100)], channel: "system")
            p.process(words: [word(canonical, speaker: 1, start: 100, end: 200)], channel: "system")
            let canonicalID = p.liveEntries[1].id

            p.process(words: [word(replacement, speaker: 1, start: 150, end: 250)], channel: "mic")
            let corrected = p.liveEntries[1]
            p.process(words: [word(suffix, speaker: 1, start: 1000, end: 1100)], channel: "system")
            let rows = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: false)
            XCTAssertEqual(rows.map(\.original), [expected])
            XCTAssertEqual(corrected.id, canonicalID)
            XCTAssertEqual(p.liveEntries[1].id, canonicalID)
            XCTAssertEqual(p.liveEntries[1].text, corrected.text)
        }
    }

    func test_crossChannel_correctionKeepsItsTranslationInTheCanonicalDisplayRun() {
        let p = TranscriptPipeline()
        p.process(words: [word("Let’s discuss", speaker: 1, start: 0, end: 100)], channel: "system")
        p.process(words: [word(" the design", speaker: 1, start: 100, end: 200)], channel: "system")
        p.process(words: [word("我们来讨论设计。", speaker: 1, start: 110, end: 210, translationStatus: "translation", language: "zh")], channel: "system")
        p.process(words: [word("the design today", speaker: 1, start: 150, end: 250)], channel: "mic")
        p.process(words: [word(" next.", speaker: 1, start: 1000, end: 1100)], channel: "system")

        let rows = LiveTranscriptPresentation.rows(from: p.liveEntries, showTranslations: true)
        XCTAssertEqual(rows.map(\.original), ["Let’s discuss the design today next."])
        XCTAssertEqual(rows.map(\.translation), ["我们来讨论设计。"])
        XCTAssertEqual(rows.map(\.translationLanguage), ["zh"])
    }

    func test_crossChannel_repeatedCorrectionsKeepCanonicalDisplayLineage() {
        let p = TranscriptPipeline()
        p.process(words: [word("Let’s discuss", speaker: 1, start: 0, end: 100)], channel: "system")
        p.process(words: [word(" the design ", speaker: 1, start: 100, end: 200)], channel: "system")
        let canonical = p.liveEntries[1]
        p.process(words: [word("the design today", speaker: 1, start: 150, end: 250)], channel: "mic")
        let firstSourceStream = p.liveEntries[1].streamID

        p.restartStream(channel: "mic", atMs: 250)
        p.process(words: [word("the design today tomorrow", speaker: 1, start: 0, end: 100)], channel: "mic")
        let corrected = p.liveEntries[1]
        XCTAssertEqual(corrected.id, canonical.id)
        XCTAssertEqual(corrected.text, " the design today tomorrow ")
        XCTAssertEqual(corrected.displayStreamID, canonical.streamID)
        XCTAssertNotEqual(corrected.streamID, firstSourceStream)
        XCTAssertEqual(corrected.textOrigin, .providerCorrection(continuingStreamID: canonical.streamID))
        XCTAssertTrue(corrected.tokens.isEmpty, "a peer correction has no fabricated word alignment")
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

    func test_restartStream_startsANewDisplayRunWithoutChangingSpeakerName() {
        let p = TranscriptPipeline()
        p.process(words: [word("before", speaker: 0, start: 0, end: 100)], channel: "mic")
        p.restartStream(channel: "mic", atMs: 5000)
        p.process(words: [word("after", speaker: 0, start: 0, end: 100)], channel: "mic")

        let rows = LiveTranscriptPresentation.rows(
            from: p.liveEntries,
            showTranslations: false,
            names: ["self": "Sam"]
        )
        XCTAssertEqual(rows.map(\.original), ["before", "after"])
        XCTAssertEqual(rows.map(\.speakerLabel), ["Sam", "Sam"])
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
    /// Wall-clock based, so opt-in: TEST_RUNNER_RTI_TIMING_TESTS=1 xcodebuild ... test
    func test_mergeCost_tracksTranscriptLength_notItsSquare() throws {
        guard ProcessInfo.processInfo.environment["RTI_TIMING_TESTS"] == "1" else {
            throw XCTSkip("Set RTI_TIMING_TESTS=1 to run the merge-cost timing check")
        }
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
