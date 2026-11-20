import Foundation

/// A pickable client or project from the vault.
public struct VaultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let isProject: Bool

    public init(
        id: String,
        name: String,
        url: URL,
        isProject: Bool
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isProject = isProject
    }
}

/// Read-only access to the vault's clients + projects so the Context tab can
/// offer a dropdown ("this meeting is with Acme / project Acme-Digital") and
/// pull that workstream's content in as assistant context. RTI never writes
/// here. The vault is located via RTI's config — the same
/// mechanism `MeetingBriefStore` uses — so no path is hardcoded.
public enum VaultWorkstreamStore {
    /// `<vault>/databases` — resolved from RTI's configured recordings path.
    public static func databasesDir() -> URL? {
        VaultPaths.preferredDatabasesDirectory()
    }

    public static func clients() -> [VaultItem] {
        items(in: "clients", isProject: false) { url in
            url.pathExtension == "md"
        } makeItem: { url in
            VaultItem(id: url.path, name: prettify(url.deletingPathExtension().lastPathComponent), url: url, isProject: false)
        }
    }

    public static func projects() -> [VaultItem] {
        items(in: "projects", isProject: true) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && url.lastPathComponent != "past-projects"
        } makeItem: { url in
            VaultItem(id: url.path, name: prettify(url.lastPathComponent), url: url, isProject: true)
        } + ProjectRoots.projects()
    }

    /// The text fed to the assistant for a selection: the client note, or a
    /// project's overview (PROJECT.md) + current status (00-status.md).
    /// Max characters of vault content to load as context — keeps a big
    /// project file from bloating every prompt.
    private static let contextCap = 6000

    public static func context(for item: VaultItem) -> String {
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

    /// The path of a picked workstream relative to `databases/`, used to focus
    /// vault search on the project a meeting is about (e.g.
    /// `projects/acme-running-retail-concept`). nil for clients — a client is a
    /// single note, not a directory tree to scope to — or when the vault can't
    /// be located.
    public static func scopeRelativePath(for item: VaultItem) -> String? {
        guard item.isProject else { return nil }
        if let base = databasesDir(), let rel = relativePath(for: item, under: base) { return rel }
        return ProjectRoots.displayPath(of: item.url)
    }

    /// Path for either a project directory or a client note, relative to
    /// `databases/`. Used by direct file access (`@...`) where a selected client
    /// should narrow to its one note, not broaden to the whole vault.
    public static func fileAccessRelativePath(for item: VaultItem) -> String? {
        if let base = databasesDir(), let rel = relativePath(for: item, under: base) { return rel }
        return ProjectRoots.displayPath(of: item.url)
    }

    private static func relativePath(for item: VaultItem, under base: URL) -> String? {
        let full = item.url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path + "/"
        return full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : nil
    }

    /// Best-effort match of a meeting name to a vault workstream — used
    /// to pre-select context when you "Go live" on a recorded meeting. Returns
    /// the item whose name appears (whole-word) in the meeting name, preferring
    /// projects, then the longest match. Conservative: only names of 4+ chars
    /// match, so a short slug can't false-positive. Pure (no FS) for testing.
    public static func match(meetingName: String, in items: [VaultItem]) -> VaultItem? {
        let haystack = " \(normalize(meetingName)) "
        guard haystack.count > 2 else { return nil }
        let whole = items
            .filter { item in
                matchNames(item).contains { needle in needle.count >= 4 && haystack.contains(" \(needle) ") }
            }
            .max { a, b in
                if a.isProject != b.isProject { return !a.isProject } // projects win
                return normalize(a.name).count < normalize(b.name).count // else longest
            }
        return whole ?? distinctiveMatch(haystack: haystack, in: items)
    }

    /// A project's names to look for whole: "Client · slug" and the slug alone,
    /// so "Northwind Bo An: follow-up" finds `Northwind · northwind-bo-an`.
    private static func matchNames(_ item: VaultItem) -> [String] {
        var names = [normalize(item.name)]
        if let slug = item.name.components(separatedBy: " · ").dropFirst().first {
            names.append(normalize(slug))
        }
        return names
    }

    /// Words in project names that say nothing about which project it is.
    static let commonWords: Set<String> = [
        "china", "chinese", "asia", "global", "research", "project", "agency", "study", "consumer", "consumers",
        "digital", "retail", "concept", "concepts", "brand", "brands", "market", "markets", "follow", "focus",
        "group", "groups", "discussion", "interview", "interviews", "online", "meeting", "call", "sync", "weekly",
        "review", "kickoff", "catch", "update", "team", "inner", "chapter", "with", "workshop", "diagnosis",
    ]

    /// Fallback when no whole name is in the title (2026-11-20: "Lumo Focus
    /// Group follow up discussion" never matched `Acme · acme-lumo-china-agency-research`).
    /// A project matches by its distinctive words: 4 letters or more, not the
    /// client's name, not a common word, not a year. The project with the
    /// most such words in the title wins; a tie picks nothing.
    private static func distinctiveMatch(haystack: String, in items: [VaultItem]) -> VaultItem? {
        var scored: [(VaultItem, Int)] = []
        for item in items where item.isProject {
            let parts = item.name.components(separatedBy: " · ")
            let client = parts.count > 1 ? Set(normalize(parts[0]).split(separator: " ").map(String.init)) : []
            let words = Set(normalize(parts.last ?? item.name).split(separator: " ").map(String.init))
                .filter { $0.count >= 4 && !client.contains($0) && !commonWords.contains($0) && Int($0) == nil }
            let hits = words.filter { haystack.contains(" \($0) ") }.count
            if hits > 0 { scored.append((item, hits)) }
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        return scored.filter { $0.1 == best.1 }.count == 1 ? best.0 : nil
    }

    // MARK: - Helpers

    /// Lowercase, fold every non-alphanumeric run to a single space. Lets a
    /// hyphenated slug ("acme-digital") match a spaced title ("Acme Digital").
    public static func normalize(_ s: String) -> String {
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

    /// "initech" → "Initech".
    private static func prettify(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
