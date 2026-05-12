import EventKit
import Foundation
import Observation

@Observable @MainActor
final class CalendarManager {
    static let shared = CalendarManager()

    private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()

    private init() {}

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess || authorizationStatus == .writeOnly
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            await MainActor.run {
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            }
            return granted
        } catch {
            NSLog("[RTI] Calendar access request failed: \(error)")
            return false
        }
    }

    func activeEvent(at date: Date = Date()) -> EKEvent? {
        guard isAuthorized else { return nil }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return nil }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-300),
            end: date.addingTimeInterval(300),
            calendars: calendars
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate != nil }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }

        return events.first
    }

    func eventTitle(for eventId: String) -> String? {
        guard isAuthorized else { return nil }
        guard let event = store.event(withIdentifier: eventId) else { return nil }
        return event.title
    }
}
