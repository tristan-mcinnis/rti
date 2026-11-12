import XCTest
import RTICore

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

    func testWordInsideAnotherWordDoesNotMatch() {
        let score = VaultSearch.rank(
            terms: ["mira"], title: "Regional note", relativePath: "meetings/m.md",
            content: "The Almira store opened."
        ).score
        XCTAssertEqual(score, 0)
    }

    func testShortTermNeedsTheWholeWord() {
        let score = VaultSearch.rank(
            terms: ["ai"], title: "Note", relativePath: "meetings/m.md",
            content: "We aim to finish soon."
        ).score
        XCTAssertEqual(score, 0)
    }

    func testPluralQueryFindsSingularWord() {
        let score = VaultSearch.rank(
            terms: ["consumers"], title: "Note", relativePath: "meetings/m.md",
            content: "One consumer said it was fine."
        ).score
        XCTAssertGreaterThan(score, 0)
    }

    func testChineseTermMatchesInsideARun() {
        let score = VaultSearch.rank(
            terms: VaultSearch.tokenize("门店"), title: "Note", relativePath: "meetings/m.md",
            content: "这个门店很好"
        ).score
        XCTAssertGreaterThan(score, 0)
    }

    func testDocumentMatchingFewQueryWordsIsDropped() {
        let terms = VaultSearch.tokenize("Mira legend athlete running brand strategy")
        let offTopic = VaultSearch.rank(
            terms: terms, title: "Quote bank", relativePath: "work/Acme/2026/acme-running/quotes.md",
            content: "Notes on running brand strategy from one group."
        ).score
        let onTopic = VaultSearch.rank(
            terms: terms, title: "Positioning", relativePath: "meetings/brief.md",
            content: "Mira is a legend athlete in running."
        ).score
        XCTAssertEqual(offTopic, 0)
        XCTAssertGreaterThan(onTopic, 0)
    }

    func testProjectFolderNameRaisesAMatchButNeverMakesOne() {
        let inNamedFolder = VaultSearch.rank(
            terms: ["running", "pricing"], title: "Note", relativePath: "work/acme-running/n.md",
            content: "pricing and running"
        ).score
        let elsewhere = VaultSearch.rank(
            terms: ["running", "pricing"], title: "Note", relativePath: "work/other/n.md",
            content: "pricing and running"
        ).score
        let folderOnly = VaultSearch.rank(
            terms: ["running"], title: "Note", relativePath: "work/acme-running/n.md",
            content: "nothing relevant"
        ).score
        XCTAssertGreaterThan(inNamedFolder, elsewhere)
        XCTAssertEqual(folderOnly, 0)
    }
}

/// A scoped search with `broaden: false` (Auto's search) never widens to the
/// whole vault. The default still does, so `search_vault` is unchanged.
final class VaultSearchScopeTests: XCTestCase {
    private var tmp: URL!
    private var previousConfigHome: String?

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-vault-scope-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let kb = tmp.appendingPathComponent("kb", isDirectory: true)
        try write("# Acme status\nNothing about the topic.", to: kb.appendingPathComponent("projects/acme/00-status.md"))
        try write("# Lantern pricing\nLantern pricing packaging decision for the battery.",
                  to: kb.appendingPathComponent("projects/other/notes.md"))
        let home = tmp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "recordings_dir": kb.appendingPathComponent("meetings/recordings").path,
            "project_roots": [String](),
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent("config.json"))
        previousConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        setenv("RTI_CONFIG_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousConfigHome {
            setenv("RTI_CONFIG_HOME", previousConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let query = "lantern pricing packaging battery"

    func testDefaultStillBroadensToTheWholeVault() async {
        let found = await VaultSearch.retrieve(query: query, scopeRelativePath: "projects/acme")
        XCTAssertEqual(found.results.map(\.relativePath), ["projects/other/notes.md"])
        XCTAssertFalse(found.scopedHit)
    }

    func testBroadenFalseNeverLeavesTheScope() async {
        let found = await VaultSearch.retrieve(query: query, scopeRelativePath: "projects/acme", broaden: false)
        XCTAssertTrue(found.results.isEmpty, "\(found.results.map(\.relativePath))")
    }

    func testBroadenFalseWithAMissingScopeFindsNothing() async {
        let found = await VaultSearch.retrieve(query: query, scopeRelativePath: "projects/gone", broaden: false)
        XCTAssertTrue(found.results.isEmpty, "a missing scope must not fall back to the vault root")
        XCTAssertFalse(VaultSearch.search(query: query, scopeRelativePath: "projects/gone").isEmpty,
                       "the default keeps the old root fallback")
    }

    func testBroadenFalseStillFindsInScope() async {
        let found = await VaultSearch.retrieve(query: query, scopeRelativePath: "projects/other", broaden: false)
        XCTAssertEqual(found.results.map(\.relativePath), ["projects/other/notes.md"])
        XCTAssertTrue(found.scopedHit)
    }
}
