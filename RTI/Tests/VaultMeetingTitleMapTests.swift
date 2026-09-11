import RTICore
import XCTest

/// The in-memory map from an RTI session stamp to the vault meeting note
/// that names it. Reads frontmatter only; everything here is invented.
final class VaultMeetingTitleMapTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-title-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testBuildMapsSourceStampToTitle() throws {
        try write("20260904-briefing-project-zeta-scope.md", """
        ---
        title: "Project Zeta, proposal scoping call"
        date: 2026-09-04
        type: meeting
        source: rti-session-20260904-150016
        ---
        # Project Zeta

        Body text that mentions source: rti-session-20990101-000000 later.
        """)
        try write("20260903-weekly.md", """
        ---
        title: Weekly status
        source: calendar
        ---
        """)
        try write("notes.txt", "---\ntitle: Not markdown\nsource: rti-session-20260901-100000\n---\n")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("recordings"), withIntermediateDirectories: true)

        let map = VaultMeetingTitleMap.build(meetingsDirectory: directory)
        XCTAssertEqual(map.entries.count, 1)
        XCTAssertEqual(map.title(forStamp: "20260904-150016"), "Project Zeta, proposal scoping call")
        XCTAssertEqual(map.stamp(forNoteFileName: "20260904-briefing-project-zeta-scope.md"), "20260904-150016")
        XCTAssertNil(map.title(forStamp: "20990101-000000"), "only the frontmatter counts")
        XCTAssertNil(map.title(forStamp: "20260901-100000"), "only .md notes count")
    }

    func testFirstNoteByNameWinsForADuplicateStamp() throws {
        try write("b-second.md", "---\ntitle: Second\nsource: rti-session-20260904-150016\n---\n")
        try write("a-first.md", "---\ntitle: First\nsource: rti-session-20260904-150016\n---\n")
        let map = VaultMeetingTitleMap.build(meetingsDirectory: directory)
        XCTAssertEqual(map.title(forStamp: "20260904-150016"), "First")
    }

    func testMissingFolderGivesEmptyMap() {
        let map = VaultMeetingTitleMap.build(meetingsDirectory: directory.appendingPathComponent("absent"))
        XCTAssertTrue(map.isEmpty)
    }

    func testFrontmatterForms() {
        let scalar = VaultMeetingTitleMap.parseFrontmatter("---\ntitle: 'It''s the pilot'\nsource: rti-session-20260615-133744\n---\n")
        XCTAssertEqual(scalar.title, "It's the pilot")
        XCTAssertEqual(scalar.sessionStamp, "20260615-133744")

        let inline = VaultMeetingTitleMap.parseFrontmatter("---\ntitle: \"Say \\\"hi\\\"\"\nsource: [rti, rti-session-20260615-133744]\n---\n")
        XCTAssertEqual(inline.title, "Say \"hi\"")
        XCTAssertEqual(inline.sessionStamp, "20260615-133744")

        let block = VaultMeetingTitleMap.parseFrontmatter("---\ntitle: Block\nsources:\n  - rti\n  - rti-session-20260615-133744\ntags:\n  - x\n---\n")
        XCTAssertEqual(block.sessionStamp, "20260615-133744")

        let none = VaultMeetingTitleMap.parseFrontmatter("# No frontmatter\nsource: rti-session-20260615-133744\n")
        XCTAssertNil(none.title)
        XCTAssertNil(none.sessionStamp)
    }

    func testFrontmatterPastTheLineLimitIsIgnored() {
        let padding = Array(repeating: "tag: x", count: VaultMeetingTitleMap.headerLineLimit).joined(separator: "\n")
        let text = "---\ntitle: Late\n\(padding)\nsource: rti-session-20260615-133744\n---\n"
        XCTAssertNil(VaultMeetingTitleMap.parseFrontmatter(text).sessionStamp)
    }

    func testCanonicalStampFromFolderName() {
        XCTAssertEqual(VaultMeetingTitleMap.canonicalStamp(fromFolderName: "2026-09-04 150016"), "20260904-150016")
        XCTAssertNil(VaultMeetingTitleMap.canonicalStamp(fromFolderName: "2026-09-04"))
        XCTAssertNil(VaultMeetingTitleMap.canonicalStamp(fromFolderName: "notes"))
    }
}
