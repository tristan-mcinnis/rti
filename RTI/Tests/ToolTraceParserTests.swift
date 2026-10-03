import RTICore
import XCTest

/// Pins how tool results and search traces become the thread's tool lines
/// and sources. The inputs are the exact shapes RTI's tools return
/// (`VaultRetrieval.Response.formattedResults`, `VaultFiles.grep`/`list`,
/// `VaultMeetings.recentFormatted`).
final class ToolTraceParserTests: XCTestCase {
    // MARK: - Status text

    func test_statusText_dropsLeadingEmoji() {
        XCTAssertEqual(ToolTraceParser.statusText("📷 Looking at your screen…"), "Looking at your screen…")
        XCTAssertEqual(ToolTraceParser.statusText("🗓️ Checking recent meetings…"), "Checking recent meetings…")
        XCTAssertEqual(ToolTraceParser.statusText("🗂️ Listing files…"), "Listing files…")
        XCTAssertEqual(ToolTraceParser.statusText("  Searching the vault…  "), "Searching the vault…")
    }

    func test_statusText_keepsLeadingDigitsAndHash() {
        XCTAssertEqual(ToolTraceParser.statusText("3 files found"), "3 files found")
        XCTAssertEqual(ToolTraceParser.statusText("#1 result"), "#1 result")
    }

    // MARK: - search_vault

    private let searchResult = """
    Found 3 relevant vault documents (focused on this meeting's project) for "guided tour":

    1. Onboarding Scope Review with Northwind (projects/personal/rti/sessions/2026-09-05 150000/summary.md, updated 2026-09-05)
       They kept the tour out of the first release.
    2. Onboarding brief (projects/northwind/onboarding-brief.md, updated 2026-09-03)
       Scope for the first screen.
    3. Pricing (v2) notes (projects/northwind/pricing-v2.md, updated 2026-08-28)

    These are from the user's knowledge vault. Cite the document name when you use one; say so if none actually answers the question.
    """

    func test_searchVault_lineCountsResults() {
        XCTAssertEqual(
            ToolTraceParser.toolLine(forTool: "search_vault", result: searchResult),
            ChatToolLine(kind: .searchVault, text: "Searched vault · 3 results")
        )
    }

    func test_searchVault_noResults() {
        let empty = "No vault documents matched \"tour\". The knowledge base may not cover this."
        XCTAssertEqual(
            ToolTraceParser.toolLine(forTool: "search_vault", result: empty)?.text,
            "Searched vault · no results"
        )
    }

    func test_searchVault_sourcesKeepTitlePathAndDay() {
        let sources = ToolTraceParser.sources(inSearchResult: searchResult)
        XCTAssertEqual(sources.map(\.title), ["Onboarding Scope Review with Northwind", "Onboarding brief", "Pricing (v2) notes"])
        XCTAssertEqual(sources.map(\.path), [
            "projects/personal/rti/sessions/2026-09-05 150000/summary.md",
            "projects/northwind/onboarding-brief.md",
            "projects/northwind/pricing-v2.md",
        ])
        let day = try? XCTUnwrap(sources.first?.date)
        XCTAssertEqual(day.map { ChatTurnRecordBuilder.dayText(for: $0) }, "2026-09-05")
    }

    func test_sources_areUniqueByPath() {
        let doubled = searchResult + "\n4. Onboarding brief again (projects/northwind/onboarding-brief.md, updated 2026-09-03)"
        XCTAssertEqual(ToolTraceParser.sources(inSearchResult: doubled).count, 3)
    }

    func test_searchLine_scopedAndSingular() {
        XCTAssertEqual(ToolTraceParser.searchLine(resultCount: 1, scoped: true).text, "Searched this project · 1 result")
        XCTAssertEqual(ToolTraceParser.searchLine(resultCount: 6, scoped: false).text, "Searched vault · 6 results")
    }

    // MARK: - The other tools

    func test_grepVault_countsFiles() {
        let many = "Files matching \"staff\" in this project (12):\n\n• a.md\n    line"
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "grep_vault", result: many)?.text, "Searched vault text · 12 files")
        let capped = "Files matching \"staff\" (50+):\n\n• a.md"
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "grep_vault", result: capped)?.text, "Searched vault text · 50 files")
        let one = "Files matching \"staff\" in this context:\n\n• projects/a.md\n    staff line"
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "grep_vault", result: one)?.text, "Searched vault text · 1 file")
        let none = "No files in this context contain \"staff\"."
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "grep_vault", result: none)?.text, "Searched vault text · no matches")
    }

    func test_readDocument_namesTheTitle() {
        let frontmatter = "---\ntitle: \"Onboarding brief\"\ndate: 2026-09-03\n---\n\n# Something else\nBody."
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "read_document", result: frontmatter)?.text, "Read Onboarding brief")
        let heading = "Intro line\n# Launch plan\nBody."
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "read_document", result: heading)?.text, "Read Launch plan")
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "read_document", result: "plain text")?.text, "Read a document")
        let refused = "Couldn't read \"x.pdf\" — it may not exist."
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "read_document", result: refused)?.text, "Could not read a document")
    }

    func test_listFiles_andRecentMeetings_count() {
        let list = "Files matching \"transcript\" in this project:\n  a/transcript-1.md\n  a/transcript-2.md"
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "list_files", result: list)?.text, "Listed files · 2")
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "list_files", result: "No files.")?.text, "Listed files · none")

        let recent = """
        This project's most recent meetings and sessions, newest first (the latest is #1):

        1. Pricing sync — Sep 4 (meeting, meetings/a.md)
           Summary.
        2. Kickoff — Sep 1 (session, projects/b.md)

        Sorted by date — for "the last/latest meeting" use #1.
        """
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "recent_meetings", result: recent)?.text, "Checked recent meetings · 2")
    }

    func test_screenTools_andUnknownTool() {
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "capture_screen", result: "Display 1: …"), ChatToolLine(kind: .readScreen, text: "Read the screen"))
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "highlight_screen_text", result: "ok")?.kind, .highlightScreen)
        XCTAssertEqual(ToolTraceParser.toolLine(forTool: "fetch_weather", result: "ok"), ChatToolLine(kind: .other, text: "Used fetch_weather"))
        XCTAssertNil(ToolTraceParser.toolLine(forTool: "", result: "ok"))
    }

    // MARK: - Trace strings

    func test_linesFromTrace_dropTimingsAndReadCounts() {
        XCTAssertEqual(
            ToolTraceParser.lines(fromTrace: "Vault-wide search · 812ms · 6 sources: a.md, b.md, c.md, +3"),
            [ChatToolLine(kind: .searchVault, text: "Searched vault · 6 results")]
        )
        XCTAssertEqual(
            ToolTraceParser.lines(fromTrace: "Scoped search · 90ms · 1 source: a.md"),
            [ChatToolLine(kind: .searchVault, text: "Searched this project · 1 result")]
        )
        XCTAssertEqual(ToolTraceParser.lines(fromTrace: "Vault-wide search · 40ms").map(\.text), ["Searched vault · no results"])
        XCTAssertEqual(ToolTraceParser.lines(fromTrace: "2 attached sources"), [])
    }

    func test_fileTitle_readsAPath() {
        XCTAssertEqual(ToolTraceParser.fileTitle(for: "projects/northwind/onboarding-brief.md"), "onboarding brief")
        XCTAssertEqual(ToolTraceParser.fileTitle(for: "notes_2026.md"), "notes 2026")
    }
}
