import XCTest
import RTICore

final class LiveTranscriptPresentationTests: XCTestCase {
    private func entry(
        _ text: String,
        speaker: String = "self",
        start: Int = 0,
        translationStatus: String = "none",
        language: String? = nil
    ) -> LiveEntry {
        LiveEntry(
            speakerId: speaker,
            text: text,
            startMs: start,
            confidence: 1,
            translationStatus: translationStatus,
            language: language,
            sourceLanguage: nil
        )
    }

    func test_coalescesConsecutiveOriginalsBySpeaker() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("hello", speaker: "self", start: 1000),
                entry("there", speaker: "self", start: 1500),
                entry("hi", speaker: "remote_1", start: 2500),
            ],
            showTranslations: false
        )

        XCTAssertEqual(rows.map(\.speakerLabel), ["You", "Speaker 1"])
        XCTAssertEqual(rows.map(\.original), ["hello there", "hi"])
        XCTAssertEqual(rows.map(\.startMs), [1000, 2500])
    }

    func test_pairsTranslationWithPreviousSpeakerTurnWhenVisible() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("bonjour", speaker: "remote_1", start: 1000),
                entry("hello", speaker: "remote_1", start: 1100, translationStatus: "translation", language: "en"),
            ],
            showTranslations: true
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].original, "bonjour")
        XCTAssertEqual(rows[0].translation, "hello")
        XCTAssertEqual(rows[0].translationLanguage, "en")
    }

    func test_hidesOrphanTranslationWhenTranslationsAreHidden() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("hello", speaker: "remote_1", start: 1000, translationStatus: "translation", language: "en"),
            ],
            showTranslations: false
        )

        XCTAssertTrue(rows.isEmpty)
    }

    func test_keepsNotesSeparate() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("first", speaker: "self", start: 1000),
                entry("remember this", speaker: "note", start: 1500),
                entry("second", speaker: "self", start: 2000),
            ],
            showTranslations: false
        )

        XCTAssertEqual(rows.map(\.speakerLabel), ["You", "Note", "You"])
        XCTAssertEqual(rows.map(\.original), ["first", "remember this", "second"])
    }

    func test_copyTextIncludesTranslationWhenVisible() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("bonjour", speaker: "remote_1", start: 61000),
                entry("hello", speaker: "remote_1", start: 61200, translationStatus: "translation", language: "en"),
            ],
            showTranslations: true,
            names: ["remote_1": "Client"]
        )

        XCTAssertEqual(
            LiveTranscriptPresentation.copyText(rows: rows, showTranslations: true),
            "[01:01] Client: bonjour\n[01:01] Translation EN: hello"
        )
    }

    // MARK: - Stable speaker labels

    /// Labels come from the id, never from order of appearance: the mic
    /// wearer is "You" even when someone else spoke first, and a remote
    /// voice keeps its number when an earlier entry drops out (the echo pass
    /// can remove an early mic entry after later audio arrives).
    func test_labelsDoNotDependOnWhoSpokeFirst() {
        let withEarlyEntry = LiveTranscriptPresentation.rows(
            from: [
                entry("echo", speaker: "self", start: 500),
                entry("hi", speaker: "remote_2", start: 1000),
                entry("hello", speaker: "remote_1", start: 2000),
                entry("morning", speaker: "self", start: 3000),
            ],
            showTranslations: false
        )
        let withoutIt = LiveTranscriptPresentation.rows(
            from: [
                entry("hi", speaker: "remote_2", start: 1000),
                entry("hello", speaker: "remote_1", start: 2000),
                entry("morning", speaker: "self", start: 3000),
            ],
            showTranslations: false
        )
        XCTAssertEqual(withEarlyEntry.map(\.speakerLabel), ["You", "Speaker 2", "Speaker 1", "You"])
        XCTAssertEqual(withoutIt.map(\.speakerLabel), ["Speaker 2", "Speaker 1", "You"])
    }

    func test_labelsKeepLegsApartAndUseNames() {
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "self"), "You")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "remote_3"), "Speaker 3")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "room_1"), "Room speaker 1")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "note"), "Note")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "remote_1", names: ["remote_1": " Priya "]), "Priya")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "remote_1", names: ["remote_1": "  "]), "Speaker 1")
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "self", names: ["self": "Sam"]), "Sam")
    }

    // MARK: - Interim

    func test_interimSegmentsKeepTheirSpeakers() {
        XCTAssertEqual(
            LiveTranscriptPresentation.interimSegments("self: based on the study  remote_2: mockup is going to be"),
            [
                .init(speakerId: "self", text: "based on the study"),
                .init(speakerId: "remote_2", text: "mockup is going to be"),
            ]
        )
    }

    func test_interimSegmentsPreserveOrdinaryColons() {
        XCTAssertEqual(
            LiveTranscriptPresentation.interimSegments("remote_1: Decision: validate phase one"),
            [.init(speakerId: "remote_1", text: "Decision: validate phase one")]
        )
        XCTAssertEqual(
            LiveTranscriptPresentation.interimSegments("the self: part"),
            [.init(speakerId: "", text: "the self: part")]
        )
    }

    private func providerEntry(_ text: String, speaker: String, at ms: Int, stream: UUID) -> LiveEntry {
        LiveEntry(speakerId: speaker, text: text, startMs: ms, confidence: 1,
                  translationStatus: "none", language: nil, sourceLanguage: nil,
                  textOrigin: .providerTokens, streamID: stream)
    }

    private func pending(_ text: String, speaker: String, at ms: Int, stream: UUID) -> LiveTranscriptPresentation.InterimSegment {
        .init(speakerId: speaker, text: text, textOrigin: .providerTokens, startMs: ms, streamID: stream)
    }

    private func timedEntry(_ text: String, speaker: String, start: Int, end: Int, stream: UUID, translated: Bool = false) -> LiveEntry {
        LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1,
                  translationStatus: translated ? "translation" : "none", language: translated ? "zh" : "en", sourceLanguage: nil,
                  textOrigin: .providerTokens, streamID: stream,
                  tokens: [.init(text: text, startMs: start, endMs: end)])
    }

    func test_utterancePolicyUsesMeasuredPauseAndNotPacketBoundaries() {
        let stream = UUID()
        let first = timedEntry("Hello", speaker: "self", start: 0, end: 100, stream: stream)
        let continued = timedEntry(" world.", speaker: "self", start: 1099, end: 1199, stream: stream)
        let afterPause = timedEntry(" Next.", speaker: "self", start: 2199, end: 2299, stream: stream)
        XCTAssertEqual(LiveTranscriptPresentation.utterances(from: [first, continued, afterPause]).map(\.text),
                       ["Hello world.", " Next."])
        let batched = LiveEntry(speakerId: "self", text: "Hello world. Next.", startMs: 0, confidence: 1,
                               translationStatus: "none", language: "en", sourceLanguage: nil,
                               textOrigin: .providerTokens, streamID: stream,
                               tokens: first.tokens + continued.tokens + afterPause.tokens)
        XCTAssertEqual(LiveTranscriptPresentation.utterances(from: [batched]).map(\.text),
                       LiveTranscriptPresentation.utterances(from: [first, continued, afterPause]).map(\.text))
    }

    func test_olderUtteranceExtensionMatchesColdProjectionAcrossAnotherLeg() {
        let mic = UUID()
        let system = UUID()
        let first = timedEntry("Alpha", speaker: "self", start: 0, end: 100, stream: mic)
        let other = timedEntry("Other voice.", speaker: "remote_1", start: 150, end: 250, stream: system)
        let continued = timedEntry(" again.", speaker: "self", start: 200, end: 300, stream: mic)
        var incremental = LiveTranscriptPresentation.Projection()
        incremental.updateFinals([first, other])
        let before = incremental.committedRows
        incremental.updateFinals([first, other, continued])
        var cold = LiveTranscriptPresentation.Projection()
        cold.updateFinals([first, other, continued])
        XCTAssertEqual(incremental.committedRows.map(\.visibleText), ["Alpha again.", "Other voice."])
        XCTAssertEqual(incremental.committedRows.map(\.id), cold.committedRows.map(\.id))
        XCTAssertEqual(incremental.committedRows.map(\.visibleText), cold.committedRows.map(\.visibleText))
        XCTAssertEqual(before[1], incremental.committedRows[1], "unrelated overlapping utterance stays cached")
    }

    func test_delayedTranslationPairsByTimestampAndMatchesColdProjection() {
        let stream = UUID()
        let first = timedEntry("First.", speaker: "remote_1", start: 0, end: 100, stream: stream)
        let second = timedEntry("Second.", speaker: "remote_1", start: 2000, end: 2100, stream: stream)
        let translated = timedEntry("第一句。", speaker: "remote_1", start: 0, end: 100, stream: stream, translated: true)
        var incremental = LiveTranscriptPresentation.Projection()
        incremental.updateFinals([first, second], showTranslations: true)
        incremental.updateFinals([first, second, translated], showTranslations: true)
        var cold = LiveTranscriptPresentation.Projection()
        cold.updateFinals([first, second, translated], showTranslations: true)
        XCTAssertEqual(incremental.committedRows.map(\.translation), ["第一句。", ""])
        XCTAssertEqual(incremental.committedRows.map(\.id), cold.committedRows.map(\.id))
        XCTAssertEqual(incremental.committedRows.map(\.translation), cold.committedRows.map(\.translation))
    }

    func test_translationFirstReattachesWhenSourceArrivesWithoutDuplicateIDs() {
        let stream = UUID()
        let original = timedEntry("First.", speaker: "remote_1", start: 0, end: 100, stream: stream)
        let translated = timedEntry("第一句。", speaker: "remote_1", start: 0, end: 100, stream: stream, translated: true)
        var incremental = LiveTranscriptPresentation.Projection()
        incremental.updateFinals([translated], showTranslations: true)
        let orphanID = incremental.committedRows[0].id
        incremental.updateFinals([translated, original], showTranslations: true)
        var cold = LiveTranscriptPresentation.Projection()
        cold.updateFinals([translated, original], showTranslations: true)
        XCTAssertEqual(incremental.committedRows.count, 1)
        XCTAssertEqual(incremental.committedRows[0].visibleText, "First.")
        XCTAssertEqual(incremental.committedRows[0].translation, "第一句。")
        XCTAssertNotEqual(orphanID, incremental.committedRows[0].id, "translation-only and spoken rows have distinct kinds")
        XCTAssertEqual(incremental.committedRows.map(\.id), cold.committedRows.map(\.id))
        XCTAssertEqual(Set(incremental.committedRows.map(\.id)).count, incremental.committedRows.count)
    }

    func test_previouslyPairedTranslationMovesToItsLaterArrivingSource() {
        let stream = UUID()
        let first = timedEntry("First.", speaker: "remote_1", start: 0, end: 100, stream: stream)
        let second = timedEntry("Second.", speaker: "remote_1", start: 2000, end: 2100, stream: stream)
        let translated = timedEntry("第二句。", speaker: "remote_1", start: 2000, end: 2100, stream: stream, translated: true)
        var incremental = LiveTranscriptPresentation.Projection()
        incremental.updateFinals([first], showTranslations: true)
        incremental.updateFinals([first, translated], showTranslations: true)
        incremental.updateFinals([first, translated, second], showTranslations: true)
        var cold = LiveTranscriptPresentation.Projection()
        cold.updateFinals([first, translated, second], showTranslations: true)
        XCTAssertEqual(incremental.committedRows.map(\.translation), ["", "第二句。"])
        XCTAssertEqual(incremental.committedRows.map(\.id), cold.committedRows.map(\.id))
        XCTAssertEqual(incremental.committedRows.map(\.translation), cold.committedRows.map(\.translation))
    }

    func test_liveProjectionKeepsInterleavedOrderAndIdentityAsPrefixesFinalize() {
        let stream = UUID()
        let first = providerEntry("Alpha.", speaker: "remote_1", at: 0, stream: stream)
        let continued = providerEntry(" Continue.", speaker: "remote_1", at: 100, stream: stream)
        let second = providerEntry("Beta.", speaker: "remote_2", at: 200, stream: stream)
        let returned = providerEntry(" Return.", speaker: "remote_1", at: 300, stream: stream)
        let interim = [
            pending(" Continue.", speaker: "remote_1", at: 100, stream: stream),
            pending("Beta.", speaker: "remote_2", at: 200, stream: stream),
            pending(" Return.", speaker: "remote_1", at: 300, stream: stream),
        ]
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals([first])
        let initial = projection.updateInterims(interim)
        let identities = initial.map(\.id)
        XCTAssertEqual(initial.map(\.speakerId), ["remote_1", "remote_2", "remote_1"])
        XCTAssertEqual(initial.map(\.visibleText), ["Alpha. Continue.", "Beta.", "Return."])

        for finalizedCount in 1...3 {
            projection.updateFinals([first] + Array([continued, second, returned].prefix(finalizedCount)))
            let rows = projection.updateInterims(Array(interim.dropFirst(finalizedCount)))
            XCTAssertEqual(rows.map(\.id), identities)
            XCTAssertEqual(rows.map(\.visibleText), initial.map(\.visibleText))
        }
    }

    func test_liveProjectionPlacesEarlierPendingLegBeforeLaterFinalLeg() {
        let mic = UUID()
        let system = UUID()
        let later = providerEntry("Later final.", speaker: "remote_1", at: 2000, stream: system)
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals([later])
        let before = projection.updateInterims([pending("Earlier pending.", speaker: "self", at: 1000, stream: mic)])
        XCTAssertEqual(before.map(\.speakerId), ["self", "remote_1"])
        projection.updateFinals([providerEntry("Earlier pending.", speaker: "self", at: 1000, stream: mic), later])
        let after = projection.updateInterims([])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.visibleText), after.map(\.visibleText))
    }

    func test_liveProjectionParagraphsDependOnVisibleTextNotFinality() {
        let cases = [
            (String(repeating: "word ", count: 90), "finished.", " Tail stays here."),
            (String(repeating: "word ", count: 239), "final", " Tail stays here."),
            (String(repeating: "汉", count: 449), "。", "后面的文字保持原位。"),
            (String(repeating: "word ", count: 90) + "Version ", "3.", "14 stays here."),
        ]
        for (prefix, promoted, suffix) in cases {
            let stream = UUID()
            var projection = LiveTranscriptPresentation.Projection()
            let first = providerEntry(prefix, speaker: "self", at: 0, stream: stream)
            projection.updateFinals([first])
            let initial = projection.updateInterims([pending(promoted + suffix, speaker: "self", at: 100, stream: stream)])[0]
            projection.updateFinals([first, providerEntry(promoted, speaker: "self", at: 100, stream: stream)])
            let middle = projection.updateInterims([pending(suffix, speaker: "self", at: 200, stream: stream)])[0]
            projection.updateFinals([first, providerEntry(promoted + suffix, speaker: "self", at: 100, stream: stream)])
            let final = projection.updateInterims([])[0]
            XCTAssertEqual(initial.id, middle.id)
            XCTAssertEqual(initial.id, final.id)
            XCTAssertEqual(initial.paragraphs.map(\.id), middle.paragraphs.map(\.id))
            XCTAssertEqual(initial.paragraphs.map(\.id), final.paragraphs.map(\.id))
            XCTAssertEqual(initial.paragraphs.map(\.text), middle.paragraphs.map(\.text))
            XCTAssertEqual(initial.paragraphs.map(\.text), final.paragraphs.map(\.text))
            XCTAssertTrue(initial.hasPending)
            XCTAssertFalse(final.hasPending)
            XCTAssertTrue(final.paragraphs.flatMap(\.spans).allSatisfy(\.isFinal))
        }
    }

    func test_liveProjectionReusesFrozenRowsDuringInterimOnlyRevisions() {
        let stream = UUID()
        let entries = (0..<2000).map {
            providerEntry("Sentence \($0).", speaker: "remote_\($0 % 2 + 1)", at: $0 * 1000, stream: stream)
        }
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(entries)
        let first = projection.updateInterims([pending(" Next", speaker: "remote_2", at: 2_000_000, stream: stream)])
        let next = projection.updateInterims([pending(" Next words.", speaker: "remote_2", at: 2_000_000, stream: stream)])
        XCTAssertEqual(first[0], next[0], "historical row equality does not scan or revise its text")
        XCTAssertEqual(first[1998], next[1998])
        XCTAssertEqual(first.last?.id, next.last?.id)
        XCTAssertNotEqual(first.last?.revision, next.last?.revision)
    }

    func test_liveProjectionKeepsCorrectionLineageTranslationAndReconnectNames() {
        let canonicalStream = UUID()
        let peerStream = UUID()
        let canonical = providerEntry("Hello ", speaker: "remote_1", at: 0, stream: canonicalStream)
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals([canonical], names: ["remote_1": "Sam"], showTranslations: true)
        let original = projection.updateInterims([pending("world.", speaker: "remote_1", at: 100, stream: canonicalStream)])[0]
        let corrected = LiveEntry(
            speakerId: "remote_1", text: "Hello there ", startMs: 0, confidence: 1,
            translationStatus: "none", language: "en", sourceLanguage: nil,
            id: canonical.id, textOrigin: .providerCorrection(continuingStreamID: canonicalStream), streamID: peerStream
        )
        let translation = LiveEntry(
            speakerId: "remote_1", text: "你好。", startMs: 50, confidence: 1,
            translationStatus: "translation", language: "zh", sourceLanguage: "en",
            textOrigin: .providerTokens, streamID: canonicalStream
        )
        projection.updateFinals([corrected, translation], names: ["remote_1": "Sam"], showTranslations: true)
        let revised = projection.updateInterims([pending("world.", speaker: "remote_1", at: 100, stream: canonicalStream)])[0]
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.visibleText, "Hello there world.")
        XCTAssertEqual(revised.translation, "你好。")
        XCTAssertEqual(revised.speakerLabel, "Sam")

        let restarted = UUID()
        let before = projection.updateInterims([pending("New stream.", speaker: "remote_1", at: 5000, stream: restarted)])
        XCTAssertEqual(before.count, 2)
        projection.updateFinals([corrected, translation, providerEntry("New stream.", speaker: "remote_1", at: 5000, stream: restarted)],
                                names: ["remote_1": "Sam"], showTranslations: true)
        let after = projection.updateInterims([])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(after.map(\.speakerLabel), ["Sam", "Sam"])
    }

    func test_liveProjectionTranslationToggleHidesAndRestoresPairedText() {
        let stream = UUID()
        let original = providerEntry("Hello.", speaker: "remote_1", at: 0, stream: stream)
        let translation = LiveEntry(
            speakerId: "remote_1", text: "你好。", startMs: 100, confidence: 1,
            translationStatus: "translation", language: "zh", sourceLanguage: "en",
            textOrigin: .providerTokens, streamID: stream
        )
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals([original, translation], showTranslations: true)
        let shown = projection.updateInterims([])[0]
        XCTAssertEqual(shown.translation, "你好。")

        projection.updateFinals([original, translation], showTranslations: false)
        let hidden = projection.updateInterims([])[0]
        XCTAssertEqual(hidden.id, shown.id)
        XCTAssertEqual(hidden.visibleText, "Hello.")
        XCTAssertEqual(hidden.translation, "")
        XCTAssertNil(hidden.translationLanguage)

        projection.updateFinals([original, translation], showTranslations: true)
        XCTAssertEqual(projection.updateInterims([])[0].translation, shown.translation)
    }

    func test_providerInterimJoinsWithoutChangingItsTokenBoundary() {
        let stream = UUID()
        for (final, interim, expected) in [
            ("Hello", ",", "Hello,"),
            ("Hello ", "world", "Hello world"),
            ("some", "thing", "something"),
            ("你好", "世界", "你好世界"),
        ] {
            var projection = LiveTranscriptPresentation.Projection()
            projection.updateFinals([providerEntry(final, speaker: "self", at: 0, stream: stream)])
            let rows = projection.updateInterims([pending(interim, speaker: "self", at: 100, stream: stream)])
            XCTAssertEqual(rows.map(\.visibleText), [expected])
            XCTAssertTrue(rows[0].hasPending)
        }
    }

    func test_interimFromANewStreamDoesNotContinueThePreviousStream() {
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals([providerEntry("Before reconnect.", speaker: "self", at: 0, stream: UUID())])
        let rows = projection.updateInterims([pending("After reconnect.", speaker: "self", at: 5000, stream: UUID())])
        XCTAssertEqual(rows.map(\.visibleText), ["Before reconnect.", "After reconnect."])
    }

    // MARK: - Attendee names

    func test_nameChoicesOfferInviteesOnce() {
        let attendees: [CalendarMeeting.Attendee] = [
            .init(name: "Sam Rivera", email: "sam@example.com", isCurrentUser: true),
            .init(name: "Priya Shah"),
            .init(name: "priya shah"),
            .init(name: "Sam Lee"),
            .init(name: "Ana Ruiz"),
        ]
        let names = ["remote_1": "Priya Shah", "remote_2": "Sam Lee"]
        XCTAssertEqual(
            LiveTranscriptPresentation.nameChoices(attendees: attendees, names: names, for: "remote_1"),
            ["Priya Shah", "Ana Ruiz"]
        )
        XCTAssertEqual(
            LiveTranscriptPresentation.nameChoices(attendees: attendees, names: names, for: "remote_3"),
            ["Ana Ruiz"]
        )
    }

    // MARK: - Paragraphs

    func test_shortRunIsOneOpenParagraph() {
        XCTAssertEqual(LiveTranscriptPresentation.paragraphs("Sure. That works."), ["Sure. That works."])
        XCTAssertEqual(LiveTranscriptPresentation.paragraphs(""), [""])
    }

    func test_longRunBreaksAtSentenceEndsAndStaysStableAsItGrows() {
        let sentence = "We can ship without the tour and measure drop-off. "
        let text = String(repeating: sentence, count: 12)
        let split = LiveTranscriptPresentation.paragraphs(text, softLimit: 120)
        XCTAssertGreaterThan(split.count, 2)
        XCTAssertTrue(split.dropLast().allSatisfy { $0.hasSuffix(".") && $0.count >= 120 })
        // The run ends on a sentence: the open paragraph is empty, so the
        // next words start a new paragraph instead of joining a closed one.
        XCTAssertEqual(split.last, "")
        XCTAssertEqual(split.joined(separator: " ").trimmingCharacters(in: .whitespaces),
                       text.trimmingCharacters(in: .whitespaces))

        // Appending words never moves an earlier break.
        let grown = LiveTranscriptPresentation.paragraphs(text + "And one more thought", softLimit: 120)
        XCTAssertEqual(Array(grown.dropLast()), Array(split.dropLast()))
        XCTAssertEqual(grown.last, "And one more thought")
    }

    func test_unpunctuatedRunBreaksAtASpacePastTheHardLimit() {
        let text = String(repeating: "word ", count: 100)
        let split = LiveTranscriptPresentation.paragraphs(text, softLimit: 50, hardLimit: 100)
        XCTAssertGreaterThan(split.count, 3)
        XCTAssertTrue(split.dropLast().allSatisfy { $0.count >= 99 && $0.count <= 100 })
    }

    func test_cjkSentenceEndsCloseWithoutASpace() {
        let text = String(repeating: "我们先上线再看数据。", count: 10)
        let split = LiveTranscriptPresentation.paragraphs(text, softLimit: 30)
        XCTAssertGreaterThan(split.count, 2)
        XCTAssertTrue(split.dropLast().allSatisfy { $0.hasSuffix("。") })
    }
}
