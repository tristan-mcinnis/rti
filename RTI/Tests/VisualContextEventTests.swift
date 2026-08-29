import XCTest
@testable import RTICore

final class VisualContextEventTests: XCTestCase {
    func testCompactionRemovesBlankLinesAndCapsText() {
        let result = VisualContextText.compact("  Alpha  \n\n Beta ", maxCharacters: 8)
        XCTAssertEqual(result, "Alpha\nBe\n…[truncated]")
    }

    func testNearDuplicateOCRIsNotMeaningfullyDifferent() {
        let first = "Quarterly planning document with pricing actions owners timeline"
        let second = "Quarterly planning document with pricing actions owners timeline 10:42"
        XCTAssertFalse(VisualContextText.isMeaningfullyDifferent(second, from: first))
    }

    func testChangedScreenIsMeaningfullyDifferent() {
        let first = "Quarterly planning document with pricing actions owners timeline"
        let second = "Customer interview transcript discussing onboarding and support pain points"
        XCTAssertTrue(VisualContextText.isMeaningfullyDifferent(second, from: first))
    }

    func testPromptContextUsesRecentTimestampedEvents() {
        let events = [
            VisualContextEvent(offsetSeconds: 5, text: "First screen"),
            VisualContextEvent(offsetSeconds: 65, text: "Second screen"),
            VisualContextEvent(offsetSeconds: 125, text: "Third screen"),
        ]
        let result = VisualContextText.promptContext(events: events, maxEvents: 2) ?? ""
        XCTAssertFalse(result.contains("First screen"))
        XCTAssertTrue(result.contains("[01:05]"))
        XCTAssertTrue(result.contains("[02:05]"))
        XCTAssertTrue(result.contains("supporting context"))
    }

    func testPromptContextCarriesVisionSummaryWhenPresent() {
        let events = [
            VisualContextEvent(
                offsetSeconds: 30,
                text: "Spreadsheet cells",
                visionSummary: "A budget spreadsheet with a bar chart on the right."
            ),
        ]
        let result = VisualContextText.promptContext(events: events) ?? ""
        XCTAssertTrue(result.contains("What the screen looks like: A budget spreadsheet"))
    }

    func testLegacyEventJSONDecodesWithoutNewFields() throws {
        let legacy = Data("""
        {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "offsetSeconds": 12, "text": "old event"}
        """.utf8)
        let event = try JSONDecoder().decode(VisualContextEvent.self, from: legacy)
        XCTAssertEqual(event.offsetSeconds, 12)
        XCTAssertEqual(event.text, "old event")
        XCTAssertNil(event.visionSummary)
        XCTAssertNil(event.frameFilename)
    }

    func testWithVisionSummaryPreservesIdentityAndFrame() {
        let event = VisualContextEvent(
            offsetSeconds: 90,
            text: "OCR text",
            frameFilename: "frame-00090-ambient-ab12.jpg"
        )
        let updated = event.withVisionSummary("A code editor beside a terminal.")
        XCTAssertEqual(updated.id, event.id)
        XCTAssertEqual(updated.offsetSeconds, 90)
        XCTAssertEqual(updated.text, "OCR text")
        XCTAssertEqual(updated.frameFilename, "frame-00090-ambient-ab12.jpg")
        XCTAssertEqual(updated.visionSummary, "A code editor beside a terminal.")
    }
}
