import XCTest

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
