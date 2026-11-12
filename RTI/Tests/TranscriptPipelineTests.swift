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

    /// The SCK fallback starts a new system backend after the socket already
    /// went `.live`. Its start offset must not move the live stream's base.
    func test_systemBackendStartAfterLive_keepsTheLiveRebase() {
        let p = TranscriptPipeline()
        p.setSystemStartOffset(ms: 0)
        p.restartStream(channel: "system", atMs: 10_000)
        p.process(words: [word("before fallback", speaker: 0, start: 100, end: 200)], channel: "system")
        p.setSystemStartOffset(ms: 25_000)
        XCTAssertEqual(p.streamOffsetMs(for: "system"), 10_000, "The .live re-base owns the live base")
        p.process(words: [word("after fallback", speaker: 0, start: 1_000, end: 1_100)], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.startMs), [10_100, 11_000])

        p.reset()
        p.setSystemStartOffset(ms: 4_000)
        XCTAssertEqual(p.streamOffsetMs(for: "system"), 4_000, "A new session places its stream again")
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

    // MARK: - Both legs kept verbatim (no cross-leg echo removal)

    func testWireTokensRemainVerbatimOnBothLegsAcrossLateDelivery() throws {
        let json = #"{"tokens":[{"text":" 登","start_ms":80,"end_ms":115,"speaker":"seat-A","is_final":true},{"text":"机。","start_ms":115,"end_ms":160,"is_final":true},{"text":"!","start_ms":160,"end_ms":160,"is_final":true},{"text":"!","start_ms":160,"end_ms":160,"is_final":true}]}"#
        let words = try XCTUnwrap(JSONDecoder().decode(SonioxTranscriptMessage.self, from: Data(json.utf8)).tokens)
        let p = TranscriptPipeline()
        for channel in ["system", "mic"] { p.process(words: words, channel: channel) }
        for leg in ["mic", "system"] {
            let raw = p.liveEntries.flatMap(\.tokens).filter { $0.leg == leg }.sorted { ($0.ordinal ?? -1) < ($1.ordinal ?? -1) }
            XCTAssertEqual(raw.compactMap(\.provider), words)
            XCTAssertEqual(raw.map(\.text).joined(), " 登机。!!")
            XCTAssertEqual(raw.map(\.ordinal), [0, 1, 2, 3])
            XCTAssertEqual(raw.map(\.streamOffsetMs), [0, 0, 0, 0])
            XCTAssertNil(raw[1].provider?.providerSpeaker)
            XCTAssertNil(raw[1].provider?.providerConfidence)
        }
        XCTAssertNotEqual(p.streamID(for: "mic"), p.streamID(for: "system"))
        XCTAssertTrue(p.liveEntries.allSatisfy { $0.confidence == nil })
    }

    func testInterimReplacesOnlyItsLegAndFinalsAppendWithoutDeduplication() throws {
        let p = TranscriptPipeline()
        func decoded(_ payload: String) throws -> [SonioxWord] {
            try XCTUnwrap(JSONDecoder().decode(SonioxTranscriptMessage.self, from: Data(payload.utf8)).tokens)
        }
        let interim = try decoded(#"{"tokens":[{"text":"我","is_final":false}]}"#)
        p.process(words: interim, channel: "system")
        p.process(words: interim, channel: "mic")
        let mixed = try decoded(#"{"tokens":[{"text":"我","is_final":true},{"text":" 喜","is_final":false}]}"#)
        p.process(words: mixed, channel: "system")
        XCTAssertEqual(p.interimSegments.map(\.text), ["我", " 喜"])
        let final = try decoded(#"{"tokens":[{"text":" 喜欢","is_final":true},{"text":" 喜欢","is_final":true},{"text":"<end>","is_final":true}]}"#)
        p.process(words: final, channel: "system")
        let committed = p.liveEntries.flatMap(\.tokens)
        XCTAssertEqual(committed.map(\.text), ["我", " 喜欢", " 喜欢"])
        XCTAssertTrue(committed.allSatisfy { $0.provider?.providerStartMs == nil })
        XCTAssertEqual(p.interimSegments.map(\.text), ["我"])
        p.process(words: [], channel: "mic")
        XCTAssertTrue(p.interimSegments.isEmpty)
        XCTAssertEqual(LiveTranscriptPresentation.utterances(from: p.liveEntries).map(\.text), ["我 喜欢 喜欢"])
    }

    func testProviderEndpointSeparatesEvidenceWithoutAddingSpokenText() {
        let p = TranscriptPipeline()
        p.process(words: [word("First.", speaker: 1, start: 0, end: 100),
                          word("<end>", speaker: 1, start: 100, end: 100)], channel: "system")
        p.process(words: [word("Second.", speaker: 1, start: 105, end: 200)], channel: "system")
        XCTAssertEqual(LiveTranscriptPresentation.utterances(from: p.liveEntries).map(\.text), ["First.", "Second."])
    }

    func testTranslationAndOriginalAtIdenticalTimeStayOnTheirOwnLane() {
        let p = TranscriptPipeline()
        p.process(words: [word("杯子", speaker: 1, start: 200, end: 500, translationStatus: "original", language: "zh"),
                          word("cup", speaker: 1, start: 200, end: 500, translationStatus: "translation", language: "en")], channel: "system")
        let raw = p.liveEntries.flatMap(\.tokens).compactMap(\.provider)
        XCTAssertEqual(raw.map(\.translationStatus), ["original", "translation"])
        XCTAssertEqual(raw.map(\.text), ["杯子", "cup"])
    }

    /// Soniox sends translation tokens without times. They are not echo.
    func test_untimedMicTranslation_isKeptBesideTheSameSystemTranslation() {
        let p = TranscriptPipeline()
        for channel in ["system", "mic"] {
            p.process(words: [word("我们开始吧。", speaker: 1, start: 0, end: 0, translationStatus: "translation")], channel: channel)
        }
        XCTAssertEqual(p.liveEntries.map(\.speakerId), ["self", "remote_1"])
    }

    func testTwoLegsRepeatingIdenticalSpeechAreBothRetained() {
        let p = TranscriptPipeline()
        let repeated = word("I said blue.", speaker: 2, start: 40, end: 250)
        p.process(words: [repeated], channel: "mic")
        p.process(words: [repeated], channel: "system")
        XCTAssertEqual(p.liveEntries.map(\.text), ["I said blue.", "I said blue."])
        XCTAssertEqual(p.liveEntries.compactMap { $0.tokens.first?.leg }, ["mic", "system"])
    }

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

    func testMissingSystemLabelNeverInheritsAnAdjacentName() {
        let pipeline = TranscriptPipeline()
        pipeline.process(words: [
            word("First.", speaker: 1, start: 100, end: 150),
            word("Second.", speaker: 0, start: 200, end: 250),
        ], channel: "system")
        XCTAssertEqual(pipeline.liveEntries.map(\.speakerId), ["remote_1", "remote"])
    }

    func testIncrementalLiveProjectionMatchesFreshProjectionAtEachTransition() {
        let pipeline = TranscriptPipeline()
        var incremental = LiveTranscriptPresentation.Projection()
        for n in 1...300 {
            let leg = n.isMultiple(of: 2) ? "mic" : "system"
            let timestamp = n == 151 ? 144000 : n * 1000
            pipeline.process(words: [word(" Token \(n)。", speaker: n % 4 + 1, start: timestamp, end: timestamp + 100)], channel: leg)
            incremental.updateLiveFinals(pipeline)
        }
        var fresh = LiveTranscriptPresentation.Projection()
        fresh.updateFinals(pipeline.liveEntries)
        XCTAssertEqual(incremental.committedRows.map(\.visibleText), fresh.committedRows.map(\.visibleText))
        XCTAssertEqual(incremental.committedRows.map(\.id), fresh.committedRows.map(\.id))
        pipeline.reset()
        incremental.updateLiveFinals(pipeline)
        XCTAssertTrue(incremental.committedRows.isEmpty)
    }

    func testIndependentRespondentsRepeatingTheSameSentenceAreRetained() {
        let pipeline = TranscriptPipeline()
        for speaker in 1...2 {
            pipeline.process(words: [word("我的茶杯是蓝色的", speaker: speaker, start: speaker * 1000, end: speaker * 1000 + 500)], channel: "system")
        }
        XCTAssertEqual(pipeline.liveEntries.map(\.speakerId), ["remote_1", "remote_2"])
        pipeline.restartStream(channel: "system", atMs: 4000)
        pipeline.process(words: [word("Next group.", speaker: 1, start: 30, end: 100)], channel: "system")
        XCTAssertEqual(pipeline.liveEntries.last?.speakerId, "remote_3")
        pipeline.systemSpeakerLabelsEnabled = false
        pipeline.process(words: [word("很轻。", speaker: 2, start: 230, end: 400)], channel: "system")
        XCTAssertEqual(pipeline.liveEntries.last?.speakerId, "remote")
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
    private func updateMilliseconds(entries: Int) -> Double {
        let pipeline = TranscriptPipeline()
        var projection = LiveTranscriptPresentation.Projection()
        for i in 0..<entries {
            pipeline.process(words: [word(distinctText(i), speaker: i % 4 + 1, start: i * 1000, end: i * 1000 + 600)],
                             channel: i.isMultiple(of: 2) ? "mic" : "system")
        }
        projection.updateLiveFinals(pipeline)
        var observed = pipeline.liveEntries
        let start = DispatchTime.now().uptimeNanoseconds
        for i in entries..<(entries + 64) {
            pipeline.process(words: [word(" Cup.", speaker: i % 4 + 1, start: i * 1000, end: i * 1000 + 600)],
                             channel: i.isMultiple(of: 2) ? "mic" : "system")
            projection.updateLiveFinals(pipeline)
            let rows = projection.updateInterims([])
            XCTAssertFalse(projection.turns(for: rows).isEmpty)
            withExtendedLifetime(observed) {}
            observed = pipeline.liveEntries
        }
        XCTAssertEqual(observed.count, entries + 64)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 64_000_000
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
        let small = updateMilliseconds(entries: 4_000)
        let large = updateMilliseconds(entries: 16_000)
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
