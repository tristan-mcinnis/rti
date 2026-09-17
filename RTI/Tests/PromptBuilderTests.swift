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

    func test_systemMessages_discussionGuideInjected() {
        let ctx = PromptContext(baseSystemPrompt: "BASE", discussionGuide: "[ ] What drives your purchase?")
        let msgs = PromptBuilder.buildSystemMessages(context: ctx)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertTrue(msgs[1].content?.contains("discussion guide") ?? false)
        XCTAssertTrue(msgs[1].content?.contains("What drives your purchase?") ?? false)
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

    func test_systemMessages_referencedDocumentsComeLast() {
        let ctx = PromptContext(
            baseSystemPrompt: "BASE",
            screenContext: "SCREEN",
            referencedDocuments: "## projects/acme/discussion-guide.md\n\nGUIDE"
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

    func test_promptContext_hasContentWhenReferencedDocumentsPresent() {
        XCTAssertTrue(PromptContext(referencedDocuments: "doc").hasContent)
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
