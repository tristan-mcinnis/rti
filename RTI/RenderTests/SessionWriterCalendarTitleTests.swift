import RTICore
import XCTest

/// Pins the session writer's calendar-title hand-off.
///
/// The Sessions window can only title a session from its calendar event if
/// the writer stamps that event into `session.json` when the recording ends.
/// `SessionFinalizer` is the one call site in the recording path that does
/// it, so it gets its own test: if the argument is ever dropped, or stops
/// reading the picked meeting, this fails rather than quietly returning
/// every new session to "Untitled session".
///
/// It lives in this bundle because `SessionFinalizer` is part of the app
/// module; RTITests compiles only the extracted pure types.
@MainActor
final class SessionWriterCalendarTitleTests: XCTestCase {
    override func tearDown() async throws {
        MeetingContextStore.shared.clearCalendarMeeting()
    }

    private func meeting(title: String) -> CalendarMeeting {
        CalendarMeeting(
            id: "event-1",
            title: title,
            startDate: Date(timeIntervalSince1970: 1_757_000_000),
            endDate: Date(timeIntervalSince1970: 1_757_003_600)
        )
    }

    func testTheWriterPassesThePickedCalendarEventTitle() {
        MeetingContextStore.shared.selectCalendarMeeting(meeting(title: "  Acme Pilot Zero scoping  "))
        XCTAssertEqual(SessionFinalizer.calendarTitleForArchive(), "Acme Pilot Zero scoping")
    }

    func testNoCalendarEventMeansNoTitle() {
        MeetingContextStore.shared.clearCalendarMeeting()
        XCTAssertNil(SessionFinalizer.calendarTitleForArchive())
    }

    func testABlankCalendarTitleIsNotATitle() {
        MeetingContextStore.shared.selectCalendarMeeting(meeting(title: "   "))
        XCTAssertNil(SessionFinalizer.calendarTitleForArchive())
    }

    /// The far end of the same hand-off: what the writer stamps is what the
    /// resolver reads back, so a session with no summary still has a name.
    func testAStampedCalendarTitleResolvesTheSessionTitle() throws {
        MeetingContextStore.shared.selectCalendarMeeting(meeting(title: "Acme Pilot Zero scoping"))
        let metadata = SessionArchiveMetadata(
            sessionId: "abc123",
            systemAudioStartOffsetMs: nil,
            micAudioFile: nil,
            systemAudioFile: nil,
            mode: "Meeting",
            workstream: nil,
            durationSeconds: 960,
            calendarTitle: SessionFinalizer.calendarTitleForArchive()
        )
        let decoded = try JSONDecoder().decode(
            SessionArchiveMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        let resolved = SessionTitleResolver.resolve(
            SessionTitleInputs(calendarTitle: decoded.calendarTitle, durationSeconds: 960)
        )
        XCTAssertEqual(resolved, ResolvedSessionTitle(text: "Acme Pilot Zero scoping", source: .calendar))
    }
}
