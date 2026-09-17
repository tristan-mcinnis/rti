import XCTest
import HouseChatCore
@testable import RTICore

/// RTI's enforcement of the shared context policy: which of RTI's own tools
/// reach outside the conversation, and whether the tool loop actually refuses
/// one that was withheld.
final class ChatToolPolicyTests: XCTestCase {

    private func policy(
        currentSourceCount: Int = 0,
        historyTurnCount: Int = 0,
        historyHasSources: Bool = false,
        question: String = "what does this say?",
        override: ContextOverride? = nil
    ) -> ChatToolPolicy {
        let decision = ContextPolicy.standard.resolve(ChatContextRequestBuilder.request(
            question: question,
            currentSourceCount: currentSourceCount,
            historyTurnCount: historyTurnCount,
            historyHasSources: historyHasSources,
            broaderToggleOn: override == .broader
        ))
        return ChatToolPolicy(decision: decision)
    }

    func testOrdinaryChatAllowsExternalRetrieval() {
        let gate = policy()
        XCTAssertTrue(gate.allowsExternalRetrieval)
        XCTAssertTrue(gate.allowsTool(named: "search_vault"))
        XCTAssertTrue(gate.allowsTool(named: "list_files"))
    }

    func testAnAttachedSourceWithholdsExternalRetrieval() {
        let gate = policy(currentSourceCount: 1)
        XCTAssertFalse(gate.allowsExternalRetrieval)
        for name in ChatToolPolicy.discoveryToolNames {
            XCTAssertFalse(gate.allowsTool(named: name), "\(name) must not be offered")
        }
        // `read_document` reads the vault by path and the screen tools read the
        // display: both reach outside the conversation, so source-first
        // withholds them just like the search tools.
        XCTAssertFalse(gate.allowsTool(named: "read_document"))
        XCTAssertFalse(gate.allowsTool(named: "capture_screen"))
        XCTAssertFalse(gate.allowsTool(named: "highlight_screen_text"))
    }

    func testHistoryThatCarriedSourcesWithholdsExternalRetrieval() {
        let gate = policy(historyTurnCount: 3, historyHasSources: true)
        XCTAssertFalse(gate.allowsExternalRetrieval)
        XCTAssertFalse(gate.allowsTool(named: "grep_vault"))
    }

    func testAPlainBroadSummaryNeverWidens() {
        let gate = policy(currentSourceCount: 1, question: "summarize this file")
        XCTAssertFalse(gate.allowsExternalRetrieval)
    }

    func testComparingTwoAttachmentsNeverWidens() {
        let gate = policy(currentSourceCount: 2, question: "compare these two documents")
        XCTAssertFalse(gate.allowsExternalRetrieval)
    }

    func testExplicitExternalWordingWidens() {
        let gate = policy(question: "search the web for this number")
        XCTAssertTrue(gate.allowsExternalRetrieval)
    }

    func testBroaderToggleWidensEvenWithAnAttachment() {
        let gate = policy(currentSourceCount: 1, override: .broader)
        XCTAssertTrue(gate.allowsExternalRetrieval)
        XCTAssertTrue(gate.allowsTool(named: "search_vault"))
    }

    func testSourceOnlyOverrideRefusesExternalEvenWithExternalWording() {
        let decision = ContextPolicy.standard.resolve(ContextRequest(
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 2,
            historyHasSources: true,
            question: "search the web for this",
            override: .sourceOnly
        ))
        let gate = ChatToolPolicy(decision: decision)
        XCTAssertFalse(gate.allowsExternalRetrieval)
        XCTAssertFalse(gate.allowsTool(named: "search_vault"))
    }

    func testTheDecisionRationaleIsCarriedForTheLog() {
        XCTAssertFalse(policy(currentSourceCount: 1).rationale.isEmpty)
    }

    func testSourceFirstAllowsScreenToolsOnlyForAScreenQuestion() {
        // A document question keeps the display closed and the vault closed.
        let docQuestion = policy(currentSourceCount: 1, question: "what does this file say?")
        XCTAssertFalse(docQuestion.allowsTool(named: "capture_screen"))
        XCTAssertFalse(docQuestion.allowsTool(named: "highlight_screen_text"))
        XCTAssertFalse(docQuestion.allowsTool(named: "read_document"))

        // Only the user's own wording about the screen opens the screen tools,
        // and it still does not open the vault.
        let screenDecision = ContextPolicy.standard.resolve(ChatContextRequestBuilder.request(
            question: "what's on my screen?",
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            broaderToggleOn: false
        ))
        let screenQuestion = ChatToolPolicy(
            decision: screenDecision,
            allowsScreenTools: ChatToolPolicy.questionRequestsScreen("what's on my screen?")
        )
        XCTAssertTrue(screenQuestion.allowsTool(named: "capture_screen"))
        XCTAssertTrue(screenQuestion.allowsTool(named: "highlight_screen_text"))
        XCTAssertFalse(screenQuestion.allowsTool(named: "read_document"), "a screen question does not open the vault")
        XCTAssertFalse(screenQuestion.allowsExternalRetrieval)
    }

