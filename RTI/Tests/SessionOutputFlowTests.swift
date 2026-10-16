import RTICore
import XCTest

/// The deterministic reducer behind the saved-meeting output chooser: the
/// session-switch and cancel flows, with no timing or I/O in them.
final class SessionOutputFlowTests: XCTestCase {
    func testStartsIdle() {
        let flow = SessionOutputFlow()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.selectedRecipeID)
        XCTAssertFalse(flow.isGenerating)
    }

    func testSelectThenBeginThenSucceed() {
        var flow = SessionOutputFlow()
        XCTAssertTrue(flow.select(recipeID: "decision-log"))
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertEqual(flow.selectedRecipeID, "decision-log")
        XCTAssertTrue(flow.begin())
        XCTAssertEqual(flow.phase, .generating)
        XCTAssertTrue(flow.isGenerating)
        let artifact = SessionOutputArtifact(
            url: URL(fileURLWithPath: "/tmp/decision-log-1.md"),
            templateID: "decision-log",
            templateName: "Decision log",
            generatedAt: nil
        )
        flow.succeed(artifact)
        XCTAssertEqual(flow.phase, .saved(artifact))
        XCTAssertEqual(flow.savedFileName, "decision-log-1.md")
    }

    func testBeginWithoutSelectionIsRefused() {
        var flow = SessionOutputFlow()
        XCTAssertFalse(flow.begin())
        XCTAssertEqual(flow.phase, .idle)
    }

    func testSelectNilClearsToIdle() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.select(recipeID: nil)
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.selectedRecipeID)
    }

    func testDoubleBeginIsRefused() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        XCTAssertTrue(flow.begin())
        XCTAssertFalse(flow.begin(), "a second start must not restart the running run")
        XCTAssertEqual(flow.phase, .generating)
    }

    func testSelectingWhileGeneratingIsIgnored() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.begin()
        XCTAssertFalse(flow.select(recipeID: "research-debrief"))
        XCTAssertEqual(flow.selectedRecipeID, "decision-log")
        XCTAssertEqual(flow.phase, .generating)
    }

    func testFailKeepsMessageAndFallsBackWhenBlank() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.begin()
        flow.fail("   ")
        XCTAssertEqual(flow.phase, .failed("The output could not be generated."))
        // Not generating any more, so a new run may start.
        flow.begin()
        flow.fail("network down")
        XCTAssertEqual(flow.phase, .failed("network down"))
    }

    func testCancelOnlyAppliesWhileGenerating() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.cancel()
        XCTAssertEqual(flow.phase, .ready, "a cancel with nothing running is a no-op")
        flow.begin()
        flow.cancel()
        XCTAssertEqual(flow.phase, .cancelled)
        XCTAssertFalse(flow.isGenerating)
    }

    func testLateCancelCannotEraseASavedResult() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.begin()
        let artifact = SessionOutputArtifact(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            templateID: "decision-log",
            templateName: "Decision log",
            generatedAt: nil
        )
        flow.succeed(artifact)
        flow.cancel()
        XCTAssertEqual(flow.phase, .saved(artifact))
    }

    func testSessionSwitchResetsSelectionAndPhase() {
        var flow = SessionOutputFlow()
        flow.select(recipeID: "decision-log")
        flow.begin()
        flow.reset()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertNil(flow.selectedRecipeID)
        XCTAssertFalse(flow.isGenerating)
    }
}
