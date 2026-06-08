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
    /// The picked vault item itself — kept so the Setup tab can offer that
    /// project's discussion guides. nil when nothing is picked.
    var workstreamItem: VaultItem?

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
        workstreamItem = nil
    }

    /// Best-effort: when a session is linked to a Sentinel meeting, pre-select
    /// the vault workstream whose name appears in the meeting name. No-ops if
    /// the user already picked one or nothing matches — a wrong guess just shows
    /// in the "RTI is using:" banner for the user to clear.
    func autoLink(toMeetingNamed meetingName: String) {
        guard workstreamName == nil else { return }
        let items = VaultWorkstreamStore.projects() + VaultWorkstreamStore.clients()
        guard let match = VaultWorkstreamStore.match(meetingName: meetingName, in: items) else { return }
        workstreamName = match.name
        workstreamContext = VaultWorkstreamStore.context(for: match)
        workstreamItem = match
    }
}
