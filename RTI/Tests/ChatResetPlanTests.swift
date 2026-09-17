import XCTest
@testable import RTICore

/// `/new` and `/clear` clear pending context; they never end a recording and
/// never discard the thread that was already recorded.
final class ChatResetPlanTests: XCTestCase {

    func testNewAndClearAreTheSameBehaviour() {
        let viaNew = ChatResetPlan.plan(forCommand: "new")
        let viaClear = ChatResetPlan.plan(forCommand: "clear")
        let viaSlash = ChatResetPlan.plan(forCommand: "/clear")

        XCTAssertEqual(viaNew?.command, "new")
        XCTAssertEqual(viaClear?.command, "clear")
        XCTAssertEqual(viaSlash?.command, "clear")
        XCTAssertEqual(viaNew?.clearsDraft, viaClear?.clearsDraft)
        XCTAssertEqual(viaNew?.cancelsStream, viaClear?.cancelsStream)
    }

    func testAnUnknownCommandHasNoResetPlan() {
        XCTAssertNil(ChatResetPlan.plan(forCommand: "recap"))
        XCTAssertNil(ChatResetPlan.plan(forCommand: "foo"))
    }

    func testThePlanClearsPendingContext() {
        let plan = ChatResetPlan.forNewChat
        XCTAssertTrue(plan.clearsDraft)
        XCTAssertTrue(plan.clearsAttachments)
        XCTAssertTrue(plan.clearsPendingScreenContext)
        XCTAssertTrue(plan.clearsQueuedFollowUp)
        XCTAssertTrue(plan.cancelsStream)
        XCTAssertTrue(plan.resetsModelSelection)
        XCTAssertTrue(plan.resetsBroaderSearch)
    }

    func testThePlanNeverEndsTheRecordingOrDiscardsTheThread() {
        for word in ["new", "clear"] {
            guard let plan = ChatResetPlan.plan(forCommand: word) else {
                return XCTFail("\(word) must have a plan")
            }
            XCTAssertTrue(plan.preservesSavedThread, "\(word) must keep the recorded thread")
            XCTAssertTrue(plan.preservesRecording, "\(word) must not end the recording")
            XCTAssertTrue(plan.preservesLiveNotes, "\(word) must not drop live notes")
        }
    }

    func testCaseAndSlashAreBothAccepted() {
        XCTAssertEqual(ChatResetPlan.plan(forCommand: "/NEW")?.command, "new")
        XCTAssertEqual(ChatResetPlan.plan(forCommand: "Clear")?.command, "clear")
    }
}
