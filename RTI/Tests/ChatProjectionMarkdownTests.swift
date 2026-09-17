import XCTest
@testable import RTICore

/// The session projection: a recording's chats rendered with their exact ids.
final class ChatProjectionMarkdownTests: XCTestCase {

    private func threads() -> [ChatProjectionMarkdown.Thread] {
        [
            ChatProjectionMarkdown.Thread(
                id: "thread-a",
                title: "First chat",
                createdAt: Date(timeIntervalSince1970: 1_000),
                turns: [
                    .init(id: "turn-a1", role: "user", text: "what changed?", status: "completed"),
                    .init(id: "turn-a2", role: "assistant", text: "Pricing moved.", status: "completed"),
                ]
            ),
            ChatProjectionMarkdown.Thread(
                id: "thread-b",
                title: nil,
                createdAt: Date(timeIntervalSince1970: 2_000),
                turns: [
                    .init(id: "turn-b1", role: "user", text: "and the deck?", status: "completed"),
                    .init(id: "turn-b2", role: "assistant", text: "", status: "cancelled"),
                ]
            ),
        ]
    }

    func testEveryThreadAndTurnKeepsItsOwnId() {
        let text = ChatProjectionMarkdown.render(
            threads: threads(),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3_000),
            header: "### Header"
        )

        XCTAssertTrue(text.contains("2 chats in this recording"))
        for id in ["thread-a", "thread-b", "turn-a1", "turn-a2", "turn-b1", "turn-b2"] {
            XCTAssertTrue(text.contains(id), "\(id) must survive into the projection")
        }
        XCTAssertTrue(text.contains("First chat"))
        XCTAssertTrue(text.contains("Chat 2"), "an untitled chat is still its own section")
        XCTAssertTrue(text.contains("· cancelled") == false, "the status is written in the turn note")
        XCTAssertTrue(text.contains("turn `turn-b2`, cancelled"), "an interrupted answer says so")
    }

    func testASingleChatDoesNotClaimABoundary() {
        let one = [threads()[0]]
        let text = ChatProjectionMarkdown.render(
            threads: one,
            startedAt: Date(),
            endedAt: Date(),
            header: "### Header"
        )
        XCTAssertFalse(text.contains("chats in this recording"), "one chat states no count")
        XCTAssertTrue(text.contains("thread-a"))
    }

    func testAnUnreadableChatIsReportedNotDropped() {
        let text = ChatProjectionMarkdown.render(
            threads: [threads()[0]],
            startedAt: Date(),
            endedAt: Date(),
            unreadableChats: 2,
            header: "### Header"
        )
        XCTAssertTrue(text.contains("2 stored chats in this recording could not be read"))
        XCTAssertTrue(text.contains("Nothing was removed"))
    }

    func testTheSidecarSectionCarriesTheSameIds() {
        let lines = ChatProjectionMarkdown.renderSection(threads: threads(), unreadableChats: 1)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("## Assistant chat"))
        XCTAssertTrue(text.contains("thread-b"))
        XCTAssertTrue(text.contains("turn-b1"))
        XCTAssertTrue(text.contains("could not be read"))
    }

    func testAnEmptyProjectionRendersNoSection() {
        XCTAssertTrue(ChatProjectionMarkdown.renderSection(threads: [], unreadableChats: 0).isEmpty)
    }
}
