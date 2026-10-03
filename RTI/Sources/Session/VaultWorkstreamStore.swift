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
/// here. The vault is located via RTI's config — the same
/// mechanism `MeetingBriefStore` uses — so no path is hardcoded.
enum VaultWorkstreamStore {
    /// `<vault>/databases` — resolved from RTI's configured recordings
    /// path, with a nearby moved `kb/databases` tree preferred when the
    /// configured path is stale.
    static func databasesDir() -> URL? {
        VaultPaths.preferredDatabasesDirectory()
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

    /// The discussion guides under a project's `discussion-guide/` folder,
    /// recursing sub-folders (some projects bucket guides by audience, e.g.
    /// running/training). Covers every format GuideTextExtractor can read.
    /// When the same guide exists in several formats (e.g. a `.md` and its
    /// `.docx` render), only the most parse-friendly one is listed, so the
    /// project picker shows one row per guide. Empty for clients or projects
    /// without that folder. Read-only; RTI never writes here.
    static func discussionGuides(for item: VaultItem) -> [URL] {
        guard item.isProject else { return [] }
        let dir = item.url.appendingPathComponent("discussion-guide", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        // Parse-friendliness order (lower = preferred). Excludes .html/.yaml —
        // in IC projects those are render/logic artifacts, not importable guides.
        let preference = ["md": 0, "markdown": 1, "txt": 2, "text": 3, "docx": 4, "doc": 5, "rtf": 6, "pdf": 7]

        var bestByBaseName: [String: URL] = [:]
        for url in enumerator.compactMap({ $0 as? URL }) {
            let ext = url.pathExtension.lowercased()
            guard let rank = preference[ext] else { continue }
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
            if let existing = bestByBaseName[key],
               (preference[existing.pathExtension.lowercased()] ?? 99) <= rank {
                continue
            }
            bestByBaseName[key] = url
        }
        return bestByBaseName.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The path of a picked workstream relative to `databases/`, used to focus
    /// vault search on the project a meeting is about (e.g.
    /// `projects/acme-running-retail-concept`). nil for clients — a client is a
    /// single note, not a directory tree to scope to — or when the vault can't
    /// be located.
    static func scopeRelativePath(for item: VaultItem) -> String? {
        guard item.isProject, let base = databasesDir() else { return nil }
        return relativePath(for: item, under: base)
    }

    /// Path for either a project directory or a client note, relative to
    /// `databases/`. Used by direct file access (`@...`) where a selected client
    /// should narrow to its one note, not broaden to the whole vault.
    static func fileAccessRelativePath(for item: VaultItem) -> String? {
        guard let base = databasesDir() else { return nil }
        return relativePath(for: item, under: base)
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

    /// "initech" → "Initech".
    private static func prettify(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
