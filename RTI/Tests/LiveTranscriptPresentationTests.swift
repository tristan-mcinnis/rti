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

        XCTAssertEqual(rows.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
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

        XCTAssertEqual(rows.map(\.speakerLabel), ["Speaker 1", "Note", "Speaker 1"])
        XCTAssertEqual(rows.map(\.original), ["first", "remember this", "second"])
    }

    func test_copyTextIncludesTranslationWhenVisible() {
        let rows = LiveTranscriptPresentation.rows(
            from: [
                entry("bonjour", speaker: "remote_1", start: 61000),
                entry("hello", speaker: "remote_1", start: 61200, translationStatus: "translation", language: "en"),
            ],
            showTranslations: true,
            speakerLabelStyle: .displayNames(["remote_1": "Client"])
        )

        XCTAssertEqual(
            LiveTranscriptPresentation.copyText(rows: rows, showTranslations: true),
            "[01:01] Client: bonjour\n[01:01] Translation EN: hello"
        )
    }

    func test_displayInterimHidesRawSpeakerIDs() {
        XCTAssertEqual(
            LiveTranscriptPresentation.displayInterim(
                "remote_2: mockup is going to be  self: based on the study"
            ),
            "mockup is going to be  based on the study"
        )
    }

    func test_displayInterimPreservesOrdinaryColons() {
        XCTAssertEqual(
            LiveTranscriptPresentation.displayInterim("Decision: validate phase one"),
            "Decision: validate phase one"
        )
    }
}
