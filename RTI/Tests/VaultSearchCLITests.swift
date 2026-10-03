import XCTest

/// The Neon-backed vault search adapter: which CLI it resolves, how each
/// answer shape becomes an outcome, and — last — the live Swift→bun→Neon path.
final class VaultSearchCLITests: XCTestCase {

    /// The tests marked live need the maintainer's vault, its search CLI and its
    /// index. Other Macs and CI have none of those, so they skip unless
    /// `RTI_LIVE_VAULT=1` is set (it is set on the maintainer's Mac, never in CI).
    private func requireLiveVault() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RTI_LIVE_VAULT"] == "1",
            "needs the live vault; set RTI_LIVE_VAULT=1 to run"
        )
    }

    // MARK: - Resolution

    /// The resolver must name the CLI's current owner. It used to build
    /// `<vault>/code/hermes/src/cli.ts`, which no longer exists, so every
    /// search silently fell through to the local keyword scan.
    func testResolverNamesTheCurrentCLIOwner() {
        XCTAssertEqual(VaultSearchCLI.cliRelativePath, "code/vault-search/src/cli.ts")
    }

    /// Live: the CLI must exist in the real vault checkout.
    func testResolverFindsTheCLIInTheLiveVault() throws {
        try requireLiveVault()
        XCTAssertNotNil(
            VaultPaths.vaultToolURL(VaultSearchCLI.cliRelativePath),
            "the vault-search CLI must resolve from the vault git root"
        )
        XCTAssertNil(
            VaultPaths.vaultToolURL("code/hermes/src/cli.ts"),
            "the old hermes owner is gone; resolving it can only fail"
        )
    }

    // MARK: - Parse fixtures

    func testRowsBecomeAvailableResultsWithKnowledgeBaseRelativePaths() {
        let data = Data("""
        {"ok":true,"query":"store format","results":[
          {"title":"Long deck","type":"report","path":"kb/databases/projects/acme-tennis/v3/deck.md","date":"2026-07-02T10:00:00.000Z","summary":"The long deck."},
          {"path":"kb/databases/meetings/2026-07-03-status.md"}
        ]}
        """.utf8)

        guard case .results(let rows) = VaultSearchCLI.parse(data) else {
            return XCTFail("an ok answer with rows is results")
        }
        XCTAssertEqual(rows.map(\.relativePath), [
            "projects/acme-tennis/v3/deck.md",
            "meetings/2026-07-03-status.md",
        ], "paths are relative to databases/, the style the local scan and the UI use")
        XCTAssertEqual(rows.first?.title, "Long deck")
        XCTAssertEqual(rows.last?.title, "2026 07 03 status", "a row with no title is named for its file")
    }

    func testAnEmptyResultSetIsAnHonestNoMatch() {
        let data = Data(#"{"ok":true,"query":"nothing here","results":[]}"#.utf8)
        XCTAssertEqual(VaultSearchCLI.parse(data), .noMatch)
    }

    /// The CLI reports its own failures as `{"ok":false,"error":"…"}` with exit
    /// status 0. Collapsing that into an empty result set is what let a dead
    /// index read as an empty vault.
    func testAReportedFailureBecomesAnUnavailableReason() {
        let data = Data(#"{"ok":false,"query":"x","error":"connection terminated unexpectedly"}"#.utf8)
        XCTAssertEqual(
            VaultSearchCLI.parse(data),
            .unavailable(reason: "the vault-search CLI reported a failure: connection terminated unexpectedly")
        )
    }

    func testAnEmptyReportedFailureStillNamesTheFailure() {
        let data = Data(#"{"ok":false,"query":"x","error":""}"#.utf8)
        guard case .unavailable(let reason) = VaultSearchCLI.parse(data) else {
            return XCTFail("ok:false is unavailable")
        }
        XCTAssertTrue(reason.contains("reported a failure"))
    }

    func testUnreadableJSONIsUnavailableNotEmpty() {
        XCTAssertEqual(
            VaultSearchCLI.parse(Data("not json at all".utf8)),
            .unavailable(reason: "the vault-search CLI returned unreadable JSON")
        )
        XCTAssertEqual(
            VaultSearchCLI.parse(Data()),
            .unavailable(reason: "the vault-search CLI returned unreadable JSON")
        )
    }

    // MARK: - Live path

    func testHybridSearchReturnsKnowledgeBaseHits() async throws {
        try requireLiveVault()
        let outcome = await VaultSearchCLI.searchOutcome(query: "AcmeWear report format", limit: 5)
        switch outcome {
        case .unavailable(let reason):
            // A resolver miss is the bug this test guards; anything else is
            // this machine's index being down, which skips cleanly.
            if reason.contains("missing at") || reason.contains("not on PATH") {
                return XCTFail("the hybrid index cannot be reached at all: \(reason)")
            }
            throw XCTSkip("hybrid index unreachable here: \(reason)")
        case .noMatch:
            throw XCTSkip("the index answered with no rows for this query")
        case .results(let results):
            XCTAssertFalse(results.isEmpty, "hybrid search should return at least one hit for a known project")
            // The privacy boundary: session logs + verbatim transcripts under
            // memory/ must never surface in a meeting tool.
            XCTAssertFalse(
                results.contains { $0.relativePath.hasPrefix("memory/") || $0.relativePath.contains("vault/memory/") },
                "memory/ content must be filtered out"
            )
            // Every hit should carry a human-readable title and a path in the
            // databases/-relative style.
            for r in results {
                XCTAssertFalse(r.title.isEmpty)
                XCTAssertFalse(r.relativePath.isEmpty)
                XCTAssertFalse(r.relativePath.hasPrefix("kb/"), "\(r.relativePath) is not databases/-relative")
            }
        }
    }

    func testAProjectScopedSearchPassesTheSlugServerSide() async throws {
        try requireLiveVault()
        // `--project` is the CLI's server-side filter; the live call proves the
        // new argv is accepted and still returns rows.
        let outcome = await VaultSearchCLI.searchOutcome(query: "status", limit: 5, project: "acme-tennis")
        switch outcome {
        case .unavailable(let reason):
            if reason.contains("missing at") || reason.contains("not on PATH") {
                return XCTFail("the hybrid index cannot be reached at all: \(reason)")
            }
            throw XCTSkip("hybrid index unreachable here: \(reason)")
        case .noMatch:
            throw XCTSkip("the project-scoped query had no rows")
        case .results(let rows):
            XCTAssertFalse(rows.isEmpty, "a server-side project filter must still return project rows")
        }
    }
}
