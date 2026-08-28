import XCTest

/// Integration test for the Neon-backed vault search. Actually shells out to
/// the hermes CLI and hits the live hybrid index, so it verifies the whole
/// Swift→bun→Neon path (process spawn, path resolution, JSON parse, the
/// `vault/memory/` privacy filter). Skips cleanly when the environment isn't
/// wired (CI / offline / no bun), so it never produces a false failure.
final class VaultSearchCLITests: XCTestCase {

    func testHybridSearchReturnsKnowledgeBaseHits() async throws {
        guard let results = await VaultSearchCLI.search(query: "AcmeBrand report format", limit: 5) else {
            throw XCTSkip("hermes CLI / Neon not reachable here — falling back to grep at runtime")
        }
        XCTAssertFalse(results.isEmpty, "hybrid search should return at least one hit for a known project")
        // The privacy boundary: session logs + verbatim transcripts under
        // vault/memory/ must never surface in a meeting tool.
        XCTAssertFalse(
            results.contains { $0.relativePath.hasPrefix("memory/") || $0.relativePath.contains("vault/memory/") },
            "vault/memory/ content must be filtered out"
        )
        // Every hit should carry a human-readable title and a path.
        for r in results {
            XCTAssertFalse(r.title.isEmpty)
            XCTAssertFalse(r.relativePath.isEmpty)
        }
    }
}