    func testScreenIntentIsNarrowAndExplicit() {
        XCTAssertTrue(ChatToolPolicy.questionRequestsScreen("what's on my screen?"))
        XCTAssertTrue(ChatToolPolicy.questionRequestsScreen("look at the display and tell me"))
        XCTAssertTrue(ChatToolPolicy.questionRequestsScreen("看一下屏幕"))
        XCTAssertFalse(ChatToolPolicy.questionRequestsScreen("what does this report say?"))
        XCTAssertFalse(ChatToolPolicy.questionRequestsScreen("summarize this file"))
        XCTAssertFalse(ChatToolPolicy.questionRequestsScreen("screening criteria for the study"))
    }

    func testHistoryIsOfferedOnlyWhenThePolicyOffersIt() {
        let withHistory = policy(currentSourceCount: 1, historyTurnCount: 4)
        XCTAssertTrue(withHistory.offersHistory, "the shared policy offers earlier turns as a widening")

        let withoutHistory = policy(currentSourceCount: 1)
        XCTAssertFalse(withoutHistory.offersHistory, "nothing to offer when there are no earlier turns")
    }

    // MARK: The execution gate

    private func tool(named name: String) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: name,
            parameters: [:],
            execute: { _ in "ran \(name)" },
            runningStatus: nil
        )
    }

    private func call(_ name: String) -> LLMToolCall {
        LLMToolCall(id: "1", type: "function", function: .init(name: name, arguments: "{}"))
    }

    @MainActor
    func testTheExecutorRefusesAWithheldExternalTool() async {
        var executor = ToolExecutor(
            tools: [tool(named: "search_vault")],
            allowsExternalRetrieval: false
        )
        let result = await executor.execute(call("search_vault"))
        XCTAssertFalse(result.executed, "a withheld tool must not run")
        XCTAssertFalse(result.resultText.contains("ran search_vault"))
        XCTAssertTrue(result.resultText.contains("not available for this turn"))
    }

    @MainActor
    func testTheExecutorRunsTheSameToolWhenExternalRetrievalIsAllowed() async {
        var executor = ToolExecutor(
            tools: [tool(named: "search_vault")],
            allowsExternalRetrieval: true
        )
        let result = await executor.execute(call("search_vault"))
        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.resultText, "ran search_vault")
    }

    @MainActor
    func testTheExecutorRefusesReadDocumentWhenWithheld() async {
        var executor = ToolExecutor(
            tools: [tool(named: "read_document")],
            allowsExternalRetrieval: false
        )
        let result = await executor.execute(call("read_document"))
        XCTAssertFalse(result.executed, "a withheld vault read must not run")
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertFalse(result.resultText.contains("ran read_document"))
    }

    @MainActor
    func testTheExecutorRefusesAScreenToolWithoutScreenIntent() async {
        // Source-first, document question: the screen tool is refused.
        var docExecutor = ToolExecutor(
            tools: [tool(named: "capture_screen")],
            allowsExternalRetrieval: false,
            allowsScreenTools: false
        )
        let refused = await docExecutor.execute(call("capture_screen"))
        XCTAssertFalse(refused.executed)
        XCTAssertEqual(refused.outcome, .refused)

        // Source-first, screen question: the same tool runs.
        var screenExecutor = ToolExecutor(
            tools: [tool(named: "capture_screen")],
            allowsExternalRetrieval: false,
            allowsScreenTools: true
        )
        let allowed = await screenExecutor.execute(call("capture_screen"))
        XCTAssertTrue(allowed.executed)
        XCTAssertEqual(allowed.outcome, .succeeded)
    }

    @MainActor
    func testTheExecutorAlwaysRunsANonExternalTool() async {
        var executor = ToolExecutor(
            tools: [tool(named: "write_note")],
            allowsExternalRetrieval: false
        )
        let result = await executor.execute(call("write_note"))
        XCTAssertTrue(result.executed, "a tool that stays inside the conversation is never withheld")
        XCTAssertEqual(result.outcome, .succeeded)
    }
}
