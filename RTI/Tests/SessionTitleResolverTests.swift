import RTICore
import XCTest

/// The Sessions window's title order: manual, title file, vault note,
/// calendar, first transcript line, then a descriptive fallback that never
/// says "Untitled".
final class SessionTitleResolverTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 15, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(2026, 9, 12, 12) }

    private func resolve(_ inputs: SessionTitleInputs) -> ResolvedSessionTitle {
        SessionTitleResolver.resolve(inputs, now: now, calendar: calendar)
    }

    // MARK: - Order

    func testManualTitleWinsOverEverything() {
        let resolved = resolve(SessionTitleInputs(
            titleFile: "  Real study name ",
            hasManualMarker: true,
            vaultNoteTitle: "Vault note",
            calendarTitle: "Calendar event"
        ))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Real study name", source: .manual))
    }

    func testTitleFileBeatsVaultNoteAndCalendar() {
        let resolved = resolve(SessionTitleInputs(
            titleFile: "Q3 Pipeline Review with Timberland",
            vaultNoteTitle: "Vault note",
            calendarTitle: "Calendar event"
        ))
        XCTAssertEqual(resolved.source, .titleFile)
        XCTAssertEqual(resolved.text, "Q3 Pipeline Review with Timberland")
    }

    func testVaultNoteWhenNoTitleFile() {
        let resolved = resolve(SessionTitleInputs(
            titleFile: nil,
            vaultNoteTitle: "Acme Pilot Zero, proposal scoping call with Anna Lu",
            calendarTitle: "Weekly sync"
        ))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Acme Pilot Zero, proposal scoping call with Anna Lu", source: .vaultNote))
    }

    func testCalendarTitleWhenNoNote() {
        let resolved = resolve(SessionTitleInputs(calendarTitle: " Weekly sync ", startedAt: now))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Weekly sync", source: .calendar))
    }

    func testEmptyFilesCountAsMissing() {
        let resolved = resolve(SessionTitleInputs(titleFile: "   ", hasManualMarker: true, vaultNoteTitle: "\n", calendarTitle: ""))
        XCTAssertEqual(resolved.source, .fallback)
    }

    // MARK: - Fallback

    func testFallbackNamesDayTimeAndLength() {
        let resolved = resolve(SessionTitleInputs(startedAt: date(2026, 9, 4, 15, 0), durationSeconds: 16 * 60, transcriptBytes: 21_000))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Meeting · Sep 4, 15:00 · 16 min", source: .fallback))
        XCTAssertFalse(resolved.text.localizedCaseInsensitiveContains("untitled"))
    }

    func testFallbackAddsYearForAnOlderYear() {
        let resolved = resolve(SessionTitleInputs(startedAt: date(2025, 12, 30, 9, 5), durationSeconds: 3_900, transcriptBytes: 50_000))
        XCTAssertEqual(resolved.text, "Meeting · Dec 30, 2025, 09:05 · 1 hr 5 min")
    }

    func testShortTestUnderOneKilobyte() {
        let resolved = resolve(SessionTitleInputs(startedAt: now, durationSeconds: 12, transcriptBytes: 400))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Short test · 12 s", source: .shortTest))
        XCTAssertEqual(
            SessionTitleResolver.fallbackTitle(startedAt: nil, durationSeconds: nil, transcriptBytes: 0),
            "Short test"
        )
    }

    func testLongSessionWithTinyTranscriptIsNotAShortTest() {
        let resolved = resolve(SessionTitleInputs(startedAt: date(2026, 9, 7, 14, 0), durationSeconds: 16 * 60, transcriptBytes: 400))
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Meeting · Sep 7, 14:00 · 16 min", source: .fallback))
    }

    func testFallbackWithNothingKnown() {
        XCTAssertEqual(resolve(SessionTitleInputs()).text, "Meeting")
    }

    func testDurationText() {
        XCTAssertEqual(SessionTitleResolver.durationText(0), "0 s")
        XCTAssertEqual(SessionTitleResolver.durationText(59), "59 s")
        XCTAssertEqual(SessionTitleResolver.durationText(16 * 60 + 20), "16 min")
        XCTAssertEqual(SessionTitleResolver.durationText(60 * 60), "1 hr")
        XCTAssertEqual(SessionTitleResolver.durationText(64 * 60), "1 hr 4 min")
    }

    // MARK: - Live header

    func testLiveTitleOrder() {
        XCTAssertEqual(SessionTitleResolver.liveTitle(calendarTitle: "Weekly sync", project: "Northwind"), "Weekly sync")
        XCTAssertEqual(SessionTitleResolver.liveTitle(calendarTitle: " ", project: "Northwind"), "Northwind")
        XCTAssertEqual(SessionTitleResolver.liveTitle(calendarTitle: nil, project: nil), "Live session")
    }

    func testCleanTitle() {
        XCTAssertEqual(SessionTitleResolver.cleanTitle("TITLE: \"Store Map Pilot Planning.\"\n\nextra"), "Store Map Pilot Planning")
        XCTAssertEqual(SessionTitleResolver.cleanTitle("\n  **Contoso   staff rota review**  "), "Contoso staff rota review")
        XCTAssertNil(SessionTitleResolver.cleanTitle("   \n \"\" "))
        let long = String(repeating: "word ", count: 40)
        let cut = SessionTitleResolver.cleanTitle(long)
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(cut?.count ?? 0, SessionTitleResolver.titleMaxLength)
        XCTAssertFalse(cut?.hasSuffix(" ") ?? true)
    }

    // MARK: - The first substantive transcript line

    private let transcript = """
    ---
    title: "RTI session · 2026-09-04 15:00 · Transcript"
    source: rti
    ---

    # Transcript

    _Sep 4, 2026 at 15:00 · 16 min_

    `0:00` **Speaker 1:** Okay, yeah, so.

    `0:04` **📝 Note:** Remember to ask about the pricing table before the end.

    `0:09` **Speaker 2:** Let's start with the Pilot Zero scope and what Anna needs by Friday.
    """

    func testFirstSubstantiveLineSkipsHeadersFillerAndNotes() {
        XCTAssertEqual(
            SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: transcript),
            "Let's start with the Pilot Zero scope and what Anna needs by Friday"
        )
    }

    func testTranscriptLineTitlesASessionWithNoOtherName() {
        let resolved = resolve(SessionTitleInputs(
            transcriptHead: transcript,
            startedAt: date(2026, 9, 4, 15, 0),
            durationSeconds: 16 * 60,
            transcriptBytes: 21_000
        ))
        XCTAssertEqual(resolved.source, .transcriptLine)
        XCTAssertEqual(resolved.text, "Let's start with the Pilot Zero scope and what Anna needs by Friday")
    }

    func testTranscriptLineRanksBelowEveryNamedSource() {
        let base = SessionTitleInputs(
            transcriptHead: transcript,
            startedAt: date(2026, 9, 4, 15, 0),
            durationSeconds: 16 * 60,
            transcriptBytes: 21_000
        )
        var withCalendar = base
        withCalendar.calendarTitle = "Pilot Zero scoping"
        XCTAssertEqual(resolve(withCalendar).source, .calendar)

        var withNote = base
        withNote.vaultNoteTitle = "Acme Pilot Zero scoping call"
        XCTAssertEqual(resolve(withNote).source, .vaultNote)

        var withTitleFile = base
        withTitleFile.titleFile = "Pilot Zero Proposal Scoping Call"
        XCTAssertEqual(resolve(withTitleFile).source, .titleFile)
    }

    func testTranscriptLineBeatsTheDateAndTimeFallback() {
        // The whole point: a new session is never "Meeting · Sep 4, 15:00".
        let resolved = resolve(SessionTitleInputs(
            transcriptHead: transcript,
            startedAt: date(2026, 9, 4, 15, 0),
            durationSeconds: 16 * 60,
            transcriptBytes: 21_000
        ))
        XCTAssertNotEqual(resolved.source, .fallback)
        XCTAssertFalse(resolved.text.localizedCaseInsensitiveContains("untitled"))
    }

    func testThinOrShortTranscriptLinesAreRejected() {
        let thin = """
        # Transcript

        `0:00` **Speaker 1:** Yeah.
        `0:02` **Speaker 2:** Okay so yeah alright.
        """
        XCTAssertNil(SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: thin))
        XCTAssertNil(SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: "# Transcript\n\nno entries here at all\n"))
    }

    func testShortTestKeepsItsLabelRatherThanATranscriptLine() {
        let resolved = resolve(SessionTitleInputs(
            transcriptHead: transcript,
            startedAt: now,
            durationSeconds: 12,
            transcriptBytes: 400
        ))
        XCTAssertEqual(resolved.source, .shortTest)
    }

    func testLongTranscriptLineIsCutToATitleLength() {
        let long = "`0:00` **Speaker 1:** " + String(repeating: "scope ", count: 40)
        let title = SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: long)
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title?.count ?? 0, SessionTitleResolver.titleMaxLength)
    }

    // MARK: - Chinese, Japanese and Korean transcript lines

    /// The user records mostly in Chinese. Counting words by splitting on
    /// spaces sees one "word" in any Chinese line, so before this the rule
    /// rejected every Chinese session and left it on the date fallback.
    func testAChineseLineNamesASession() {
        let chinese = """
        # Transcript

        _Jun 8, 2026 at 15:58 \u{00B7} 9m 35s_

        `0:01` **Them 1:** \u{6211}\u{4EEC}\u{4ECA}\u{5929}\u{5148}\u{8BA8}\u{8BBA}\u{5B9A}\u{4EF7}\u{8868}\u{548C}\u{4EA4}\u{671F}\u{3002}
        """
        let title = SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: chinese)
        XCTAssertEqual(title, "\u{6211}\u{4EEC}\u{4ECA}\u{5929}\u{5148}\u{8BA8}\u{8BBA}\u{5B9A}\u{4EF7}\u{8868}\u{548C}\u{4EA4}\u{671F}")
    }

    func testShortChineseFillerIsStillRejected() {
        let filler = """
        # Transcript

        `0:00` **Them 1:** \u{597D}\u{7684}\u{3002}
        `0:02` **Them 2:** \u{5BF9}\u{5BF9}\u{5BF9}\u{3002}
        """
        XCTAssertNil(SessionTitleResolver.firstSubstantiveLine(fromTranscriptMarkdown: filler))
    }

    /// A mixed line keeps the English rule, where its word count still means
    /// something: one Chinese term does not let a three-word line through.
    func testAMostlyEnglishLineKeepsTheWordRule() {
        XCTAssertFalse(SessionTitleResolver.isSubstantialSpokenLine("The \u{4EA4}\u{671F} slipped"))
        XCTAssertTrue(
            SessionTitleResolver.isSubstantialSpokenLine("The \u{4EA4}\u{671F} slipped again so we moved the review to Friday")
        )
    }

    func testFullWidthTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(
            SessionTitleResolver.cleanTitle("\u{5B9A}\u{4EF7}\u{8868}\u{8BA8}\u{8BBA}\u{FF0C}"),
            "\u{5B9A}\u{4EF7}\u{8868}\u{8BA8}\u{8BBA}"
        )
        XCTAssertEqual(
            SessionTitleResolver.cleanTitle("\u{4EA4}\u{671F}\u{786E}\u{8BA4}\u{3002}"),
            "\u{4EA4}\u{671F}\u{786E}\u{8BA4}"
        )
    }

    func testCJKCharacterCountIgnoresLatinAndPunctuation() {
        XCTAssertEqual(SessionTitleResolver.cjkCharacterCount("hello, world"), 0)
        XCTAssertEqual(SessionTitleResolver.cjkCharacterCount("\u{5B9A}\u{4EF7}\u{8868} v2"), 3)
    }
}
