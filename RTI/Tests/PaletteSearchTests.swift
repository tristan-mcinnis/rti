import XCTest

@MainActor
final class PaletteSearchTests: XCTestCase {

    private func cmd(_ id: String, _ title: String = "Cmd") -> RTICommand {
        RTICommand(id: id, title: title, perform: {})
    }

    private func makeSession(_ id: String, title: String = "S") -> Session {
        Session(
            id: id,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            wavPath: nil,
            notes: nil,
            title: title,
            modeId: nil,
            calendarEventId: nil,
            calendarTitle: nil,
            transcriptQuality: nil
        )
    }

    private func match(_ id: String, snippet: String = "snip") -> SessionSearchResult {
        SessionSearchResult(id: id, session: makeSession(id), snippet: snippet)
    }

    // MARK: - empty query

    func test_emptyQuery_returnsCommandsOnly() {
        let results = PaletteSearch.compose(
            query: "",
            commands: [cmd("a"), cmd("b")],
            sessions: [match("s1"), match("s2")]
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.isCommand })
    }

    func test_whitespaceOnlyQuery_returnsCommandsOnly() {
        let results = PaletteSearch.compose(
            query: "   ",
            commands: [cmd("a")],
            sessions: [match("s1")]
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isCommand)
    }

    // MARK: - non-empty query

    func test_nonEmptyQuery_putsCommandsBeforeSessions() {
        let results = PaletteSearch.compose(
            query: "find",
            commands: [cmd("c1"), cmd("c2")],
            sessions: [match("s1"), match("s2")]
        )
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results[0].isCommand)
        XCTAssertTrue(results[1].isCommand)
        XCTAssertTrue(results[2].isSession)
        XCTAssertTrue(results[3].isSession)
    }

    func test_nonEmptyQuery_capsSessionsAtLimit() {
        let sessions = (0..<10).map { match("s\($0)") }
        let results = PaletteSearch.compose(
            query: "x",
            commands: [],
            sessions: sessions,
            sessionLimit: 3
        )
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.id), ["sess:s0", "sess:s1", "sess:s2"])
    }

    func test_nonEmptyQuery_zeroLimit_dropsAllSessions() {
        let results = PaletteSearch.compose(
            query: "x",
            commands: [cmd("a")],
            sessions: [match("s1")],
            sessionLimit: 0
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isCommand)
    }

    func test_nonEmptyQuery_negativeLimit_treatedAsZero() {
        let results = PaletteSearch.compose(
            query: "x",
            commands: [],
            sessions: [match("s1"), match("s2")],
            sessionLimit: -5
        )
        XCTAssertTrue(results.isEmpty)
    }

    func test_nonEmptyQuery_emptyResults_isEmpty() {
        let results = PaletteSearch.compose(
            query: "x",
            commands: [],
            sessions: []
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - PaletteResult identity

    func test_resultIds_areNamespacedToAvoidCollisions() {
        // A command with id "x" and a session with id "x" must produce
        // different palette ids so SwiftUI's ForEach doesn't collapse them.
        let results = PaletteSearch.compose(
            query: "x",
            commands: [cmd("x")],
            sessions: [match("x")]
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(results[0].id, results[1].id)
        XCTAssertEqual(results[0].id, "cmd:x")
        XCTAssertEqual(results[1].id, "sess:x")
    }
}
