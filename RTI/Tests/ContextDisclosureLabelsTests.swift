import XCTest
@testable import RTICore

/// The composer's "Next answer uses" line names what the turn actually sends,
/// including the ambient screen trail and this chat's retained sources.
final class ContextDisclosureLabelsTests: XCTestCase {

    func testAnEmptyStateNamesNothing() {
        XCTAssertTrue(ContextDisclosureLabels.make(ContextDisclosureInput()).isEmpty)
    }

    func testTheOrdinaryContextIsNamedInOrder() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(
            hasLiveTranscript: true,
            workstreamName: "Northwind app",
            hasMeetingNote: true,
            hasBrief: true,
            glossaryEntryCount: 2
        ))
        XCTAssertEqual(labels, ["Live transcript", "Northwind app", "Meeting note", "Brief", "Glossary"])
    }

    func testAnAmbientScreenTrailIsNamedWithoutAManualCapture() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(hasAmbientScreenRead: true))
        XCTAssertEqual(labels, [ContextDisclosureLabels.ambientScreenLabel])
        XCTAssertTrue(labels.contains { $0.hasPrefix("Screen OCR") },
                      "a screen block on the wire must be named")
    }

    func testAManualCaptureKeepsItsOwnLabel() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(hasPendingScreenCapture: true))
        XCTAssertEqual(labels, [ContextDisclosureLabels.screenCaptureLabel])
    }

    func testRetainedSourcesAreNamedWhenTheyAreOnTheWire() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(
            retainedSourceNames: ["report.pdf", "photo.png"]
        ))
        XCTAssertEqual(labels, ["This chat's saved sources (report.pdf, photo.png)"])
    }

    func testMoreThanTwoRetainedSourcesStayOneLine() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(
            retainedSourceNames: ["a.pdf", "b.png", "c.md"]
        ))
        XCTAssertEqual(labels, ["This chat's saved sources (a.pdf, b.png, and 1 more)"])
    }

    func testADatedHandOverIsNamed() {
        let labels = ContextDisclosureLabels.make(ContextDisclosureInput(
            datedSourceName: "Dated entry 12 Sep 2026 · 07:04"
        ))
        XCTAssertEqual(labels, ["Dated entry 12 Sep 2026 · 07:04"])
    }

    /// The footnote may name a screen entry exactly when a screen block is
    /// sent, so the two cannot silently disagree.
    func testTheScreenEntryTracksTheScreenBlock() {
        func hasScreenEntry(_ input: ContextDisclosureInput) -> Bool {
            ContextDisclosureLabels.make(input).contains {
                $0 == ContextDisclosureLabels.screenCaptureLabel
                    || $0 == ContextDisclosureLabels.ambientScreenLabel
            }
        }
        XCTAssertFalse(hasScreenEntry(ContextDisclosureInput()))
        XCTAssertTrue(hasScreenEntry(ContextDisclosureInput(hasPendingScreenCapture: true)))
        XCTAssertTrue(hasScreenEntry(ContextDisclosureInput(hasAmbientScreenRead: true)))
        XCTAssertTrue(hasScreenEntry(ContextDisclosureInput(
            hasPendingScreenCapture: true,
            hasAmbientScreenRead: true
        )))
    }
}
