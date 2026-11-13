import XCTest
import RTICore

/// Pins the pure heuristic behind the Ask retrieval fix: which zero-result
/// vault searches must be surfaced to the model as a hard "nothing here"
/// (never silently answered from priors) versus a softer note.
final class LLMControllerRetrievalTests: XCTestCase {

    func testGenericQuestionWithoutScopeDoesNotSearchVault() {
        XCTAssertFalse(RetrievalHeuristics.shouldSearchVault(
            query: "What is this about?",
            hasSelectedScope: false,
            workstreamNames: ["Acme Wear"],
            recentQuestions: []
        ))
    }

    func testHistoricalQuestionSearchesVault() {
        XCTAssertTrue(RetrievalHeuristics.shouldSearchVault(
            query: "What did we decide in the previous meeting?",
            hasSelectedScope: false,
            workstreamNames: [],
            recentQuestions: []
        ))
    }

    func testSelectedProjectSearchesVault() {
        XCTAssertTrue(RetrievalHeuristics.shouldSearchVault(
            query: "What is this about?",
            hasSelectedScope: true,
            workstreamNames: [],
            recentQuestions: []
        ))
    }
    func testEverydayWordsDoNotAskForPastWork() {
        XCTAssertFalse(RetrievalHeuristics.asksForPastWork("What type of research fits this client brief for Acme?"))
    }

    func testPastWorkWordsAsk() {
        for question in ["What did we find in the previous round?", "Look up the Acme quote", "search for pricing"] {
            XCTAssertTrue(RetrievalHeuristics.asksForPastWork(question), question)
        }
    }

    /// Three live asks that missed the vault in a judged client readout.
    func testTranscriptsReportsPlacesAndChineseAsk() {
        for question in ["but what about the fixture transcripts", "summarize the Lisbon report",
                         "what do they say in chengdu about this", "what did they say about price",
                         "How did it land in Osaka?", "他们怎么说包装的？", "上次访谈的结论是什么",
                         "what do people mean by \"不会出错\""] {
            XCTAssertTrue(RetrievalHeuristics.asksForPastWork(question), question)
        }
        for question in ["Say this in Mandarin please", "Give me scoping questions", "What should I ask next?",
                         "Draft a reply in English"] {
            XCTAssertFalse(RetrievalHeuristics.asksForPastWork(question), question)
        }
    }

    func testLiveCallWithholdsVaultToolsUnlessAsked() {
        let open = ChatToolPolicy(allowsExternalRetrieval: true)

        let plain = open.forLiveCall(question: "Give me scoping questions", callType: .client)
        XCTAssertFalse(plain.allowsTool(named: "search_vault"))
        XCTAssertFalse(plain.allowsTool(named: "capture_screen"))

        let onScreen = open.forLiveCall(question: "What is on my screen?", callType: .client)
        XCTAssertFalse(onScreen.allowsTool(named: "grep_vault"))
        XCTAssertTrue(onScreen.allowsTool(named: "capture_screen"))

        XCTAssertTrue(open.forLiveCall(question: "Search for the last quote", callType: .client).allowsTool(named: "search_vault"))
    }

    func testNamesKnownWorkstreamForcesHard() {
        XCTAssertTrue(RetrievalHeuristics.shouldForceVaultSearch(
            query: "what did we decide about AcmeWear Northport vs Southvale",
            workstreamNames: ["Acme Wear", "Globex Retail"],
            recentQuestions: []
        ))
    }

    func testRepeatsRecentQuestionForcesHard() {
        XCTAssertTrue(RetrievalHeuristics.shouldForceVaultSearch(
            query: "What's the store staff ratio?",
            workstreamNames: [],
            recentQuestions: ["what's the store staff ratio?"]
        ))
    }

    func testUnrelatedFirstAskDoesNotForceHard() {
        XCTAssertFalse(RetrievalHeuristics.shouldForceVaultSearch(
            query: "what's the weather like",
            workstreamNames: ["Acme Wear", "Globex Retail"],
            recentQuestions: ["something else entirely"]
        ))
    }

    func testEmptyQueryNeverForcesHard() {
        XCTAssertFalse(RetrievalHeuristics.shouldForceVaultSearch(
            query: "   ",
            workstreamNames: ["Acme Wear"],
            recentQuestions: ["   "]
        ))
    }

    func testRepeatMatchIsCaseAndPunctuationInsensitive() {
        XCTAssertTrue(RetrievalHeuristics.shouldForceVaultSearch(
            query: "What's the STORE staff ratio",
            workstreamNames: [],
            recentQuestions: ["what's the store staff ratio?"]
        ))
    }
}
