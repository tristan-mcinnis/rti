@preconcurrency import EventKit
import Foundation
import Observation
import RTICore

/// Read-only EventKit bridge for the Setup tab. It only reads a compact window
/// around now and never writes, responds, or edits calendar events.
@Observable @MainActor
final class CalendarMeetingStore {
    static let shared = CalendarMeetingStore()

    private let eventStore = EKEventStore()
    private(set) var events: [CalendarMeeting] = []
    private(set) var suggestion: CalendarMeeting?
    private(set) var accessState: AccessState = .notDetermined

    enum AccessState: Equatable {
        case notDetermined
        case denied
        case available
    }

    private init() {}

    func refresh(at date: Date = Date()) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            accessState = .available
            loadEvents(around: date)
        case .notDetermined:
            accessState = .notDetermined
            events = []
            suggestion = nil
        default:
            accessState = .denied
            events = []
            suggestion = nil
        }
    }

    func requestAccess() {
        eventStore.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    private func loadEvents(around date: Date) {
        let interval: TimeInterval = 12 * 60 * 60
        let predicate = eventStore.predicateForEvents(
            withStart: date.addingTimeInterval(-interval),
            end: date.addingTimeInterval(interval),
            calendars: nil
        )
        events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(CalendarMeeting.init(event:))
            .sorted { $0.startDate < $1.startDate }
        suggestion = CalendarMeetingMatcher.suggestion(for: events, sessionStart: date)
    }
}

private extension CalendarMeeting {
    init(event: EKEvent) {
        let attendees = (event.attendees ?? []).compactMap { participant -> Attendee? in
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            let email = participant.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
            return Attendee(name: name, email: email.isEmpty ? nil : email, isCurrentUser: participant.isCurrentUser)
        }
        self.init(
            id: event.eventIdentifier ?? "\(event.calendar.calendarIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)-\(event.title ?? "")",
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            attendees: attendees,
            calendarName: event.calendar.title,
            calendarSource: event.calendar.source.title
        )
    }
}
