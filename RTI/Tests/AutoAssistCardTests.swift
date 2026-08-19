import XCTest

/// Locks the tolerant kind parsing Auto mode relies on — the model emits
/// uppercase tags and a few synonyms, and an unknown tag must not drop the card.
final class AutoAssistCardTests: XCTestCase {
    func testCanonicalKinds() {
        XCTAssertEqual(AutoCardKind(raw: "SAY"), .say)
        XCTAssertEqual(AutoCardKind(raw: "ASK"), .ask)
        XCTAssertEqual(AutoCardKind(raw: "RECALL"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "FLAG"), .flag)
    }

    func testSynonymsAndCase() {
        XCTAssertEqual(AutoCardKind(raw: "context"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "Info"), .recall)
        XCTAssertEqual(AutoCardKind(raw: "watch"), .flag)
    }

    func testUnknownFallsBackToRecall() {
        XCTAssertEqual(AutoCardKind(raw: "banana"), .recall)
        XCTAssertEqual(AutoCardKind(raw: ""), .recall)
    }
}
