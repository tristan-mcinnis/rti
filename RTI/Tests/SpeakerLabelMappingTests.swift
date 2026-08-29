import RTICore
import XCTest

/// Pins the raw-id → display-label mapping that keys `speaker-names.json`,
/// the transcript label scrape behind the post-hoc rename editor, and the
/// `speaker-suggestions.json` reader.
final class SpeakerLabelMappingTests: XCTestCase {

    // MARK: displayLabel(forRawKey:)

    func testDisplayLabelMapsRawIds() {
        XCTAssertEqual(SpeakerLabelMapping.displayLabel(forRawKey: "self"), "You")
        XCTAssertEqual(SpeakerLabelMapping.displayLabel(forRawKey: "room_1"), "Room speaker 1")
        XCTAssertEqual(SpeakerLabelMapping.displayLabel(forRawKey: "remote_2"), "Remote speaker 2")
        XCTAssertEqual(SpeakerLabelMapping.displayLabel(forRawKey: "them_3"), "Speaker 3")
    }

    func testDisplayLabelRejectsNonRawKeys() {
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: "note"))
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: "Speaker 1"))
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: "Remote speaker 1"))
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: "room_"))
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: "room_x"))
        XCTAssertNil(SpeakerLabelMapping.displayLabel(forRawKey: ""))
    }

    func testDisplayLabelMatchesRawLabelRoundTrip() {
        // Every label rawLabel can mint must map to a display label.
        XCTAssertEqual(
            SpeakerLabelMapping.displayLabel(forRawKey: SpeakerLabelMapping.rawLabel(speaker: 1, channel: "system")),
            "Remote speaker 2"
        )
        XCTAssertEqual(
            SpeakerLabelMapping.displayLabel(forRawKey: SpeakerLabelMapping.rawLabel(speaker: 2, channel: "mic")),
            "Room speaker 1"
        )
        XCTAssertEqual(
            SpeakerLabelMapping.displayLabel(forRawKey: SpeakerLabelMapping.rawLabel(speaker: 4)),
            "Speaker 4"
        )
    }

    // MARK: displayKeyedNames

    func testDisplayKeyedNamesConvertsRawDropsSelfKeepsDisplay() {
        let converted = SpeakerLabelMapping.displayKeyedNames([
            "self": "Tristan",
            "remote_1": "Alex",
            "them_2": "Bob",
            "Speaker 3": "Carol",
        ])
        XCTAssertEqual(converted, [
            "Remote speaker 1": "Alex",
            "Speaker 2": "Bob",
            "Speaker 3": "Carol",
        ])
    }

    func testDisplayKeyedNamesEmptyInput() {
        XCTAssertEqual(SpeakerLabelMapping.displayKeyedNames([:]), [:])
        XCTAssertEqual(SpeakerLabelMapping.displayKeyedNames(["self": "Tristan"]), [:])
    }

    // MARK: archivedSpeakerLabels(in:)

    func testArchivedSpeakerLabelsScrapesDedupesAndOrders() {
        let transcript = """
        `0:07` **Speaker 2:** Morning.
        `0:08` **Remote speaker 1:** Morning. How's it going?
        `0:11` **Speaker 1:** Good.
        `0:30` **📝 Note:** Speaker 1 said something useful.
        `0:40` **Room speaker 1:** From the room mic.
        `0:55` **Speaker 1:** Again.
        """
        XCTAssertEqual(
            SpeakerLabelMapping.archivedSpeakerLabels(in: transcript),
            ["Speaker 1", "Speaker 2", "Room speaker 1", "Remote speaker 1"]
        )
    }

    func testArchivedSpeakerLabelsSortsNumerically() {
        let transcript = "**Speaker 10:** a\n**Speaker 2:** b\n**Speaker 1:** c"
        XCTAssertEqual(
            SpeakerLabelMapping.archivedSpeakerLabels(in: transcript),
            ["Speaker 1", "Speaker 2", "Speaker 10"]
        )
    }

    func testArchivedSpeakerLabelsEmptyText() {
        XCTAssertEqual(SpeakerLabelMapping.archivedSpeakerLabels(in: ""), [])
        XCTAssertEqual(SpeakerLabelMapping.archivedSpeakerLabels(in: "no labels here"), [])
    }

    // MARK: SpeakerSuggestions decoding

    func testSpeakerSuggestionsDecodesMatcherOutput() throws {
        // Shape produced by speaker-profiles.py suggest (verified 2026-08-29).
        let json = """
        {
          "session": "/tmp/x",
          "generated": "2026-08-28T05:21:32.613592+00:00",
          "model": "campplus_zh_en_advanced.onnx",
          "thresholds": {"accept": 0.65, "maybe": 0.5},
          "speakers": [
            {"label": "Remote speaker 1", "leg": "system", "clips": 1,
             "suggestion": null, "score": 0.2562, "band": "unknown", "runner_up": null},
            {"label": "Speaker 1", "leg": "mic", "clips": 3,
             "suggestion": "Tristan McInnis", "score": 0.6573, "band": "accept",
             "runner_up": {"name": "Alex Wilson", "score": 0.31}},
            {"label": "Speaker 2", "leg": "mic", "band": "maybe",
             "suggestion": "Alex Wilson", "score": 0.55, "clips": 2}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(SpeakerSuggestions.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.speakers.count, 3)

        let accept = try XCTUnwrap(decoded.entry(for: "Speaker 1"))
        XCTAssertTrue(accept.isAccept)
        XCTAssertFalse(accept.isMaybe)
        XCTAssertEqual(accept.suggestion, "Tristan McInnis")
        XCTAssertEqual(accept.score ?? 0, 0.6573, accuracy: 0.0001)

        let unknown = try XCTUnwrap(decoded.entry(for: "Remote speaker 1"))
        XCTAssertFalse(unknown.isAccept)
        XCTAssertNil(unknown.suggestion)

        let maybe = try XCTUnwrap(decoded.entry(for: "Speaker 2"))
        XCTAssertTrue(maybe.isMaybe)
        XCTAssertNil(decoded.entry(for: "Speaker 9"))
    }
}
