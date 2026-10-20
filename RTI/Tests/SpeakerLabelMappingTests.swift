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

    func testRawKeyInvertsDisplayLabel() {
        for raw in ["self", "room_1", "remote_2", "them_3"] {
            let label = SpeakerLabelMapping.displayLabel(forRawKey: raw)!
            XCTAssertEqual(SpeakerLabelMapping.rawKey(forDisplayLabel: label), raw)
        }
        XCTAssertNil(SpeakerLabelMapping.rawKey(forDisplayLabel: "Priya Shah"))
        XCTAssertNil(SpeakerLabelMapping.rawKey(forDisplayLabel: "Speaker 0"))
        XCTAssertNil(SpeakerLabelMapping.rawKey(forDisplayLabel: "📝 Note"))
    }

    func testDisplayLabelMatchesRawLabelRoundTrip() {
        // Every label rawLabel can mint must map to a display label.
        XCTAssertEqual(
            SpeakerLabelMapping.displayLabel(forRawKey: SpeakerLabelMapping.rawLabel(speaker: 2, channel: "system")),
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

    /// Soniox numbers diarized voices from 1. The system leg's first voice is
    /// `remote_1` (it was `remote_2`), and an unlabelled token (0) joins it,
    /// as mic 0 and 1 are both `self`.
    func testSystemLegNumbersVoicesFromOne() {
        XCTAssertEqual(SpeakerLabelMapping.rawLabel(speaker: 1, channel: "system"), "remote_1")
        XCTAssertEqual(SpeakerLabelMapping.rawLabel(speaker: 0, channel: "system"), "remote_1")
        XCTAssertEqual(SpeakerLabelMapping.rawLabel(speaker: 3, channel: "system"), "remote_3")
        XCTAssertEqual(SpeakerLabelMapping.rawLabel(speaker: 1, channel: "mic"), "self")
        XCTAssertEqual(SpeakerLabelMapping.rawLabel(speaker: 2, channel: "mic"), "room_1")
    }

    // MARK: displayKeyedNames

    func testDisplayKeyedNamesConvertsRawDropsSelfKeepsDisplay() {
        let converted = SpeakerLabelMapping.displayKeyedNames([
            "self": "Sam",
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
        XCTAssertEqual(SpeakerLabelMapping.displayKeyedNames(["self": "Sam"]), [:])
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
}
