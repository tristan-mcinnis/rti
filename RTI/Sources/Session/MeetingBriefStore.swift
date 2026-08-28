import Foundation

/// A pre-meeting prep brief authored by the Hermes "Meeting Prep" job and
/// saved into the vault at `<meetings>/briefs/`. RTI only reads these — it
/// does not generate briefs.
struct MeetingBrief: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    /// Raw filename stem, e.g. `2026-06-09-acme-brand-prep`.
    let title: String
    let modified: Date

    /// `YYYY-MM-DD` parsed from the filename prefix, if present.
    var datePrefix: String? {
        title.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
            .map { String(title[$0]) }
    }

    /// Human label: drop the date prefix and the `-prep` suffix, de-hyphenate,
    /// title-case. `2026-06-09-acme-brand-prep` → `Acme Brand`.
    var displayTitle: String {
        var s = title
        if let r = s.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        if s.lowercased().hasSuffix("-prep") { s = String(s.dropLast(5)) }
        s = s.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? title : s.capitalized
    }
}

/// Read-only access to the vault's pre-meeting briefs. The briefs directory
/// is located via RTI's config (`recordings_dir`'s sibling
/// `briefs/`) so the vault path is never hardcoded here.
enum MeetingBriefStore {
    static func briefsDirectory() -> URL? {
        VaultPaths.briefsDirectory()
    }

    /// Recent briefs, newest first. Filenames are date-prefixed
    /// (`YYYY-MM-DD-…`), so a reverse lexicographic sort is newest-first.
    static func recentBriefs(limit: Int = 30) -> [MeetingBrief] {
        guard let dir = briefsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        let briefs = urls
            .filter { $0.pathExtension == "md" }
            // Real briefs are date-prefixed (`YYYY-MM-DD-…`). This drops the
            // directory README and any other stray docs in the folder.
            .filter {
                $0.deletingPathExtension().lastPathComponent
                    .range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) != nil
            }
            .map { url -> MeetingBrief in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return MeetingBrief(
                    url: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    modified: modified
                )
            }
            .sorted { $0.title > $1.title }
        return Array(briefs.prefix(limit))
    }

    /// The prep brief to attach to a session, if one is confidently this
    /// session's. Conservative on purpose: a brief is only auto-loaded when it
    /// can be tied to the session by *name* (the linked meeting's name, or the
    /// picked workstream), or when there is exactly one brief for the day. A
    /// same-day-but-unrelated brief (e.g. a fieldwork session on a day with a
    /// separate client call) is left out rather than injected wrongly.
    static func briefMatching(meetingName: String?, workstreamName: String?, today: String) -> MeetingBrief? {
        let todays = recentBriefs(limit: 30).filter { $0.datePrefix == today }
        guard !todays.isEmpty else { return nil }

        for needle in [meetingName, workstreamName].compactMap({ $0 }) {
            let needleTokens = nameTokens(needle)
            guard !needleTokens.isEmpty else { continue }
            if let hit = todays.first(where: { brief in
                !nameTokens(brief.displayTitle).isDisjoint(with: needleTokens)
            }) {
                return hit
            }
        }

        // No name signal but an unambiguous single brief today → safe to use.
        return todays.count == 1 ? todays.first : nil
    }

    /// Significant (4+ char) lowercase word tokens of a name, for overlap
    /// matching. "Acme Brand" → {"acme", "brand"}; "Acme-Digital" → {"acme",
    /// "digital"}. Short tokens are dropped so a stray "the"/"q3" can't match.
    private static func nameTokens(_ s: String) -> Set<String> {
        Set(
            VaultWorkstreamStore.normalize(s)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 4 }
        )
    }

    static func content(of brief: MeetingBrief) -> String {
        let raw = (try? String(contentsOf: brief.url, encoding: .utf8))
            ?? "_Couldn't read \(brief.url.lastPathComponent)._"
        return stripFrontmatter(raw)
    }

    /// Drop a leading YAML frontmatter block (`---` … `---`) so the rendered
    /// brief shows prose, not its `title:`/`type:` metadata header.
    private static func stripFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---",
              let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
