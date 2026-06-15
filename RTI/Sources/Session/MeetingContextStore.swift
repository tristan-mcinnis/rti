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

    /// Content of the pre-meeting prep brief auto-matched to this session
    /// (authored by Ava's Meeting Prep job, read from `<meetings>/briefs/`).
    /// Separate from `combined` so it's injected only for active-participant
    /// meeting sessions, never fieldwork/observation. nil when none matched.
    private(set) var briefContext: String?
    /// Display title of the matched brief, for the "RTI is using:" banner.
    private(set) var briefTitle: String?

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

    /// At session start, match a same-day prep brief to this session and load
    /// it (or clear a stale one). Conservative matching (name, or a single
    /// unambiguous brief) lives in `MeetingBriefStore.briefMatching`. Called
    /// fresh every start so a brief never leaks into a later, unrelated session.
    func loadBriefForSession(meetingName: String?) {
        briefTitle = nil
        briefContext = nil
        guard let brief = MeetingBriefStore.briefMatching(
            meetingName: meetingName,
            workstreamName: workstreamName,
            today: Self.todayStamp.string(from: Date())
        ) else { return }
        let content = MeetingBriefStore.content(of: brief).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        briefTitle = brief.displayTitle
        briefContext = content
    }

    private static let todayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
