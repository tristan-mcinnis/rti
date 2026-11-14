import XCTest

/// The 2026-11-14 calm pass: rules that are not pixels.
@MainActor
final class CalmPassTests: XCTestCase {
    /// A follow-up queued during a turn is sent only when that turn finished
    /// its answer. A new turn starts as not completed, so Esc, Stop, a
    /// failure or a screen-policy cancel never count as finished.
    func testANewTurnStartsNotCompleted() {
        let llm = LLMController.shared
        let wasStreaming = llm.streaming
        defer { llm.streaming = wasStreaming }
        llm.streaming = false
        llm.lastTurnCompleted = true
        llm.streaming = true
        XCTAssertFalse(llm.lastTurnCompleted)
        llm.streaming = false
        XCTAssertFalse(llm.lastTurnCompleted, "ending without finishing the answer is not completed")
    }

    func testGuideSectionCountsAreWords() {
        XCTAssertEqual(GuideSectionSummary.text(["Answered", "Answered", "Lightly covered", "Pending"]),
                       "2 answered · 1 thin · 1 to ask")
        XCTAssertEqual(GuideSectionSummary.text([]), "")
    }

    func testSidebarIsIconsOnlyBesideAnotherListOrWhenNarrow() {
        XCTAssertFalse(WorkspaceSidebarSettings.isCompact(page: .live, windowWidth: 1200))
        XCTAssertTrue(WorkspaceSidebarSettings.isCompact(page: .live, windowWidth: 800))
        for page in [WorkspaceModel.Page.sessions, .chats, .settings] {
            XCTAssertTrue(WorkspaceSidebarSettings.isCompact(page: page, windowWidth: 1400))
        }
    }
}
