import RTICore
import XCTest

/// Pins the settings rail's search and the footer's "Next ⌘n" number.
final class SettingsSearchTests: XCTestCase {
    private let panes = [
        SettingsSearch.Pane(id: "providers", title: "Providers", keywords: ["api", "keys", "soniox"]),
        SettingsSearch.Pane(id: "general", title: "General", keywords: ["microphone", "appearance", "hotkeys"]),
        SettingsSearch.Pane(id: "logs", title: "Logs", keywords: ["crash", "diagnostics"]),
    ]

    func test_emptyQuery_keepsEveryPaneInOrder() {
        XCTAssertEqual(SettingsSearch.filter(panes, query: "").map(\.id), ["providers", "general", "logs"])
        XCTAssertEqual(SettingsSearch.filter(panes, query: "   ").map(\.id), ["providers", "general", "logs"])
    }

    func test_titlePrefix_matchesIgnoringCase() {
        XCTAssertEqual(SettingsSearch.filter(panes, query: "gen").map(\.id), ["general"])
        XCTAssertEqual(SettingsSearch.filter(panes, query: "LOGS").map(\.id), ["logs"])
    }

    func test_keyword_findsThePaneThatHoldsTheSetting() {
        XCTAssertEqual(SettingsSearch.filter(panes, query: "micro").map(\.id), ["general"])
        XCTAssertEqual(SettingsSearch.filter(panes, query: "API key").map(\.id), ["providers"])
    }

    func test_everyWordMustMatch_andMidWordTextDoesNot() {
        XCTAssertEqual(SettingsSearch.filter(panes, query: "crash microphone").map(\.id), [])
        XCTAssertEqual(SettingsSearch.filter(panes, query: "eneral").map(\.id), [])
    }

    func test_accentsAreIgnored() {
        XCTAssertEqual(SettingsSearch.filter(panes, query: "Généràl").map(\.id), ["general"])
    }

    func test_nextNumber_wrapsFromLastPaneToFirst() {
        XCTAssertEqual(SettingsSearch.nextNumber(after: 0, count: 8), 2)
        XCTAssertEqual(SettingsSearch.nextNumber(after: 6, count: 8), 8)
        XCTAssertEqual(SettingsSearch.nextNumber(after: 7, count: 8), 1)
        XCTAssertEqual(SettingsSearch.nextNumber(after: 0, count: 0), 1)
    }
}
