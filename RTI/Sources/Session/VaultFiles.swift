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
    private static let maxMentionGrepBytes = 256 * 1024
    private static let mentionIndexTTL: TimeInterval = 180
    private static let mentionIndexMaxFiles = 25000
    private static let maxGrepFiles = 50
    private static let maxLinesPerFile = 4
    private static let maxListItems = 200
    private static let mentionIndexCache = MentionIndexCache()

    private struct MentionIndexEntry: Sendable {
        let path: String
        let lowerPath: String
        let basename: String
        let stem: String
        let compactPath: String
        let compactStem: String
        let pathTokens: [String]
        let stemAcronym: String
        let modified: Date
    }

    private struct MentionRankedPath {
        let path: String
        let score: Int
        let modified: Date
    }

    private final class MentionIndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var basePath: String?
        private var builtAt: Date?
        private var entries: [MentionIndexEntry] = []

        func get(base: URL) -> [MentionIndexEntry]? {
            lock.lock()
            defer { lock.unlock() }
            guard basePath == base.path,
                  let builtAt,
                  Date().timeIntervalSince(builtAt) < mentionIndexTTL else { return nil }
            return entries
        }

        func set(base: URL, entries: [MentionIndexEntry]) {
            lock.lock()
            self.basePath = base.path
            self.builtAt = Date()
            self.entries = entries
            lock.unlock()
        }
    }

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

    static func mentionCandidates(_ query: String, scopeRelativePath: String?, limit: Int = 6) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dbs = VaultWorkstreamStore.databasesDir() else { return [] }
        let entries = mentionIndex(under: dbs)
        let scopedEntries = mentionScopedEntries(entries, scopeRelativePath: scopeRelativePath)
        let scoped = rankedMentionCandidates(trimmed, entries: scopedEntries, limit: limit)
        if !scoped.isEmpty || scopeRelativePath == nil { return scoped.map(\.path) }
        return rankedMentionCandidates(trimmed, entries: entries, limit: limit).map(\.path)
    }

    static func prewarmMentionIndex() {
        guard let dbs = VaultWorkstreamStore.databasesDir() else { return }
        _ = mentionIndex(under: dbs)
    }

    static func mentionCandidatesForTesting(
        _ query: String,
        paths: [String],
        scopeRelativePath: String? = nil,
        limit: Int = 6
    ) -> [String] {
        let entries = paths.map { mentionIndexEntry(path: $0, modified: .distantPast) }
        let scopedEntries = mentionScopedEntries(entries, scopeRelativePath: scopeRelativePath)
        let scoped = rankedMentionCandidates(query, entries: scopedEntries, limit: limit)
        if !scoped.isEmpty || scopeRelativePath == nil { return scoped.map(\.path) }
        return rankedMentionCandidates(query, entries: entries, limit: limit).map(\.path)
    }

    // MARK: - grep

    /// Keyword search across `.md` files (exact substring, case-insensitive) —
    /// the precise complement to semantic search. Scoped to a project subtree
    /// when `scopeRelativePath` is set, else the whole knowledge base.
    static func grep(query: String, scopeRelativePath: String?) -> String {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, let dbs = VaultWorkstreamStore.databasesDir() else { return "No query provided." }
        let root = scopeRelativePath.flatMap { resolve($0) } ?? dbs
        if (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            guard root.pathExtension.lowercased() == "md",
                  let text = try? String(contentsOf: root, encoding: .utf8),
                  text.lowercased().contains(needle) else {
                return "No files in this context contain \"\(query)\"."
            }
            let matched = text.components(separatedBy: .newlines)
                .filter { $0.lowercased().contains(needle) }
                .prefix(maxLinesPerFile)
                .map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return "    " + (t.count > 200 ? String(t.prefix(200)) + "…" : t)
                }
            return "Files matching \"\(query)\" in this context:\n\n• \(relativePath(of: root, under: dbs))\n" + matched.joined(separator: "\n")
        }
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
        if (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = relativePath(of: root, under: dbs)
            guard pat == nil || pat == "" || rel.lowercased().contains(pat ?? "") else {
                return "No files in this context matching \"\(pat ?? "")\"."
            }
            return "Files in this context:\n  \(rel)"
        }
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
        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return listRecentPaths(root: root, under: dbs)
        }
        if (try? root.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile) == true {
            return scoreMentionFile(root, needle: needle, under: dbs).map { [$0.path] } ?? []
        }
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }

        var scored: [(path: String, score: Int)] = []
        for case let url as URL in en {
            if let match = scoreMentionFile(url, needle: needle, under: dbs) {
                scored.append(match)
            }
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.path < rhs.path
            }
            .map(\.path)
    }

    private static func mentionIndex(under dbs: URL) -> [MentionIndexEntry] {
        let base = dbs.standardizedFileURL
        if let cached = mentionIndexCache.get(base: base) { return cached }

        guard let en = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [MentionIndexEntry] = []
        for case let url as URL in en {
            if shouldSkipMentionIndexPath(url, under: base) {
                en.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let path = relativePath(of: url, under: base)
            entries.append(mentionIndexEntry(path: path, modified: values.contentModificationDate ?? .distantPast))
            if entries.count >= mentionIndexMaxFiles { break }
        }

        mentionIndexCache.set(base: base, entries: entries)
        return entries
    }

    private static func mentionIndexEntry(path: String, modified: Date) -> MentionIndexEntry {
        let lowerPath = path.lowercased()
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return MentionIndexEntry(
            path: path,
            lowerPath: lowerPath,
            basename: url.lastPathComponent.lowercased(),
            stem: stem,
            compactPath: compactMentionKey(lowerPath),
            compactStem: compactMentionKey(stem),
            pathTokens: mentionTokens(lowerPath),
            stemAcronym: mentionAcronym(stem),
            modified: modified
        )
    }

    private static func mentionScopedEntries(_ entries: [MentionIndexEntry], scopeRelativePath: String?) -> [MentionIndexEntry] {
        guard var scope = scopeRelativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scope.isEmpty else { return entries }
        for prefix in ["vault/databases/", "databases/"] where scope.hasPrefix(prefix) {
            scope = String(scope.dropFirst(prefix.count))
        }
        while scope.hasPrefix("/") { scope = String(scope.dropFirst()) }
        if scope.hasSuffix(".md") {
            return entries.filter { $0.path == scope }
        }
        let directoryPrefix = scope.hasSuffix("/") ? scope : scope + "/"
        return entries.filter { $0.path.hasPrefix(directoryPrefix) }
    }

    private static func rankedMentionCandidates(_ query: String, entries: [MentionIndexEntry], limit: Int) -> [MentionRankedPath] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return entries
                .sorted { lhs, rhs in
                    lhs.modified != rhs.modified ? lhs.modified > rhs.modified : lhs.path < rhs.path
                }
                .prefix(limit)
                .map { MentionRankedPath(path: $0.path, score: 1, modified: $0.modified) }
        }

        let compact = compactMentionKey(trimmed)
        let tokens = mentionTokens(trimmed)
        return entries
            .compactMap { entry -> MentionRankedPath? in
                let score = mentionScore(query: trimmed, compactQuery: compact, tokens: tokens, entry: entry)
                guard score > 0 else { return nil }
                return MentionRankedPath(path: entry.path, score: score, modified: entry.modified)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.path < rhs.path
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func mentionScore(query: String, compactQuery: String, tokens: [String], entry: MentionIndexEntry) -> Int {
        if tokens.count > 1 {
            let tokenScores = tokens.map { mentionTokenScore($0, entry: entry) }
            guard tokenScores.allSatisfy({ $0 > 0 }) else { return 0 }
            return tokenScores.reduce(160, +) + mentionContextBoost(entry)
        }

        var score: Int
        if entry.lowerPath == query || entry.basename == query {
            score = 1000
        } else if entry.stem == query {
            score = 950
        } else if entry.basename.hasPrefix(query) {
            score = 850
        } else if entry.stem.hasPrefix(query) {
            score = 820
        } else if entry.lowerPath.hasSuffix("/" + query) {
            score = 760
        } else if entry.basename.contains(query) {
            score = 680
        } else if entry.stem.contains(query) {
            score = 640
        } else if entry.lowerPath.contains(query) {
            score = 520
        } else if !compactQuery.isEmpty && entry.compactStem.contains(compactQuery) {
            score = 430
        } else if !compactQuery.isEmpty && entry.compactPath.contains(compactQuery) {
            score = 360
        } else if !compactQuery.isEmpty && mentionSubsequence(compactQuery, in: entry.compactPath) {
            score = 220
        } else {
            return 0
        }

        score += mentionContextBoost(entry)
        return score
    }

    private static func mentionTokenScore(_ token: String, entry: MentionIndexEntry) -> Int {
        let compact = compactMentionKey(token)
        if token == entry.stem || token == entry.basename { return 460 }
        if entry.pathTokens.contains(token) { return 420 }
        if entry.pathTokens.contains(where: { $0.hasPrefix(token) }) { return 360 }
        if entry.stem.contains(token) || entry.basename.contains(token) { return 330 }
        if entry.lowerPath.contains(token) { return 260 }
        if !compact.isEmpty, entry.stemAcronym == compact { return 390 }
        if !compact.isEmpty, entry.stemAcronym.hasPrefix(compact) { return 340 }
        if !compact.isEmpty, entry.compactStem.contains(compact) { return 280 }
        if !compact.isEmpty, entry.compactPath.contains(compact) { return 230 }
        if !compact.isEmpty, mentionSubsequence(compact, in: entry.compactStem) { return 160 }
        return 0
    }

    private static func mentionContextBoost(_ entry: MentionIndexEntry) -> Int {
        var score = 0
        if entry.lowerPath.contains("/00-") { score += 18 }
        if entry.lowerPath.contains("/notes/") || entry.lowerPath.contains("/transcripts/") { score += 10 }
        if entry.lowerPath.contains("/archive/") { score -= 12 }
        return score
    }

    private static func mentionTokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func mentionAcronym(_ value: String) -> String {
        mentionTokens(value).compactMap(\.first).map(String.init).joined()
    }

    private static func compactMentionKey(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    private static func mentionSubsequence(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var searchStart = haystack.startIndex
        for character in needle {
            guard let match = haystack[searchStart...].firstIndex(of: character) else { return false }
            searchStart = haystack.index(after: match)
        }
        return true
    }

    private static func shouldSkipMentionIndexPath(_ url: URL, under base: URL) -> Bool {
        let rel = relativePath(of: url, under: base).lowercased()
        let components = rel.split(separator: "/").map(String.init)
        return components.contains { component in
            component == ".git"
                || component == "node_modules"
                || component == "attachments"
                || component == "audio"
                || component == "media"
                || component == "assets"
                || component == "transcripts-raw"
                || component == "recordings"
        }
    }

    private static func listRecentPaths(root: URL, under dbs: URL) -> [String] {
        if (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return [relativePath(of: root, under: dbs)]
        }
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(path: String, modified: Date)] = []
        for case let url as URL in en {
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            files.append((relativePath(of: url, under: dbs), values.contentModificationDate ?? .distantPast))
            if files.count >= 200 { break }
        }
        return files.sorted { $0.modified > $1.modified }.map(\.path)
    }

    private static func scoreMentionFile(_ url: URL, needle: String, under dbs: URL) -> (path: String, score: Int)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              url.pathExtension.lowercased() == "md" else { return nil }
        let rel = relativePath(of: url, under: dbs)
        let relLower = rel.lowercased()
        let basename = url.lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if relLower == needle || basename == needle { return (rel, 100) }
        if stem == needle { return (rel, 90) }
        if relLower.hasSuffix("/" + needle) { return (rel, 80) }
        if basename.contains(needle) { return (rel, 60) }
        if stem.contains(needle) { return (rel, 55) }
        if relLower.contains(needle) { return (rel, 40) }
        guard (values.fileSize ?? 0) <= maxMentionGrepBytes,
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.lowercased().contains(needle) else { return nil }
        return (rel, 20)
    }

    private static func uniqueMatch(_ paths: [String]) -> String? {
        guard paths.count == 1 else { return nil }
        return paths[0]
    }
}
