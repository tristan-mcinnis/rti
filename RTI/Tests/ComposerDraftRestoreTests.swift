import RTICore
import XCTest

/// A returned draft never overwrites what the user typed.
final class ComposerDraftRestoreTests: XCTestCase {
    func testReturnedDraftFillsAnEmptyField() {
        XCTAssertEqual(ComposerDraftRestore.fieldText(current: "", restored: "What did the client say?"), "What did the client say?")
        XCTAssertEqual(ComposerDraftRestore.fieldText(current: "  \n", restored: "Searched question"), "Searched question")
    }

    func testQueuedFollowUpStaysWhenStopReturnsTheSearchedQuestion() {
        // A search is running, the user queues a follow-up, then presses Stop:
        // cancel() hands back the searched question, the follow-up stays.
        XCTAssertNil(ComposerDraftRestore.fieldText(current: "And the budget?", restored: "Searched question"))
    }

    func testNothingToRestoreLeavesTheField() {
        XCTAssertNil(ComposerDraftRestore.fieldText(current: "", restored: nil))
        XCTAssertNil(ComposerDraftRestore.fieldText(current: "", restored: ""))
        XCTAssertNil(ComposerDraftRestore.fieldText(current: "typed", restored: nil))
    }
}
