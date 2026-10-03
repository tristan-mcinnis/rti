import XCTest

final class FindingEntryTests: XCTestCase {
    func testMarkedNoteParsesCorePrefixes() {
        let cases: [(String, FindingTag, String)] = [
            ("decision: Hold Air Force One scope until client confirms budget", .decision, "Hold Air Force One scope until client confirms budget"),
            ("action - Sam to send revised timeline", .action, "Sam to send revised timeline"),
            ("question: Who owns recruiting?", .openQuestion, "Who owns recruiting?"),
            ("risk: timeline slips if stimulus arrives late", .risk, "timeline slips if stimulus arrives late"),
            ("follow-up: confirm whether slide 10 is final", .followUp, "confirm whether slide 10 is final"),
        ]

        for (raw, tag, headline) in cases {
            let entry = FindingEntry.markedNote(from: raw, startMs: 42_000)
            XCTAssertEqual(entry?.tag, tag, raw)
            XCTAssertEqual(entry?.headline, headline, raw)
            XCTAssertEqual(entry?.rangeMs, 42_000, raw)
            XCTAssertEqual(entry?.speaker, "User note", raw)
        }
    }

    func testMarkedNoteIgnoresUnstructuredNotes() {
        XCTAssertNil(FindingEntry.markedNote(from: "this is just a normal note", startMs: 0))
        XCTAssertNil(FindingEntry.markedNote(from: "decision:", startMs: 0))
    }
}
