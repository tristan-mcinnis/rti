import XCTest
@testable import RTICore

final class CalendarMeetingMatcherTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100_000)

    func testPrefersEventContainingRecordingStart() {
        let early = meeting("early", start: -600, end: -60)
        let current = meeting("current", start: -300, end: 1_500)
        XCTAssertEqual(CalendarMeetingMatcher.suggestion(for: [early, current], sessionStart: start)?.id, "current")
    }

    func testSuggestsEventStartingWithinTenMinutes() {
        let upcoming = meeting("upcoming", start: 8 * 60, end: 68 * 60)
        XCTAssertEqual(CalendarMeetingMatcher.suggestion(for: [upcoming], sessionStart: start)?.id, "upcoming")
    }

    func testDoesNotSuggestDistantEvent() {
        let distant = meeting("distant", start: 11 * 60, end: 71 * 60)
        XCTAssertNil(CalendarMeetingMatcher.suggestion(for: [distant], sessionStart: start))
    }

    private func meeting(_ id: String, start: TimeInterval, end: TimeInterval) -> CalendarMeeting {
        CalendarMeeting(id: id, title: id, startDate: self.start.addingTimeInterval(start), endDate: self.start.addingTimeInterval(end))
    }
}
