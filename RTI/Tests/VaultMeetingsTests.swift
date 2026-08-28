import XCTest

/// Locks the filename→sort-stamp parsing that orders meetings newest-first —
/// the core of recency-aware retrieval. A session note with a time must sort
/// above a date-only meeting note on the same day.
final class VaultMeetingsTests: XCTestCase {
    func testDateAndTime() {
        XCTAssertEqual(VaultMeetings.parseStamp("rti-session-20260622-1630.md"), "202606221630")
    }

    func testDateOnlyPadsToMidnight() {
        XCTAssertEqual(VaultMeetings.parseStamp("20260615-briefing-running-concept.md"), "202606150000")
    }

    func testNoDateIsNil() {
        XCTAssertNil(VaultMeetings.parseStamp("PROJECT.md"))
    }

    func testTimedSessionSortsAboveDateOnlySameDay() {
        let timed = VaultMeetings.parseStamp("rti-session-20260622-1630.md")!
        let dateOnly = VaultMeetings.parseStamp("20260622-some-meeting.md")!
        XCTAssertGreaterThan(timed, dateOnly)
    }

    func testNewerDateSortsAbove() {
        let newer = VaultMeetings.parseStamp("rti-session-20260622-0900.md")!
        let older = VaultMeetings.parseStamp("rti-session-20260615-1900.md")!
        XCTAssertGreaterThan(newer, older)
    }
}
