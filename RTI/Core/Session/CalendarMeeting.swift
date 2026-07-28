import Foundation

/// A read-only calendar event distilled into the small, stable shape RTI needs
/// for a single live session. EventKit stays in the app target; matching stays
/// Foundation-only so it can be tested without calendar permission.
public struct CalendarMeeting: Identifiable, Hashable, Sendable {
    public struct Attendee: Hashable, Sendable {
        public let name: String
        public let email: String?

        public init(name: String, email: String? = nil) {
            self.name = name
            self.email = email
        }
    }

    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [Attendee]
    /// Human-readable account/calendar labels from EventKit, shown before a
    /// user confirms a meeting so mixed Outlook/iCloud calendars are obvious.
    public let calendarName: String?
    public let calendarSource: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendees: [Attendee] = [],
        calendarName: String? = nil,
        calendarSource: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.calendarName = calendarName
        self.calendarSource = calendarSource
    }
}

public enum CalendarMeetingMatcher {
    /// Returns the most plausible event for a recording that begins at
    /// `sessionStart`: an event containing that time wins, with the event whose
    /// own start is closest preferred. Near-start events are allowed within ten
    /// minutes so a user who presses Record a little early still sees a useful
    /// suggestion. This is deliberately only a suggestion; RTI never selects it
    /// as meeting context until the user confirms it.
    public static func suggestion(for events: [CalendarMeeting], sessionStart: Date) -> CalendarMeeting? {
        let tolerance: TimeInterval = 10 * 60
        return events
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { event in
                event.startDate <= sessionStart + tolerance && event.endDate >= sessionStart - tolerance
            }
            .min { lhs, rhs in
                score(lhs, at: sessionStart) < score(rhs, at: sessionStart)
            }
    }

    private static func score(_ event: CalendarMeeting, at sessionStart: Date) -> (Int, TimeInterval) {
        let containsStart = event.startDate <= sessionStart && sessionStart <= event.endDate
        return (containsStart ? 0 : 1, abs(event.startDate.timeIntervalSince(sessionStart)))
    }
}
