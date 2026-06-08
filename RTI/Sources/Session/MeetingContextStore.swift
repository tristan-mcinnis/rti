import Foundation
import Observation

/// Ephemeral, in-memory context for the current meeting — fed to the assistant
/// so its suggestions are grounded. Two sources, both optional:
///   • a workstream picked from the vault (client note / project status), and
///   • a free-text note the user types.
/// Nothing is written to disk; it's the user's to set per meeting.
@Observable @MainActor
final class MeetingContextStore {
    static let shared = MeetingContextStore()

    /// Free-text note (client/project/status, or anything).
    var note: String = ""
    /// Display name of the workstream picked from the vault, if any.
    var workstreamName: String?
    /// Content loaded from the picked vault client/project.
    var workstreamContext: String?

    private init() {}

    /// The combined context fed to the assistant (workstream first, then note).
    /// nil when both are empty.
    var combined: String? {
        var parts: [String] = []
        if let workstream = workstreamContext?.trimmingCharacters(in: .whitespacesAndNewlines), !workstream.isEmpty {
            parts.append(workstream)
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { parts.append(trimmedNote) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func clearWorkstream() {
        workstreamName = nil
        workstreamContext = nil
    }
}
