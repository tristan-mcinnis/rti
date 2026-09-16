import XCTest

@MainActor
final class CommandRegistryTests: XCTestCase {

    private var registry: CommandRegistry!

    override func setUp() async throws {
        try await super.setUp()
        // Tests share UserDefaults with the running test bundle. Clear the
        // recents key per test so behaviour is deterministic.
        UserDefaults.standard.removeObject(forKey: "rti.palette.recents")
        registry = CommandRegistry.shared
        registry.replaceAll([])
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "rti.palette.recents")
        try await super.tearDown()
    }

    private func cmd(
        _ id: String,
        _ title: String,
        keywords: [String] = [],
        available: Bool = true
    ) -> RTICommand {
        RTICommand(
            id: id,
            title: title,
            keywords: keywords,
            isAvailable: { available },
            perform: { }
        )
    }

    // MARK: - search

    func test_search_emptyQuery_returnsAllAvailable() {
        registry.replaceAll([
            cmd("a", "Alpha"),
            cmd("b", "Bravo"),
            cmd("c", "Charlie", available: false)
        ])
        let results = registry.search("")
        XCTAssertEqual(results.map(\.id), ["a", "b"])
    }

    func test_search_matchesByTitleSubstring_caseInsensitive() {
        registry.replaceAll([cmd("a", "Start Session"), cmd("b", "Stop Session")])
        XCTAssertEqual(registry.search("session").map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(registry.search("STOP").map(\.id), ["b"])
    }

    func test_search_matchesByKeyword() {
        registry.replaceAll([cmd("a", "Capture Screen", keywords: ["screenshot"])])
        XCTAssertEqual(registry.search("screenshot").map(\.id), ["a"])
    }

    func test_search_titleMatchOutranksKeywordMatch() {
        registry.replaceAll([
            cmd("kw", "Open Settings", keywords: ["chat"]),
            cmd("title", "Chat Clear")
        ])
        // Both match "chat", but "Chat Clear" matches in the title at
        // position 0; "Open Settings" matches via keyword. Title hit wins.
        XCTAssertEqual(registry.search("chat").map(\.id), ["title", "kw"])
    }

    func test_search_excludesUnavailable() {
        registry.replaceAll([
            cmd("a", "Alpha", available: true),
            cmd("b", "Alpha-2", available: false)
        ])
        XCTAssertEqual(registry.search("alpha").map(\.id), ["a"])
    }

    // MARK: - recents

    func test_search_matchesNoncontiguousLettersAndRanksExactTitlesFirst() {
        registry.replaceAll([
            cmd("long", "Pinned session notes"),
            cmd("pin", "Pin"),
            cmd("attach", "Attach File", keywords: ["document"])
        ])
        XCTAssertEqual(registry.search("PN").first?.id, "pin")
        XCTAssertEqual(registry.search("attfl").map(\.id), ["attach"])
        XCTAssertEqual(registry.search("dcmnt").map(\.id), ["attach"])
    }

    func test_searchUsesTheCurrentContextualTitle() {
        var pinned = false
        registry.replaceAll([RTICommand(
            id: "window.pin", title: "Pin Window", perform: {},
            menuTitleProvider: { pinned ? "Unpin Window" : "Pin Window" }
        )])
        XCTAssertTrue(registry.search("unpin").isEmpty)
        pinned = true
        XCTAssertEqual(registry.search("UNPN").map(\.id), ["window.pin"])
    }

    func test_recordExecution_pushesToFront() {
        registry.replaceAll([cmd("a", "A"), cmd("b", "B"), cmd("c", "C")])
        registry.recordExecution("b")
        registry.recordExecution("c")
        // Empty query orders by recency: most recent first, then unused
        // commands in registration order.
        XCTAssertEqual(registry.search("").map(\.id), ["c", "b", "a"])
    }

    func test_recordExecution_dedupesByID() {
        registry.replaceAll([cmd("a", "A"), cmd("b", "B")])
        registry.recordExecution("a")
        registry.recordExecution("b")
        registry.recordExecution("a")
        // "a" was used twice but appears once, at the front.
        XCTAssertEqual(registry.search("").map(\.id), ["a", "b"])
    }

    func test_recents_capsAtFive() {
        let many = (0..<10).map { cmd("\($0)", "Cmd\($0)") }
        registry.replaceAll(many)
        for i in 0..<10 {
            registry.recordExecution("\(i)")
        }
        // Recents stores up to 5; after 10 executions, the 5 most recent.
        let recents = registry.recents(limit: 5)
        XCTAssertEqual(recents.map(\.id), ["9", "8", "7", "6", "5"])
    }

    func test_recents_filtersByAvailability() {
        registry.replaceAll([
            cmd("a", "A", available: true),
            cmd("b", "B", available: false)
        ])
        registry.recordExecution("a")
        registry.recordExecution("b")
        // "b" is in recents but unavailable — should drop out.
        XCTAssertEqual(registry.recents().map(\.id), ["a"])
    }
}
