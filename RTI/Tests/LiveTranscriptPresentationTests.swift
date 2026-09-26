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
        XCTAssertEqual(LiveTranscriptPresentation.label(for: "self", names: ["self": "Tristan"]), "Tristan")
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

    func test_interimFromTheLastSpeakerContinuesTheirRun() {
        let segments = LiveTranscriptPresentation.interimSegments("self: sure  remote_1: and I'll tag design")
        let placed = LiveTranscriptPresentation.placeInterim(segments, afterSpeaker: "remote_1")
        XCTAssertEqual(placed.inline, "and I'll tag design")
        XCTAssertEqual(placed.trailing, [.init(speakerId: "self", text: "sure")])

        let afterNote = LiveTranscriptPresentation.placeInterim(segments, afterSpeaker: "note")
        XCTAssertEqual(afterNote.inline, "")
        XCTAssertEqual(afterNote.trailing.count, 2)
    }

    // MARK: - Attendee names

    func test_nameChoicesOfferInviteesOnce() {
        let attendees: [CalendarMeeting.Attendee] = [
            .init(name: "Tristan McInnis", email: "t@example.com", isCurrentUser: true),
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
}
