import Foundation
import Observation

/// Ephemeral, in-memory context the user provides for the current meeting —
/// who/what it's about, client, project, status. Fed to the assistant so its
/// suggestions are grounded, without reintroducing the projects/corpus this
/// fork deliberately removed: nothing is written to disk, and it's the user's
/// to set per meeting.
@Observable @MainActor
final class MeetingContextStore {
    static let shared = MeetingContextStore()

    var context: String = ""

    private init() {}

    var trimmed: String? {
        let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
