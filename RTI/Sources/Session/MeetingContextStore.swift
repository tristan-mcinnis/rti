import Foundation
import Observation
import RTICore

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

    /// Calendar meeting explicitly selected in Setup. This is read-only context
    /// for the current session; RTI never changes the source calendar event.
    private(set) var calendarMeeting: CalendarMeeting?

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
        if let calendar = calendarContext {
            parts.append(calendar)
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { parts.append(trimmedNote) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The picked project's path relative to `databases/`, so vault search can
    /// focus on this meeting's project (e.g. surface what a participant said in
    /// *this* project's transcripts first). nil when nothing, or a client, is
    /// picked — search then runs vault-wide.
    var workstreamScopePath: String? {
        guard let item = workstreamItem else { return nil }
        return VaultWorkstreamStore.scopeRelativePath(for: item)
    }

    var fileAccessScopePath: String? {
        guard let item = workstreamItem else { return nil }
        return VaultWorkstreamStore.fileAccessRelativePath(for: item)
    }

    func clearWorkstream() {
        workstreamName = nil
        workstreamContext = nil
        workstreamItem = nil
    }

    func selectCalendarMeeting(_ meeting: CalendarMeeting) {
        calendarMeeting = meeting
    }

    func clearCalendarMeeting() {
        calendarMeeting = nil
    }

    /// Compact, authoritative context for Assist and generated summaries. A
    /// participant is an invitee, not evidence they actually spoke or attended.
    var calendarContext: String? {
        guard let meeting = calendarMeeting else { return nil }
        var lines = ["Confirmed calendar meeting: \(meeting.title)"]
        if !meeting.attendees.isEmpty {
            lines.append("Invited participants (not proof of attendance):")
            lines += meeting.attendees.map { attendee in
                attendee.email.map { "- \(attendee.name) <\($0)>" } ?? "- \(attendee.name)"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Reference material for end-of-session summaries. Project context gives
    /// the model the correct vocabulary and spellings; the confirmed calendar
    /// event provides names that are safe to label as invitees.
    var summaryContext: String? {
        var parts: [String] = []
        if let workstream = workstreamContext?.trimmingCharacters(in: .whitespacesAndNewlines), !workstream.isEmpty {
            parts.append("Selected project/wiki context:\n\(String(workstream.prefix(8_000)))")
        }
        if let calendar = calendarContext { parts.append(calendar) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func selectWorkstream(_ item: VaultItem) {
        workstreamName = item.name
        workstreamContext = VaultWorkstreamStore.context(for: item)
        workstreamItem = item
    }

    @discardableResult
    func selectWorkstream(matching query: String) -> VaultItem? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let needle = VaultWorkstreamStore.normalize(trimmed)
        let compactNeedle = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        let items = VaultWorkstreamStore.projects() + VaultWorkstreamStore.clients()
        let match = items
            .filter { item in
                let normalized = VaultWorkstreamStore.normalize(item.name)
                let compactName = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
                return normalized.contains(needle)
                    || needle.contains(normalized)
                    || compactName.contains(compactNeedle)
                    || compactNeedle.contains(compactName)
            }
            .max { a, b in
                if a.isProject != b.isProject { return !a.isProject }
                return a.name.count < b.name.count
            }
        guard let match else { return nil }
        selectWorkstream(match)
        return match
    }

    /// Best-effort: when a session is linked to a Sentinel meeting, pre-select
    /// the vault workstream whose name appears in the meeting name. No-ops if
    /// the user already picked one or nothing matches — a wrong guess just shows
    /// in the "RTI is using:" banner for the user to clear.
    func autoLink(toMeetingNamed meetingName: String) {
        guard workstreamName == nil else { return }
        let items = VaultWorkstreamStore.projects() + VaultWorkstreamStore.clients()
        guard let match = VaultWorkstreamStore.match(meetingName: meetingName, in: items) else { return }
        selectWorkstream(match)
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
