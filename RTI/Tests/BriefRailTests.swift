import RTICore
import XCTest

/// Pins the Meeting Brief rail: Today, then Upcoming (nearest first), then
/// Earlier (newest first), or one Results list while a search is typed.
final class BriefRailTests: XCTestCase {
    private let today = "2026-09-12"
    private let items = [
        BriefRail.Item(id: "a", title: "Northwind Onboarding", day: "2026-09-12"),
        BriefRail.Item(id: "b", title: "Fabrikam Loyalty", day: "2026-09-15"),
        BriefRail.Item(id: "c", title: "Contoso Retail", day: "2026-09-13"),
        BriefRail.Item(id: "d", title: "Pricing Review", day: "2026-09-10"),
        BriefRail.Item(id: "e", title: "Quarterly Planning", day: "2026-08-30"),
        BriefRail.Item(id: "f", title: "Undated notes", day: nil),
    ]

    func test_sections_groupByDay() {
        let sections = BriefRail.sections(for: items, query: "", today: today)
        XCTAssertEqual(sections.map(\.title), ["Today", "Upcoming", "Earlier"])
        XCTAssertEqual(sections[0].items.map(\.id), ["a"])
        XCTAssertEqual(sections[1].items.map(\.id), ["c", "b"])
        XCTAssertEqual(sections[2].items.map(\.id), ["d", "e", "f"])
        XCTAssertEqual(BriefRail.flattened(sections).map(\.id), ["a", "c", "b", "d", "e", "f"])
    }

    func test_emptySectionsAreLeftOut() {
        let past = items.filter { ($0.day ?? "") < today }
        XCTAssertEqual(BriefRail.sections(for: past, query: "", today: today).map(\.title), ["Earlier"])
        XCTAssertEqual(BriefRail.sections(for: [], query: "", today: today), [])
    }

    func test_query_givesOneResultsSectionNewestFirst() {
        let sections = BriefRail.sections(for: items, query: "re", today: today)
        XCTAssertEqual(sections.map(\.title), ["Results"])
        XCTAssertEqual(sections[0].items.map(\.id), ["c", "d"])
    }

    func test_query_matchesEveryWordAndTheDay() {
        XCTAssertEqual(BriefRail.sections(for: items, query: "north onb", today: today).first?.items.map(\.id), ["a"])
        XCTAssertEqual(BriefRail.sections(for: items, query: "2026 09 15", today: today).first?.items.map(\.id), ["b"])
        XCTAssertEqual(BriefRail.sections(for: items, query: "nothing here", today: today), [])
    }
}
