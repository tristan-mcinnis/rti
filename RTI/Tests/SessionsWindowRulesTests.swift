import RTICore
import XCTest

/// The Sessions window's rail rules: date groups, row text, title filtering,
/// content snippets, search-result mapping, find, and keys.
final class SessionsWindowRulesTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 15, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private var now: Date { date(9, 12, 18) }

    private func item(_ id: String, _ title: String, _ when: Date?, project: String? = nil, speakers: [String] = []) -> SessionRailItem {
        SessionRailItem(id: id, title: title, startedAt: when, durationSeconds: 16 * 60, project: project, mode: "Meeting", speakerNames: speakers)
    }

    // MARK: - Groups

    func testGroupsTodayThisWeekEarlier() {
        let items = [
            item("a", "Today late", date(9, 12, 15)),
            item("b", "Today early", date(9, 12, 9)),
            item("c", "Six days ago", date(9, 6, 10)),
            item("d", "Seven days ago", date(9, 5, 10)),
            item("e", "No date", nil),
        ]
        let groups = SessionsWindowRules.grouped(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.group), [.today, .thisWeek, .earlier])
        XCTAssertEqual(groups[0].items.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[1].items.map(\.id), ["c"])
        XCTAssertEqual(groups[2].items.map(\.id), ["d", "e"])
    }

    func testEmptyGroupsAreLeftOut() {
        let groups = SessionsWindowRules.grouped([item("d", "Old", date(8, 1))], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.group), [.earlier])
    }

    // MARK: - Row text

    func testDetailLineTimeTodayDayBefore() {
        XCTAssertEqual(
            SessionsWindowRules.detailLine(for: item("a", "x", date(9, 12, 15), project: "Northwind app"), now: now, calendar: calendar),
            "15:00 · 16 min · Northwind app"
        )
        XCTAssertEqual(
            SessionsWindowRules.detailLine(for: item("b", "x", date(9, 4, 15)), now: now, calendar: calendar),
            "Sep 4 · 16 min"
        )
        XCTAssertEqual(
            SessionsWindowRules.detailLine(for: item("c", "x", date(12, 30, 15, year: 2025)), now: now, calendar: calendar),
            "Dec 30, 2025 · 16 min"
        )
    }

    func testFallbackRowDoesNotRepeatTheTitle() {
        let row = item("a", "Meeting · Sep 4, 15:00 · 16 min", date(9, 4), project: "Contoso retail")
        XCTAssertEqual(SessionsWindowRules.detailLine(for: row, titleSource: .fallback, now: now, calendar: calendar), "Contoso retail")
        let noProject = item("b", "Meeting · Sep 4, 15:00 · 16 min", date(9, 4))
        XCTAssertEqual(SessionsWindowRules.detailLine(for: noProject, titleSource: .fallback, now: now, calendar: calendar), "Meeting")
        // A short test's title names its length, not its day.
        let test = SessionRailItem(id: "c", title: "Short test · 12 s", startedAt: date(8, 31, 11), durationSeconds: 12)
        XCTAssertEqual(SessionsWindowRules.detailLine(for: test, titleSource: .shortTest, now: now, calendar: calendar), "Aug 31")
    }

    func testHeaderDay() {
        XCTAssertEqual(SessionsWindowRules.headerDay(date(9, 12, 9), now: now, calendar: calendar), "Today")
        XCTAssertEqual(SessionsWindowRules.headerDay(date(9, 11, 9), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(SessionsWindowRules.headerDay(date(9, 4, 9), now: now, calendar: calendar), "Sep 4")
    }

    // MARK: - Filtering

    func testMatchesTitleProjectSpeakerAndDateWords() {
        let row = item("a", "Onboarding Scope Review", date(9, 11, 10), project: "Northwind app", speakers: ["Émile Zola"])
        for query in ["onboarding", "SCOPE review", "northwind", "emile", "yesterday", "friday", "sep 11", "2026-09-11", ""] {
            XCTAssertTrue(SessionsWindowRules.matches(row, query: query, now: now, calendar: calendar), query)
        }
        for query in ["pricing", "today", "onboarding pricing"] {
            XCTAssertFalse(SessionsWindowRules.matches(row, query: query, now: now, calendar: calendar), query)
        }
    }

    // MARK: - Snippets

    func testSnippetMarksEveryTermAndCutsAtWords() throws {
        let text = "We talked for a while about the launch. The flat zero scope is the first thing to lock, then the zero price line after that for the spring."
        let snippet = try XCTUnwrap(SessionsWindowRules.snippet(label: "Transcript:", text: text, query: "zero scope"))
        XCTAssertEqual(snippet.label, "Transcript:")
        XCTAssertTrue(snippet.text.hasPrefix("…"), snippet.text)
        XCTAssertTrue(snippet.text.hasSuffix("…"), snippet.text)
        XCTAssertFalse(snippet.text.contains("We talked"), "cut before the context window")
        // Every term inside the window is marked; the window is cut at words.
        XCTAssertEqual(snippet.runs.filter(\.isMatch).map(\.text), ["zero", "scope"])
        XCTAssertEqual(snippet.text, "…for a while about the launch. The flat zero scope is the first thing to lock, then…")
        XCTAssertTrue(snippet.plainText.hasPrefix("Transcript: …"))
        XCTAssertNil(SessionsWindowRules.snippet(label: "Notes:", text: text, query: "pricing"))
    }

    func testKeepingLeadKeepsTheMatchInView() throws {
        let text = "We talked for a while about the launch. The flat zero scope is the first thing to lock."
        let snippet = try XCTUnwrap(SessionsWindowRules.snippet(label: "Transcript:", text: text, query: "zero"))
        let narrow = snippet.keepingLead(12)
        XCTAssertEqual(narrow.label, "Transcript:")
        XCTAssertEqual(narrow.runs.first?.text, "…The flat ")
        XCTAssertEqual(narrow.runs.filter(\.isMatch).map(\.text), ["zero"])
        XCTAssertEqual(snippet.keepingLead(200), snippet, "a short lead stays as it is")
    }

    func testSnippetShortTextHasNoEllipsis() throws {
        let snippet = try XCTUnwrap(SessionsWindowRules.snippet(label: "Notes:", text: "Café   menu\nreview", query: "cafe"))
        XCTAssertEqual(snippet.text, "Café menu review")
        XCTAssertEqual(snippet.runs.first, SessionSnippet.Run(text: "Café", isMatch: true))
    }

    func testSnippetLabels() {
        XCTAssertEqual(SessionsWindowRules.snippetLabel(forPath: "projects/personal/rti/sessions/2026-09-04 150016/transcript.md"), "Transcript:")
        XCTAssertEqual(SessionsWindowRules.snippetLabel(forPath: "projects/personal/rti/sessions/2026-09-04 150016/notes.md"), "Notes:")
        XCTAssertEqual(SessionsWindowRules.snippetLabel(forPath: "projects/personal/rti/sessions/2026-09-04 150016/summary.md"), "Summary:")
        XCTAssertEqual(SessionsWindowRules.snippetLabel(forPath: "meetings/20260904-briefing.md"), "Meeting note:")
        XCTAssertEqual(SessionsWindowRules.snippetLabel(forPath: "meetings/transcripts-raw/20260904-150016-transcript.txt"), "Transcript:")
    }

    func testSessionStampForResultPaths() {
        let notes = ["20260904-briefing.md": "20260904-150016"]
        XCTAssertEqual(SessionsWindowRules.sessionStamp(forResultPath: "projects/personal/rti/sessions/2026-09-04 150016/transcript.md", noteStamps: notes), "20260904-150016")
        XCTAssertEqual(SessionsWindowRules.sessionStamp(forResultPath: "meetings/transcripts-raw/20260904-150016-transcript.txt", noteStamps: notes), "20260904-150016")
        XCTAssertEqual(SessionsWindowRules.sessionStamp(forResultPath: "meetings/20260904-briefing.md", noteStamps: notes), "20260904-150016")
        XCTAssertNil(SessionsWindowRules.sessionStamp(forResultPath: "meetings/20260903-other.md", noteStamps: notes))
        XCTAssertNil(SessionsWindowRules.sessionStamp(forResultPath: "projects/northwind/onboarding-brief.md", noteStamps: notes))
    }

    // MARK: - Status and find

    func testTranscriptStatus() {
        XCTAssertEqual(SessionsWindowRules.transcriptStatus(fileNames: ["transcript.md", "transcript.upgraded.md"]), "Transcript upgraded")
        XCTAssertEqual(SessionsWindowRules.transcriptStatus(fileNames: ["transcript.md", "automatic-upgrade.pending"]), "Upgrade pending")
        XCTAssertNil(SessionsWindowRules.transcriptStatus(fileNames: ["transcript.md"]), "the usual case needs no word")
        XCTAssertEqual(SessionsWindowRules.transcriptStatus(fileNames: ["chat.md"]), "No transcript")
    }

    /// A session whose summary call came back empty must SAY so, not leave a
    /// silent gap in the row.
    func testSummaryStatusNamesAMissingSummary() {
        XCTAssertEqual(SessionsWindowRules.summaryStatus(fileNames: ["transcript.md"]), "Summary unavailable")
        XCTAssertEqual(
            SessionsWindowRules.summaryStatus(fileNames: ["transcript.upgraded.md"]),
            "Summary unavailable",
            "an upgraded transcript with no summary is the same failure"
        )
        XCTAssertNil(SessionsWindowRules.summaryStatus(fileNames: ["transcript.md", "summary.md"]))
        XCTAssertNil(
            SessionsWindowRules.summaryStatus(fileNames: ["chat.md"]),
            "nothing was transcribed, so there was nothing to summarise"
        )
    }

    func testFindRangesAndStatus() {
        let text = "The tour. No TOUR. Détour?"
        XCTAssertEqual(SessionsWindowRules.findRanges(of: "tour", in: text).count, 3)
        XCTAssertTrue(SessionsWindowRules.findRanges(of: "  ", in: text).isEmpty)
        XCTAssertEqual(SessionsWindowRules.findStatus(current: 1, total: 17, query: "tour"), "2 of 17")
        XCTAssertEqual(SessionsWindowRules.findStatus(current: 0, total: 0, query: "tour"), "No matches")
        XCTAssertEqual(SessionsWindowRules.findStatus(current: 0, total: 0, query: ""), "")
    }

    func testMarkdownBlocksKeepCodeFencesWhole() {
        let markdown = "# Title\n\nFirst para\nsame para\n\n```\ncode\n\nmore code\n```\n\n- a\n- b\n"
        XCTAssertEqual(
            SessionsWindowRules.markdownBlocks(markdown),
            ["# Title", "First para\nsame para", "```\ncode\n\nmore code\n```", "- a\n- b"]
        )
    }

    // MARK: - Keys

    func testListToggleIsControlCommandS() {
        XCTAssertEqual(SessionsWindowKeys.command(characters: "s", modifiers: [.command, .control]), .toggleList)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "s", modifiers: [.command]), .saveMarkdown)
        // ⌘\ stays RTI's global show/hide; it never toggles a list here.
        XCTAssertNil(SessionsWindowKeys.command(characters: "\\", modifiers: [.command]))
    }

    func testCommandKeys() {
        XCTAssertEqual(SessionsWindowKeys.command(characters: "f", modifiers: .command), .find)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "g", modifiers: .command), .findNext)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "G", modifiers: [.command, .shift]), .findPrevious)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "k", modifiers: .command), .actions)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "j", modifiers: .command), .ask)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "e", modifiers: .command), .rename)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "C", modifiers: [.command, .shift]), .copy)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "w", modifiers: .command), .close)
        XCTAssertEqual(SessionsWindowKeys.command(characters: "3", modifiers: .command), .openRow(3))
        XCTAssertNil(SessionsWindowKeys.command(characters: "0", modifiers: .command))
        XCTAssertNil(SessionsWindowKeys.command(characters: "k", modifiers: [.command, .option]))
    }

    func testPlainKeys() {
        XCTAssertEqual(SessionsWindowKeys.plainKey(keyCode: 53, modifiers: []), .escape)
        XCTAssertEqual(SessionsWindowKeys.plainKey(keyCode: 36, modifiers: []), .confirm)
        XCTAssertEqual(SessionsWindowKeys.plainKey(keyCode: 36, modifiers: .shift), .confirmAlternate)
        XCTAssertEqual(SessionsWindowKeys.plainKey(keyCode: 126, modifiers: []), .moveUp)
        XCTAssertEqual(SessionsWindowKeys.plainKey(keyCode: 125, modifiers: []), .moveDown)
        XCTAssertNil(SessionsWindowKeys.plainKey(keyCode: 36, modifiers: .command))
        XCTAssertNil(SessionsWindowKeys.plainKey(keyCode: 0, modifiers: []))
    }
}
