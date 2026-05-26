import Foundation

/// A pre-meeting prep brief authored by the Hermes "Meeting Prep" job and
/// saved into the vault at `<meetings>/briefs/`. RTI only reads these — it
/// does not generate briefs.
struct MeetingBrief: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let title: String
    let modified: Date
}

/// Read-only access to the vault's pre-meeting briefs. The briefs directory
/// is located via Meeting Sentinel's own config (`recordings_dir`'s sibling
/// `briefs/`) so the vault path is never hardcoded here.
enum MeetingBriefStore {
    static func briefsDirectory() -> URL? {
        guard let data = try? Data(contentsOf: sentinelConfigURL()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = obj["recordings_dir"] as? String, !recordings.isEmpty
        else { return nil }
        let recordingsURL = URL(fileURLWithPath: (recordings as NSString).expandingTildeInPath)
        return recordingsURL.deletingLastPathComponent()
            .appendingPathComponent("briefs", isDirectory: true)
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

    static func content(of brief: MeetingBrief) -> String {
        (try? String(contentsOf: brief.url, encoding: .utf8))
            ?? "_Couldn't read \(brief.url.lastPathComponent)._"
    }

    private static func sentinelConfigURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_SENTINEL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                .appendingPathComponent("config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-sentinel/config.json")
    }
}
