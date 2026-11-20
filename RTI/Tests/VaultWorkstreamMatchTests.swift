import XCTest
import RTICore

/// Pins the conservative meeting-name → vault-workstream matcher that
/// pre-selects the Context tab from a matched meeting name.
/// The guarantees that matter: whole-word matches only (no substring
/// false-positives), projects beat clients, longest name wins, and short
/// slugs never auto-match.
final class VaultWorkstreamMatchTests: XCTestCase {
    private func item(_ name: String, project: Bool) -> VaultItem {
        VaultItem(id: name, name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), isProject: project)
    }

    func testMatchesWholeWorkstreamName() {
        let items = [item("Acme Digital", project: true), item("Apple", project: false)]
        XCTAssertEqual(
            VaultWorkstreamStore.match(meetingName: "2026-06-08 Acme Digital sync", in: items)?.name,
            "Acme Digital"
        )
    }

    func testHyphenatedSlugMatchesSpacedTitle() {
        let items = [item("Acme Digital", project: true)]
        XCTAssertEqual(
            VaultWorkstreamStore.match(meetingName: "acme-digital weekly", in: items)?.name,
            "Acme Digital"
        )
    }

    func testNoSubstringFalsePositive() {
        let items = [item("Apple", project: false)]
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "pineapple tasting", in: items))
    }

    func testPrefersProjectOverClient() {
        let items = [item("Acme", project: false), item("Acme", project: true)]
        XCTAssertEqual(VaultWorkstreamStore.match(meetingName: "Acme review", in: items)?.isProject, true)
    }

    func testPrefersLongestMatch() {
        let items = [item("Acme", project: true), item("Acme Digital", project: true)]
        XCTAssertEqual(
            VaultWorkstreamStore.match(meetingName: "Acme Digital chat", in: items)?.name,
            "Acme Digital"
        )
    }

    func testShortNamesDoNotMatch() {
        let items = [item("AXA", project: false)] // 3 chars — below the 4-char floor
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "AXA standup", in: items))
    }

    func testNoMatchReturnsNil() {
        let items = [item("Acme Digital", project: true)]
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "Weekly standup", in: items))
    }

    /// 2026-11-20: real event titles that linked no project.
    func testDistinctiveWordsMatchAProject() {
        let items = [
            item("Acme · acme-lumo-china-agency-research", project: true),
            item("Acme · acme-prestige-neasia", project: true),
            item("Northwind · northwind-global-youth", project: true),
            item("Northwind · northwind-bo-an", project: true),
            item("Northwind · northwind-running-retail-concept", project: true),
        ]
        XCTAssertEqual(VaultWorkstreamStore.match(meetingName: "Lumo Focus Group follow up discussion", in: items)?.name,
                       "Acme · acme-lumo-china-agency-research")
        XCTAssertEqual(VaultWorkstreamStore.match(meetingName: "Lumo China Diagnosis - Catch up with Mira", in: items)?.name,
                       "Acme · acme-lumo-china-agency-research")
        XCTAssertEqual(VaultWorkstreamStore.match(meetingName: "Northwind x Studio: global youth research", in: items)?.name,
                       "Northwind · northwind-global-youth")
        XCTAssertEqual(VaultWorkstreamStore.match(meetingName: "Northwind Bo An: Follow-up interview (Online)", in: items)?.name,
                       "Northwind · northwind-bo-an")
    }

    func testClientOrCommonWordsAloneMatchNothing() {
        let items = [item("Northwind · northwind-global-youth", project: true), item("Northwind · northwind-running-retail-concept", project: true)]
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "Northwind China research sync", in: items))
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "Director's Meeting", in: items))
    }

    func testATieMatchesNothing() {
        let items = [item("Acme · acme-lumo-pack", project: true), item("Acme · acme-lumo-price", project: true)]
        XCTAssertNil(VaultWorkstreamStore.match(meetingName: "Lumo debrief", in: items))
    }
}
