import Foundation

/// Agentic file access over the vault's `databases/` tree — the read / grep /
/// list primitives that let the chat assistant work like a researcher instead
/// of being limited to canned search: pull a whole document, keyword-grep across
/// files, or list what's in a project, and chain them in the tool loop (e.g.
/// list recent meetings → read the top one → answer).
///
/// Security: every path is hard-confined to `databases/`. A resolved path that
/// escapes the base (via `..`, an absolute path, a symlink target) is refused,
/// so untrusted transcript/meeting content can never steer a read to `~/.ssh`
/// or anywhere outside the knowledge base. Read-only; RTI never writes the vault.
enum VaultFiles {
    enum MentionResolution {
        case resolved(path: String, content: String)
        case ambiguous(query: String, candidates: [String])
        case missing(query: String)
    }

    private static let maxReadChars = 16000
    private static let maxGrepFiles = 50
    private static let maxLinesPerFile = 4
    private static let maxListItems = 200

    /// Resolve a vault-relative path safely under `databases/`. Accepts the path
    /// shapes the other tools print (`projects/foo/00-status.md`, or with a
    /// leading `vault/databases/` / `databases/`). Returns nil if it escapes.
    static func resolve(_ relative: String) -> URL? {
        guard let dbs = VaultWorkstreamStore.databasesDir() else { return nil }
        var rel = relative.trimmingCharacters(in: .whitespaces)
        for p in ["vault/databases/", "databases/"] where rel.hasPrefix(p) { rel = String(rel.dropFirst(p.count)) }
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        let base = dbs.standardizedFileURL
        let url = base.appendingPathComponent(rel).standardizedFileURL
        // Confinement: the resolved, symlink-collapsed path must stay under base.
        let resolved = url.resolvingSymlinksInPath()
        let baseResolved = base.resolvingSymlinksInPath()
        guard resolved.path == baseResolved.path || resolved.path.hasPrefix(baseResolved.path + "/"),
              url.path == base.path || url.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    // MARK: - read

    /// Full text of one vault document (capped). The model passes a path printed
    /// by search_vault / recent_meetings / grep_vault / list_files.
    static func read(relativePath: String) -> String {
        guard let url = resolve(relativePath) else {
            return "Refused: \"\(relativePath)\" is outside the vault knowledge base."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Couldn't read \"\(relativePath)\" — it may not exist or isn't a text document (PDFs/PPTX aren't readable here; use search_vault for their summary)."
        }
        if text.count > maxReadChars {
            return String(text.prefix(maxReadChars))
                + "\n\n…[truncated — \(text.count) chars total. Grep within it or ask about a specific section.]"
        }
        return text
    }

    /// Resolve an inline `@file` mention to one readable vault document.
    /// Prefers an exact path inside the current project/client scope, then a
    /// fuzzy filename/path match within that scope, finally broadening vault-wide.
    static func resolveMention(_ mention: String, scopeRelativePath: String?) -> MentionResolution {
        let query = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .missing(query: mention) }

        if let exact = exactMentionPath(query, scopeRelativePath: scopeRelativePath),
           let content = rawRead(relativePath: exact)
        {
            return .resolved(path: exact, content: content)
        }

        let scopedMatches = matchingPaths(for: query, scopeRelativePath: scopeRelativePath)
        if let unique = uniqueMatch(scopedMatches), let content = rawRead(relativePath: unique) {
            return .resolved(path: unique, content: content)
        }
        if scopedMatches.count > 1 {
            return .ambiguous(query: query, candidates: Array(scopedMatches.prefix(5)))
        }

        let globalMatches = matchingPaths(for: query, scopeRelativePath: nil)
        if let unique = uniqueMatch(globalMatches), let content = rawRead(relativePath: unique) {
            return .resolved(path: unique, content: content)
        }
        if globalMatches.count > 1 {
            return .ambiguous(query: query, candidates: Array(globalMatches.prefix(5)))
        }
        return .missing(query: query)
    }

    // MARK: - grep

    /// Keyword search across `.md` files (exact substring, case-insensitive) —
    /// the precise complement to semantic search. Scoped to a project subtree
    /// when `scopeRelativePath` is set, else the whole knowledge base.
    static func grep(query: String, scopeRelativePath: String?) -> String {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, let dbs = VaultWorkstreamStore.databasesDir() else { return "No query provided." }
        let root = scopeRelativePath.flatMap { resolve($0) } ?? dbs
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return "Nothing to search." }

        var blocks: [String] = []
        for case let url as URL in en {
            guard url.pathExtension.lowercased() == "md",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.lowercased().contains(needle) else { continue }
            let matched = text.components(separatedBy: .newlines)
                .filter { $0.lowercased().contains(needle) }
                .prefix(maxLinesPerFile)
                .map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return "    " + (t.count > 200 ? String(t.prefix(200)) + "…" : t)
                }
            blocks.append("• \(relativePath(of: url, under: dbs))\n" + matched.joined(separator: "\n"))
            if blocks.count >= maxGrepFiles { break }
        }
        let where_ = scopeRelativePath != nil ? " in this project" : ""
        guard !blocks.isEmpty else { return "No files\(where_) contain \"\(query)\". Try search_vault for a meaning-based match." }
        return "Files matching \"\(query)\"\(where_) (\(blocks.count)\(blocks.count == maxGrepFiles ? "+" : "")):\n\n" + blocks.joined(separator: "\n\n")
    }

    // MARK: - list

    /// List documents in the project (or whole vault), optionally filtered by a
    /// case-insensitive substring of the path — "what files do we have on X".
    static func list(scopeRelativePath: String?, pattern: String?) -> String {
        guard let dbs = VaultWorkstreamStore.databasesDir() else { return "Vault not found." }
        let root = scopeRelativePath.flatMap { resolve($0) } ?? dbs
        let pat = pattern?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return "Nothing to list." }

        var files: [String] = []
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = relativePath(of: url, under: dbs)
            if let pat, !pat.isEmpty, !rel.lowercased().contains(pat) { continue }
            files.append(rel)
            if files.count >= maxListItems { break }
        }
        files.sort()
        let where_ = scopeRelativePath != nil ? " in this project" : ""
        guard !files.isEmpty else { return "No files\(where_)\(pat.map { " matching \"\($0)\"" } ?? "")." }
        let cap = files.count >= maxListItems ? "\n…[more — narrow with a pattern]" : ""
        return "Files\(pattern.map { " matching \"\($0)\"" } ?? "")\(where_):\n" + files.map { "  \($0)" }.joined(separator: "\n") + cap
    }

    // MARK: - Helpers

    private static func relativePath(of url: URL, under base: URL) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path + "/"
        return full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : url.lastPathComponent
    }

    private static func rawRead(relativePath: String) -> String? {
        guard let url = resolve(relativePath),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if text.count > maxReadChars {
            return String(text.prefix(maxReadChars)) + "\n\n…[truncated]"
        }
        return text
    }

    private static func exactMentionPath(_ query: String, scopeRelativePath: String?) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidates: [String] = {
            guard let scope = scopeRelativePath, !trimmed.hasPrefix(scope + "/") else { return [trimmed] }
            return [trimmed, scope + "/" + trimmed]
        }()

        for candidate in candidates {
            guard let url = resolve(candidate),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let dbs = VaultWorkstreamStore.databasesDir() else { return nil }
            return relativePath(of: url, under: dbs)
        }
        return nil
    }

    private static func matchingPaths(for query: String, scopeRelativePath: String?) -> [String] {
        guard let dbs = VaultWorkstreamStore.databasesDir() else { return [] }
        let root = scopeRelativePath.flatMap { resolve($0) } ?? dbs
        let needle = query.lowercased()
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }

        var scored: [(path: String, score: Int)] = []
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.pathExtension.lowercased() == "md" else { continue }
            let rel = relativePath(of: url, under: dbs)
            let relLower = rel.lowercased()
            let basename = url.lastPathComponent.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let score: Int
            if relLower == needle || basename == needle {
                score = 100
            } else if stem == needle {
                score = 90
            } else if relLower.hasSuffix("/" + needle) {
                score = 80
            } else if basename.contains(needle) {
                score = 60
            } else if stem.contains(needle) {
                score = 55
            } else if relLower.contains(needle) {
                score = 40
            } else {
                continue
            }
            scored.append((rel, score))
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.path < rhs.path
            }
            .map(\.path)
    }

    private static func uniqueMatch(_ paths: [String]) -> String? {
        guard paths.count == 1 else { return nil }
        return paths[0]
    }
}
