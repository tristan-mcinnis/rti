import XCTest

/// Pins the menu-bar glyph family. DESIGN.md bans letters in circles and asks
/// the status item to use the same silhouette as the app icon (a record ring),
/// so a regression back to `r.circle` must fail here.
final class StatusItemSymbolTests: XCTestCase {
    func testUsesTheRecordRingFamily() {
        XCTAssertEqual(StatusItemSymbol.idle, "record.circle")
        XCTAssertEqual(StatusItemSymbol.recording, "record.circle.fill")
    }

    func testNoLettersInCircles() {
        for symbol in [StatusItemSymbol.idle, StatusItemSymbol.recording] {
            XCTAssertFalse(symbol.hasPrefix("r.circle"), "\(symbol) is a letter in a circle")
        }
    }

    func testNameFollowsRunningState() {
        XCTAssertEqual(StatusItemSymbol.name(running: false), StatusItemSymbol.idle)
        XCTAssertEqual(StatusItemSymbol.name(running: true), StatusItemSymbol.recording)
    }

    /// The accessibility descriptions the status item has always carried.
    func testAccessibilityDescriptionsAreUnchanged() {
        XCTAssertEqual(StatusItemSymbol.accessibilityDescription(running: false), "RTI")
        XCTAssertEqual(StatusItemSymbol.accessibilityDescription(running: true), "RTI recording")
    }
}
