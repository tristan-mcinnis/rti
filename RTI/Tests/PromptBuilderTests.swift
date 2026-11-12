import Foundation
import RTICore
import XCTest

/// Pins PromptBuilder's message assembly: ordering of the system attachments,
/// reference truncation, and how the conversation history is built (the latest
/// user turn carries the transcript-augmented content).
final class PromptBuilderTests: XCTestCase {
    private func entry(_ role: String, _ text: String) -> ChatEntry {
        ChatEntry(role: role, text: text, action: nil, contextUsed: false, screenContextUsed: false)
    }

    func test_systemMessages_orderBaseGlossaryScreen() {
        let ctx = PromptContext(
            baseSystemPrompt: "BASE",
            glossaryFragment: "GLOSSARY",
            screenContext: "SCREEN"
        )
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertTrue(msgs.allSatisfy { $0.role == "system" })
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].content, "BASE")
        XCTAssertEqual(msgs[1].content, "GLOSSARY")
        XCTAssertTrue(msgs[2].content?.contains("SCREEN") ?? false)
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

    func test_systemMessages_referencedDocumentsComeLast() {
        let ctx = PromptContext(
            baseSystemPrompt: "BASE",
            screenContext: "SCREEN",
            referencedDocuments: "## projects/acme/discussion-guide.md\n\nGUIDE",
            sourceContext: TurnSourceContext(freshCount: 1)
        )
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].content, "BASE")
        XCTAssertTrue(msgs[1].content?.contains("SCREEN") ?? false)
        XCTAssertTrue(msgs[2].content?.contains("explicitly attached or @mentioned") ?? false)
        XCTAssertTrue(msgs[2].content?.contains("Do not search the vault") ?? false)
        XCTAssertTrue(msgs[2].content?.contains("discussion-guide.md") ?? false)
        XCTAssertTrue(msgs[2].content?.contains("GUIDE") ?? false)
    }

    /// A bare follow-up re-sends this chat's sources. The system block must not
    /// call them new, and a widened turn must not forbid the vault.
    func test_systemMessages_retainedDocumentsAreNotCalledNew() {
        let retained = PromptBuilder.buildSystemMessages(context: PromptContext(
            referencedDocuments: "GUIDE",
            sourceContext: TurnSourceContext(freshCount: 0, retainedCount: 1)
        ))
        let retainedText = retained.last?.content ?? ""
        XCTAssertFalse(retainedText.contains("for this turn"))
        XCTAssertTrue(retainedText.contains("retained from an earlier turn"))

        let widened = PromptBuilder.buildSystemMessages(context: PromptContext(
            referencedDocuments: "GUIDE",
            sourceContext: TurnSourceContext(freshCount: 0, retainedCount: 1),
            externalRetrievalAllowed: true
        ))
        XCTAssertFalse((widened.last?.content ?? "").contains("Do not search the vault"))
    }

    /// A context built without an origin says nothing about when the source
    /// arrived and permits nothing new.
    func test_systemMessages_aHeaderWithoutAnOriginClaimsNeither() {
        let msgs = PromptBuilder.buildSystemMessages(context: PromptContext(referencedDocuments: "GUIDE"))
        let text = msgs.last?.content ?? ""
        XCTAssertFalse(text.contains("for this turn"))
        XCTAssertFalse(text.contains("Do not search the vault"))
        XCTAssertTrue(text.contains("GUIDE"))
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

    func test_conversation_attachesImagesToLatestUserTurnOnly() {
        let image = LLMImage(jpegData: Data([0x01, 0x02]))
        let entries = [entry("user", "first"), entry("assistant", "reply"), entry("user", "raw latest")]
        let msgs = PromptBuilder.buildConversationMessages(
            entries: entries,
            fullContent: "AUGMENTED",
            images: [image]
        )
        XCTAssertEqual(msgs[0].images?.count ?? 0, 0)
        XCTAssertEqual(msgs[1].images?.count ?? 0, 0)
        XCTAssertEqual(msgs[2].images?.count, 1)
    }

    // MARK: - History cap

    private func longChat(exchanges: Int, answer: String = "reply") -> [ChatEntry] {
        (0 ..< exchanges).flatMap { [entry("user", "question \($0)"), entry("assistant", "\(answer) \($0)")] }
            + [entry("user", "raw latest")]
    }

    func test_conversation_capKeepsTheLastTwelvePriorExchangesAndTheLatestUserTurn() {
        let msgs = PromptBuilder.buildConversationMessages(entries: longChat(exchanges: 20), fullContent: "AUGMENTED")
        XCTAssertEqual(msgs.count, PromptBuilder.historyTurnCap * 2 + 1, "12 questions with their answers")
        XCTAssertEqual(msgs.last?.content, "AUGMENTED")
        XCTAssertEqual(msgs.last?.role, "user")
        XCTAssertEqual(msgs.first?.content, "question 8", "the oldest exchanges go first")
        XCTAssertEqual(msgs[msgs.count - 2].content, "reply 19")
    }

    func test_conversation_capDropsOldTurnsPastTheCharacterBudget() {
        let big = String(repeating: "x", count: 10000)
        let msgs = PromptBuilder.buildConversationMessages(entries: longChat(exchanges: 4, answer: big),
                                                           fullContent: "AUGMENTED")
        let prior = msgs.dropLast()
        let characters = prior.reduce(0) { $0 + ($1.content?.count ?? 0) }
        XCTAssertLessThanOrEqual(characters, PromptBuilder.historyCharacterCap)
        XCTAssertEqual(prior.count, 4, "two big answers and their questions fit; a third big answer does not")
        XCTAssertEqual(msgs.last?.content, "AUGMENTED")
    }

    func test_conversation_latestUserTurnIsKeptEvenWhenItAloneIsOverTheBudget() {
        let huge = String(repeating: "y", count: PromptBuilder.historyCharacterCap * 2)
        let image = LLMImage(jpegData: Data([0x01]))
        let msgs = PromptBuilder.buildConversationMessages(entries: longChat(exchanges: 2), fullContent: huge,
                                                           images: [image])
        XCTAssertEqual(msgs.last?.content, huge)
        XCTAssertEqual(msgs.last?.images?.count, 1)
        XCTAssertEqual(msgs.count, 5, "the short prior turns still fit beside it")
    }

    func test_conversation_newestPriorExchangeIsKeptEvenWhenItIsOverTheBudget() {
        let long = String(repeating: "z", count: PromptBuilder.historyCharacterCap + 1)
        let msgs = PromptBuilder.buildConversationMessages(entries: longChat(exchanges: 3, answer: long),
                                                           fullContent: "shorten that")
        XCTAssertEqual(msgs.map(\.content), ["question 2", "\(long) 2", "shorten that"],
                       "a follow-up keeps the answer it refers to, and the older exchanges go")
    }

    func test_conversation_cutHistoryNeverStartsWithAnAssistantMessage() {
        let big = String(repeating: "x", count: 9000)
        let entries = [entry("assistant", "Hi, how can I help?")]
            + (0 ..< 4).flatMap { [entry("user", "question \($0)"), entry("assistant", "\(big) \($0)"),
                                   entry("assistant", "more \($0)")] }
            + [entry("user", "raw latest")]
        let msgs = PromptBuilder.buildConversationMessages(entries: entries, fullContent: "AUGMENTED")
        XCTAssertEqual(msgs.first?.role, "user")
        XCTAssertEqual(msgs.first?.content, "question 2")
        XCTAssertEqual(msgs.count, 7)
    }

    func test_conversation_shortChatIsUnchanged() {
        let entries = longChat(exchanges: 3)
        let msgs = PromptBuilder.buildConversationMessages(entries: entries, fullContent: "AUGMENTED")
        XCTAssertEqual(msgs.count, entries.count)
    }

    // MARK: - Wire shape

    func test_wireMessage_plainTextEncodesContentAsString() throws {
        let json = try encodedJSON(LLMMessage(role: "user", content: "hello"))
        XCTAssertEqual(json["content"] as? String, "hello")
    }

    func test_wireMessage_withImageEncodesContentAsBlocks() throws {
        // Providers take images in USER messages as OpenAI content blocks: a
        // text block, then one `image_url` with an inline data URL. A plain
        // message must stay a bare string so the tool paths and other
        // providers keep working.
        let image = LLMImage(jpegData: Data([0xAA, 0xBB]))
        let json = try encodedJSON(LLMMessage(role: "user", content: "look", images: [image]))
        let blocks = try XCTUnwrap(json["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
        XCTAssertEqual(blocks[0]["text"] as? String, "look")
        XCTAssertEqual(blocks[1]["type"] as? String, "image_url")
        let url = try XCTUnwrap(blocks[1]["image_url"] as? [String: Any])
        XCTAssertTrue((url["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") ?? false)
        // The image must not leak as a separate top-level key.
        XCTAssertNil(json["images"])
    }

    private func encodedJSON(_ message: LLMMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
