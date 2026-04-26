import EventKit
import Foundation

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

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
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        return events.first
    }

    func eventTitle(for eventId: String) -> String? {
        guard isAuthorized else { return nil }
        guard let event = store.event(withIdentifier: eventId) else { return nil }
        return event.title
    }
}
