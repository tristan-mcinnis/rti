import Foundation

/// A pickable client or project from the vault.
struct VaultItem: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let isProject: Bool
}

/// Read-only access to the vault's clients + projects so the Context tab can
/// offer a dropdown ("this meeting is with Acme / project Acme-Digital") and
/// pull that workstream's content in as assistant context. RTI never writes
/// here. The vault is located via Meeting Sentinel's config — the same
/// mechanism `MeetingBriefStore` uses — so no path is hardcoded.
enum VaultWorkstreamStore {
    /// `<vault>/databases` — derived from Sentinel's `recordings_dir`
    /// (`<vault>/databases/meetings/recordings` → up two levels).
    static func databasesDir() -> URL? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-sentinel/config.json")
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = obj["recordings_dir"] as? String, !recordings.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (recordings as NSString).expandingTildeInPath)
            .deletingLastPathComponent() // recordings → meetings
            .deletingLastPathComponent() // meetings → databases
    }

    static func clients() -> [VaultItem] {
        items(in: "clients", isProject: false) { url in
            url.pathExtension == "md"
        } makeItem: { url in
            VaultItem(id: url.path, name: prettify(url.deletingPathExtension().lastPathComponent), url: url, isProject: false)
        }
    }

    static func projects() -> [VaultItem] {
        items(in: "projects", isProject: true) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && url.lastPathComponent != "past-projects"
        } makeItem: { url in
            VaultItem(id: url.path, name: prettify(url.lastPathComponent), url: url, isProject: true)
        }
    }

    /// The text fed to the assistant for a selection: the client note, or a
    /// project's overview (PROJECT.md) + current status (00-status.md).
    /// Max characters of vault content to load as context — keeps a big
    /// project file from bloating every prompt.
    private static let contextCap = 6000

    static func context(for item: VaultItem) -> String {
        let raw: String
        if item.isProject {
            // Status first (most relevant during a call), then the overview.
            let parts = ["00-status.md", "PROJECT.md"].compactMap { name -> String? in
                let url = item.url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
            raw = parts.isEmpty ? "Project: \(item.name)" : parts.joined(separator: "\n\n")
        } else {
            raw = (try? String(contentsOf: item.url, encoding: .utf8)) ?? "Client: \(item.name)"
        }
        return raw.count > contextCap ? String(raw.prefix(contextCap)) + "\n…[truncated]" : raw
    }

    /// Best-effort match of a Sentinel meeting name to a vault workstream — used
    /// to pre-select context when you "Go live" on a recorded meeting. Returns
    /// the item whose name appears (whole-word) in the meeting name, preferring
    /// projects, then the longest match. Conservative: only names of 4+ chars
    /// match, so a short slug can't false-positive. Pure (no FS) for testing.
    static func match(meetingName: String, in items: [VaultItem]) -> VaultItem? {
        let haystack = " \(normalize(meetingName)) "
        guard haystack.count > 2 else { return nil }
        return items
            .filter { item in
                let needle = normalize(item.name)
                return needle.count >= 4 && haystack.contains(" \(needle) ")
            }
            .max { a, b in
                if a.isProject != b.isProject { return !a.isProject } // projects win
                return normalize(a.name).count < normalize(b.name).count // else longest
            }
    }

    // MARK: - Helpers

    /// Lowercase, fold every non-alphanumeric run to a single space. Lets a
    /// hyphenated slug ("acme-digital") match a spaced title ("Acme Digital").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func items(
        in subdir: String,
        isProject _: Bool,
        filter: (URL) -> Bool,
        makeItem: (URL) -> VaultItem
    ) -> [VaultItem] {
        guard let dir = databasesDir()?.appendingPathComponent(subdir, isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              )
        else { return [] }
        return urls.filter(filter).map(makeItem).sorted { $0.name < $1.name }
    }

    /// "umbrella-foods" → "Umbrella Foods".
    private static func prettify(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
