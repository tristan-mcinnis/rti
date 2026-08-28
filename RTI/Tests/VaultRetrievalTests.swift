import XCTest

final class VaultRetrievalTests: XCTestCase {
    private func result(_ path: String, title: String = "Doc") -> VaultSearch.Result {
        VaultSearch.Result(
            title: title,
            relativePath: path,
            modified: Date(timeIntervalSince1970: 0),
            excerpt: "Useful excerpt",
            score: 10
        )
    }

    func testResponseExposesSourcesWithoutParsingFormattedText() {
        let response = VaultRetrieval.localResponse(
            query: "store format",
            scopeRelativePath: "projects/acme",
            results: [result("projects/acme/00-status.md")],
            inScope: true,
            elapsedMS: 42
        )

        XCTAssertEqual(response.sourcePaths, ["projects/acme/00-status.md"])
        XCTAssertEqual(response.scopeLabel, "Project-scoped")
        XCTAssertEqual(response.trace, "Scoped search · 42ms · 1 source: projects/acme/00-status.md")
        XCTAssertTrue(response.formattedResults.contains("(focused on this meeting's project)"))
    }

    func testQuestionContextWithResultsWrapsFormattedResults() {
        let response = VaultRetrieval.localResponse(
            query: "decision",
            scopeRelativePath: nil,
            results: [result("meetings/a.md", title: "Decision")],
            inScope: false
        )

        XCTAssertTrue(response.modelContextForQuestion.hasPrefix("Vault-wide retrieval for this question:"))
        XCTAssertTrue(response.modelContextForQuestion.contains("meetings/a.md"))
    }

    func testHardZeroResultPolicyTellsModelNotToGuess() {
        let response = VaultRetrieval.localResponse(
            query: "known client fact",
            scopeRelativePath: nil,
            results: [],
            inScope: false,
            zeroResultPolicy: .hard
        )

        XCTAssertTrue(response.modelContextForQuestion.contains("do not answer from general knowledge or guesswork"))
    }

    func testLatestPointZeroResultPolicyUsesLatestPointCopy() {
        let response = VaultRetrieval.localResponse(
            query: "latest transcript",
            scopeRelativePath: "projects/acme",
            results: [],
            inScope: false,
            zeroResultPolicy: .latestPoint
        )

        XCTAssertTrue(response.modelContextForQuestion.contains("latest point"))
        XCTAssertTrue(response.modelContextForQuestion.contains("vault had no hits"))
    }
}
