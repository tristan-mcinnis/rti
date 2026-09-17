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

    // MARK: - Normalized status

    func testHybridAnswerWithRowsIsAvailable() {
        let decision = VaultRetrieval.answered(
            [result("projects/acme/00-status.md")],
            scopeRelativePath: "projects/acme",
            projectScoped: false
        )

        XCTAssertEqual(decision.adapter, .hybrid)
        XCTAssertEqual(decision.status, .available)
        XCTAssertNil(decision.fallbackReason)
        XCTAssertTrue(decision.inScope)
    }

    func testHybridAnswerWithNoUsableRowsIsAnHonestNoMatch() {
        let decision = VaultRetrieval.answered([], scopeRelativePath: nil, projectScoped: false)

        XCTAssertEqual(decision.adapter, .hybrid)
        XCTAssertEqual(decision.status, .noMatch)
        XCTAssertEqual(decision.results, [])
        XCTAssertNil(decision.fallbackReason)
    }

    func testAServerSideProjectAnswerKeepsAMeetingRowInScope() {
        // The CLI filtered by project, so a meeting note that lives outside the
        // project directory still belongs to the scoped answer.
        let decision = VaultRetrieval.answered(
            [result("meetings/2026-07-03-status.md")],
            scopeRelativePath: "projects/acme-tennis",
            projectScoped: true
        )

        XCTAssertEqual(decision.status, .available)
        XCTAssertTrue(decision.inScope)
        XCTAssertEqual(decision.results.map(\.relativePath), ["meetings/2026-07-03-status.md"])
    }

    func testUnavailableIndexWithALocalVaultIsDegradedAndNamesTheReason() {
        let decision = VaultRetrieval.fallback(
            reason: "bun is not on PATH",
            local: (results: [result("projects/acme/00-status.md")], inScope: true, vaultReachable: true)
        )

        XCTAssertEqual(decision.adapter, .local)
        XCTAssertEqual(decision.status, .degraded(reason: "bun is not on PATH"))
        XCTAssertEqual(decision.fallbackReason, "bun is not on PATH")
        XCTAssertEqual(decision.status.reason, "bun is not on PATH")
    }

    func testUnavailableIndexWithNoLocalVaultIsUnavailable() {
        let decision = VaultRetrieval.fallback(
            reason: "the vault-search CLI is missing at <vault>/code/vault-search/src/cli.ts",
            local: (results: [], inScope: false, vaultReachable: false)
        )

        XCTAssertEqual(decision.adapter, .local)
        XCTAssertEqual(
            decision.status,
            .unavailable(reason: "the vault-search CLI is missing at <vault>/code/vault-search/src/cli.ts")
        )
        XCTAssertEqual(decision.results, [])
    }

    func testUnavailableRetrievalIsNeverReportedAsAnEmptyVault() {
        let response = VaultRetrieval.localResponse(
            query: "store format",
            scopeRelativePath: nil,
            results: [],
            inScope: false,
            status: .unavailable(reason: "the vault-search CLI is missing"),
            fallbackReason: "the vault-search CLI is missing"
        )

        XCTAssertTrue(response.formattedResults.contains("Vault search could not run"))
        XCTAssertFalse(
            response.formattedResults.contains("No vault documents matched"),
            "a retrieval failure is not a statement about the vault"
        )
        XCTAssertTrue(response.modelContextForQuestion.contains("do not say the vault has nothing on this"))
    }

    func testDegradedZeroResultSaysTheIndexDidNotAnswer() {
        let response = VaultRetrieval.localResponse(
            query: "known client fact",
            scopeRelativePath: nil,
            results: [],
            inScope: false,
            zeroResultPolicy: .hard,
            status: .degraded(reason: "bun is not on PATH")
        )

        XCTAssertTrue(response.modelContextForQuestion.contains("The semantic vault index did not answer"))
        XCTAssertTrue(response.modelContextForQuestion.contains("bun is not on PATH"))
        XCTAssertTrue(response.modelContextForQuestion.contains("do not answer from general knowledge or guesswork"))
    }

    func testProjectScopeSlugOnlyForASingleProjectPath() {
        XCTAssertEqual(VaultRetrieval.projectScopeSlug("projects/acme-tennis"), "acme-tennis")
        XCTAssertNil(VaultRetrieval.projectScopeSlug(nil))
        XCTAssertNil(VaultRetrieval.projectScopeSlug("projects/personal/rti"), "a nested scope has no single slug")
        XCTAssertNil(VaultRetrieval.projectScopeSlug("clients/foo.md"))
        XCTAssertNil(VaultRetrieval.projectScopeSlug("projects/Acme Tennis"))
    }
}
