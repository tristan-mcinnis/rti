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
        XCTAssertEqual(VaultSearch.tokenize("AcmeBrand 门店"), ["acmebrand", "门店"])
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
            terms: ["acmebrand"], title: "AcmeBrand status", relativePath: "projects/n/notes.md",
            content: "a body that does not mention the brand").score
        let bodyHit = VaultSearch.rank(
            terms: ["acmebrand"], title: "Generic note", relativePath: "meetings/m.md",
            content: "acmebrand came up once").score
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
}
