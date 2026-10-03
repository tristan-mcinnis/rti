import XCTest

/// Pins the pure scoring + tokenisation behind the `search_vault` LLM tool.
/// The filesystem scan is exercised against the real vault elsewhere; here we
/// lock the parts that decide *relevance*: how a query splits into tokens
/// (incl. bilingual CJK) and how a document scores.
final class VaultSearchTests: XCTestCase {

    // MARK: tokenize

    func testLatinWordsLowercasedAndDeduped() {
        XCTAssertEqual(VaultSearch.tokenize("Store STORE format"), ["store", "format"])
    }

    func testShortLatinTokensDropped() {
        // "a" and "x" are below the length-2 floor; "to" survives length but...
        XCTAssertEqual(VaultSearch.tokenize("a store x"), ["store"])
    }

    func testStopwordsRemoved() {
        XCTAssertEqual(VaultSearch.tokenize("what did we decide about store"), ["decide", "store"])
    }

    func testCJKBecomesOverlappingBigrams() {
        XCTAssertEqual(VaultSearch.tokenize("什么时候"), ["什么", "么时", "时候"])
    }

    func testLoneCJKCharSurvives() {
        XCTAssertEqual(VaultSearch.tokenize("买 store"), ["买", "store"])
    }

    func testMixedLatinAndCJK() {
        XCTAssertEqual(VaultSearch.tokenize("AcmeWear 门店"), ["acmewear", "门店"])
    }

    // MARK: rank

    func testNoMatchScoresZero() {
        let (score, excerpt) = VaultSearch.rank(
            terms: ["unrelated"], title: "Status", relativePath: "projects/x/00-status.md",
            content: "nothing relevant here at all")
        XCTAssertEqual(score, 0)
        XCTAssertEqual(excerpt, "")
    }

    func testTitleMatchOutweighsBodyMention() {
        let titleHit = VaultSearch.rank(
            terms: ["acmewear"], title: "AcmeWear status", relativePath: "projects/n/notes.md",
            content: "a body that does not mention the brand").score
        let bodyHit = VaultSearch.rank(
            terms: ["acmewear"], title: "Generic note", relativePath: "meetings/m.md",
            content: "acmewear came up once").score
        XCTAssertGreaterThan(titleHit, bodyHit)
    }

    func testStatusFileGetsRecencyNudge() {
        let status = VaultSearch.rank(
            terms: ["store"], title: "Status", relativePath: "projects/n/00-status.md",
            content: "store store").score
        let plain = VaultSearch.rank(
            terms: ["store"], title: "Status", relativePath: "meetings/n.md",
            content: "store store").score
        XCTAssertGreaterThan(status, plain)
    }

    func testExcerptPicksTheDensestLine() {
        let (_, excerpt) = VaultSearch.rank(
            terms: ["store", "format"], title: "T", relativePath: "meetings/m.md",
            content: """
            An opening paragraph with little relevance to anything.
            The group split on preferred store format options today.
            A trailing line about logistics.
            """)
        XCTAssertTrue(excerpt.contains("store format"))
    }

    func testDailyDriverAcmeProjectQuestionPrefersProjectStatus() {
        let terms = VaultSearch.tokenize("tell me about the Acme projects I have done this year")
        let acmeStatus = VaultSearch.rank(
            terms: terms,
            title: "AcmeWear status",
            relativePath: "projects/acmewear/00-status.md",
            content: "AcmeWear project status for this year covering fieldwork, mass consumers, and retail concept decisions."
        ).score
        let genericMeeting = VaultSearch.rank(
            terms: terms,
            title: "Generic client meeting",
            relativePath: "meetings/2026-06-01-client.md",
            content: "We mentioned Acme once in a broader conversation."
        ).score

        XCTAssertGreaterThan(acmeStatus, genericMeeting)
    }

    func testDailyDriverAcmeWearCityComparisonFindsComparisonEvidence() {
        let terms = VaultSearch.tokenize("difference between mass consumers in Northport and Southvale for AcmeWear")
        let cityEvidence = VaultSearch.rank(
            terms: terms,
            title: "AcmeWear City Differences",
            relativePath: "projects/acmewear/analysis/36-evidence-deck.md",
            content: """
            Northport mass consumers showed higher awareness of the range and more openness to new formats.
            Southvale mass consumers were more practical, wanting localisation, staff guidance, and visible Acme product proof.
            """
        ).score
        let offTopicAcme = VaultSearch.rank(
            terms: terms,
            title: "Acme store logistics",
            relativePath: "projects/acme-running/00-status.md",
            content: "Acme store logistics and project timing."
        ).score

        XCTAssertGreaterThan(cityEvidence, offTopicAcme)
    }

    // MARK: project scoping

    private func result(_ path: String) -> VaultSearch.Result {
        VaultSearch.Result(title: path, relativePath: path, modified: .distantPast, excerpt: "", score: 1)
    }

    func testScopeKeepsOnlyInProjectResults() {
        let results = [
            result("projects/acme-running/transcripts/consumer/group-1.md"),
            result("projects/other/00-status.md"),
            result("meetings/20260601-x.md"),
        ]
        let scoped = VaultSearch.applyScope(results, scope: "projects/acme-running")
        XCTAssertTrue(scoped.inScope)
        XCTAssertEqual(scoped.results.count, 1)
        XCTAssertEqual(scoped.results.first?.relativePath, "projects/acme-running/transcripts/consumer/group-1.md")
    }

    func testScopeBroadensWhenNoInProjectMatch() {
        let results = [result("projects/other/00-status.md"), result("meetings/20260601-x.md")]
        let scoped = VaultSearch.applyScope(results, scope: "projects/acme-running")
        XCTAssertFalse(scoped.inScope) // fell back to whole-vault results
        XCTAssertEqual(scoped.results.count, 2)
    }

    func testNoScopeReturnsAllUnflagged() {
        let scoped = VaultSearch.applyScope([result("meetings/a.md")], scope: nil)
        XCTAssertFalse(scoped.inScope)
        XCTAssertEqual(scoped.results.count, 1)
    }
}
