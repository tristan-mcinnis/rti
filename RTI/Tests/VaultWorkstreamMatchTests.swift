import XCTest

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
}
