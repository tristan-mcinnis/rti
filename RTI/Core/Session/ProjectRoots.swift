import Foundation

/// Read-only roots that hold client project folders laid out as
/// `<root>/<client>/<year>/<project>/`. Default `~/Documents/Work`; the
/// optional `project_roots` array in RTI's config replaces it (an empty array
/// turns it off). These never change where RTI writes: every write still goes
/// through `VaultPaths`.
///
/// Paths under a root are shown to the model as `<prefix>/<rest>`, where the
/// prefix is the root folder's name in lowercase (`work/Acme/2026/acme-launch/…`).
public enum ProjectRoots {
    public struct Root: Equatable {
        public let prefix: String
        public let url: URL
    }

    /// Folders in a project tree that are media or build output, not knowledge.
    public static let skipDirComponents: Set<String> = [
        "participant-media", "output", "stimulus", "brand-assets", "audio", "media",
        "assets", "recordings", "node_modules", "__pycache__", "_quarantine",
    ]

    public static func roots(configURL: URL = VaultPaths.configURL()) -> [Root] {
        roots(config: VaultPaths.configDictionary(configURL: configURL))
    }

    public static func roots(config: [String: Any]) -> [Root] {
        let paths: [String]
        if let configured = config["project_roots"] as? [String] {
            paths = configured
        } else {
            paths = [FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Work", isDirectory: true).path]
        }
        var seen = Set<String>()
        return paths.compactMap { raw in
            guard !raw.isEmpty else { return nil }
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            let prefix = url.lastPathComponent.lowercased()
            guard !prefix.isEmpty, seen.insert(prefix).inserted else { return nil }
            return Root(prefix: prefix, url: url)
        }
    }

    /// Resolve `<prefix>/<rest>` under its root. nil when the path names no
    /// root, or when it escapes the root (`..`, a symlink out).
    public static func resolve(_ relative: String, roots: [Root] = roots()) -> URL? {
        guard let (root, rest) = split(relative, roots: roots) else { return nil }
        let base = root.url
        let url = rest.isEmpty ? base : base.appendingPathComponent(rest).standardizedFileURL
        guard url.path == base.path || url.path.hasPrefix(base.path + "/") else { return nil }
        let resolved = url.resolvingSymlinksInPath().path
        let baseResolved = base.resolvingSymlinksInPath().path
        guard resolved == baseResolved || resolved.hasPrefix(baseResolved + "/") else { return nil }
        return url
    }

    /// True when the path starts with a root prefix, so the caller must not
    /// fall back to the knowledge base for it.
    public static func claims(_ relative: String, roots: [Root] = roots()) -> Bool {
        split(relative, roots: roots) != nil
    }

    /// `<prefix>/<rest>` for a URL under a root, else nil.
    public static func displayPath(of url: URL, roots: [Root] = roots()) -> String? {
        let full = url.standardizedFileURL.path
        for root in roots {
            if full == root.url.path { return root.prefix }
            if full.hasPrefix(root.url.path + "/") {
                return root.prefix + "/" + full.dropFirst(root.url.path.count + 1)
            }
        }
        return nil
    }

    /// Project folders for this year and last year that carry a `00-status.md`.
    /// Folders inside the knowledge base are left out: it is walked on its own.
    public static func projects(
        roots: [Root] = roots(),
        now: Date = Date(),
        knowledgeBase: URL? = VaultPaths.preferredDatabasesDirectory()
    ) -> [VaultItem] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let years = ["\(year)", "\(year - 1)"]
        let kbPath = knowledgeBase.map { $0.standardizedFileURL.path + "/" }
        let fm = FileManager.default
        var items: [VaultItem] = []
        for root in roots {
            for client in subdirectories(of: root.url) where !skipDirComponents.contains(client.lastPathComponent) {
                for y in years {
                    let yearDir = client.appendingPathComponent(y, isDirectory: true)
                    for project in subdirectories(of: yearDir)
                    where fm.fileExists(atPath: project.appendingPathComponent("00-status.md").path)
                        && !(kbPath.map { project.standardizedFileURL.path.hasPrefix($0) } ?? false) {
                        items.append(VaultItem(
                            id: project.path,
                            name: "\(client.lastPathComponent) · \(project.lastPathComponent)",
                            url: project,
                            isProject: true
                        ))
                    }
                }
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Visit the knowledge files (`.md`, `.txt`) under `root`, skipping hidden,
    /// media and output folders. `visit` returns false to stop the walk.
    public static func walkFiles(
        under root: URL,
        extraSkips: Set<String> = [],
        keys: [URLResourceKey] = [.isRegularFileKey],
        _ visit: (URL) -> Bool
    ) {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys + [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in en {
            let name = url.lastPathComponent
            if skipDirComponents.contains(name) || extraSkips.contains(name) {
                en.skipDescendants()
                continue
            }
            guard ["md", "txt"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if !visit(url) { return }
        }
    }

    /// The project folders an unscoped search walks: the same set the picker
    /// lists, so a whole-root walk stays bounded.
    public static func searchFolders(roots: [Root] = roots(), now: Date = Date()) -> [URL] {
        projects(roots: roots, now: now).map(\.url)
    }

    private static func split(_ relative: String, roots: [Root]) -> (Root, String)? {
        var rel = relative.trimmingCharacters(in: .whitespaces)
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        for root in roots {
            if rel == root.prefix { return (root, "") }
            if rel.hasPrefix(root.prefix + "/") { return (root, String(rel.dropFirst(root.prefix.count + 1))) }
        }
        return nil
    }

    private static func subdirectories(of dir: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
