import RTICore
import XCTest

/// Pins PromptBuilder's message assembly: ordering of the system attachments,
/// reference truncation, and how the conversation history is built (the latest
/// user turn carries the transcript-augmented content).
final class PromptBuilderTests: XCTestCase {
    private func entry(_ role: String, _ text: String) -> ChatEntry {
        ChatEntry(role: role, text: text, action: nil, contextUsed: false, screenContextUsed: false)
    }

    func test_systemMessages_orderBaseGlossaryReferenceScreen() {
        let ctx = PromptContext(
            baseSystemPrompt: "BASE",
            glossaryFragment: "GLOSSARY",
            referenceText: "REF",
            referenceModeName: "Interview",
            screenContext: "SCREEN"
        )
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertTrue(msgs.allSatisfy { $0.role == "system" })
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0].content, "BASE")
        XCTAssertEqual(msgs[1].content, "GLOSSARY")
        XCTAssertTrue(msgs[2].content?.contains("REF") ?? false)
        XCTAssertTrue(msgs[2].content?.contains("Interview") ?? false)
        XCTAssertTrue(msgs[3].content?.contains("SCREEN") ?? false)
    }

    func test_systemMessages_emptyContext_isEmpty() {
        XCTAssertTrue(PromptBuilder.buildSystemMessages(context: PromptContext()).isEmpty)
    }

    func test_systemMessages_meetingContextFollowsBase() {
        let ctx = PromptContext(baseSystemPrompt: "BASE", meetingContext: "Client: Acme, status: behind")
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].content, "BASE")
        XCTAssertTrue(msgs[1].content?.contains("Acme") ?? false)
    }

    func test_systemMessages_skipsBlankMeetingContext() {
        let ctx = PromptContext(baseSystemPrompt: "BASE", meetingContext: "   ")
        XCTAssertEqual(PromptBuilder.buildSystemMessages(context: ctx).count, 1)
    }

    func test_systemMessages_skipsEmptyReference() {
        let ctx = PromptContext(baseSystemPrompt: "BASE", referenceText: "")
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].content, "BASE")
    }

    func test_systemMessages_truncatesLongReference() throws {
        let long = String(repeating: "a", count: 9000)
        let ctx = PromptContext(referenceText: long, referenceModeName: "Mode")
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        let ref = try XCTUnwrap(msgs.first?.content)
        XCTAssertTrue(ref.contains("[truncated]"))
        // Reference body capped at 8000 chars: 8000 consecutive 'a's present,
        // 8001 are not (the original was 9000).
        XCTAssertTrue(ref.contains(String(repeating: "a", count: 8000)))
        XCTAssertFalse(ref.contains(String(repeating: "a", count: 8001)))
    }

    func test_conversation_latestUserTurnUsesFullContent() {
        let entries = [entry("user", "first"), entry("assistant", "reply"), entry("user", "raw latest")]
        let msgs = PromptBuilder.buildConversationMessages(entries: entries, fullContent: "AUGMENTED")
        XCTAssertEqual(msgs.map(\.content), ["first", "reply", "AUGMENTED"])
    }

    func test_conversation_skipsEmptyNonLatestEntries() {
        let entries = [entry("assistant", ""), entry("user", "hi")]
        let msgs = PromptBuilder.buildConversationMessages(entries: entries, fullContent: "FULL")
        // The empty assistant entry is dropped; the latest user gets fullContent.
        XCTAssertEqual(msgs.map(\.content), ["FULL"])
    }
}
