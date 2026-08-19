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

    /// Session context is intentionally one-meeting-only. Clearing it after a
    /// finished archive prevents a project or invite from silently leaking
    /// into the next unrelated recording.
    func resetAfterSession() {
        note = ""
        clearWorkstream()
    }

    /// Reference material for end-of-session summaries. Project context gives
    /// the model the correct vocabulary and spellings.
    var summaryContext: String? {
        guard let workstream = workstreamContext?.trimmingCharacters(in: .whitespacesAndNewlines), !workstream.isEmpty else {
            return nil
        }
        return "Selected project/wiki context:\n\(String(workstream.prefix(8_000)))"
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

}
