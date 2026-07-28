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
}
