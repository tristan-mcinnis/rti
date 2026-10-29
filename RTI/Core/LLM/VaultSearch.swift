import Foundation

/// Keyword search over the vault's `databases/` markdown corpus — the local,
/// offline backing for the `search_vault` LLM tool. RTI already reads vault
/// files directly (see `VaultWorkstreamStore`); this widens that to a scored
/// lookup across every project, meeting, client note, proposal, and finding so
/// the assistant can answer "what did we decide about X" from the knowledge
/// base, not just the live transcript.
///
/// Design choices:
///   • Filesystem, not Neon. The vault is local and git-synced; a local scan is
///     zero-auth, offline-capable, and consistent with how RTI already reads the
///     vault. (Neon hybrid search is a possible future upgrade.)
///   • Scope is `databases/` only — never `memory/` (session transcripts), which
///     is a sibling directory and so is excluded for free.
///   • The scan runs off the main actor; the pure `rank` core is testable.
public enum VaultSearch {
    public struct Result: Equatable, Sendable {
        public let title: String
        /// Path relative to `databases/`, e.g. `projects/acmewear/00-status.md`.
        public let relativePath: String
        public let modified: Date
        public let excerpt: String
        public let score: Int

        public init(
            title: String,
            relativePath: String,
            modified: Date,
            excerpt: String,
            score: Int
        ) {
            self.title = title
            self.relativePath = relativePath
            self.modified = modified
            self.excerpt = excerpt
            self.score = score
        }
    }

    /// A citeable handle for one retrieved document. `id` is the short handle
    /// the model is told to cite (`S1`, `S2`, …); the title, path and label
    /// always come from the retrieval record itself, never from model text.
    public struct Citation: Equatable, Sendable {
        public let id: String
        public let title: String
        public let relativePath: String

        /// Compact label for a card's source row: the document's file name.
        public var label: String {
            URL(fileURLWithPath: relativePath).lastPathComponent
        }

        public init(
            id: String,
            title: String,
            relativePath: String
        ) {
            self.id = id
            self.title = title
            self.relativePath = relativePath
        }
    }

    /// One retrieval pass in structured form: the ranked records, the handles a
    /// citation may use, and the same human-readable material the model reads.
    /// Both halves are produced together, so a caller never has to parse a
    /// citation back out of the display string.
    public struct Retrieval: Equatable, Sendable {
        public let results: [Result]
        public let citations: [Citation]
        public let formatted: String
        public let scopedHit: Bool

        public var isEmpty: Bool { results.isEmpty }

        public init(
            results: [Result],
            citations: [Citation],
            formatted: String,
            scopedHit: Bool
        ) {
            self.results = results
            self.citations = citations
            self.formatted = formatted
            self.scopedHit = scopedHit
        }
    }

    /// Directories under `databases/` that are noise for a knowledge query:
    /// raw capture and binary/asset folders, plus RTI's own machine logs.
    private static let skipDirComponents: Set<String> = [
        "recordings", "transcripts-raw", "audio", "media", "assets",
        ".git", "node_modules", "versions", "legacy",
    ]
    /// Skip files larger than this — a knowledge doc is never this big, and a
    /// stray dump shouldn't stall the scan.
    private static let maxFileBytes = 256 * 1024
    /// Safety cap on how many files a single query will read. Set above the
    /// real corpus size (~7k) so a normal vault is scanned whole; this only
    /// guards against a pathological tree.
    private static let maxFilesScanned = 20000
    private static let resultLimit = 5

    /// Thread-safe sink for the parallel scan to merge per-core partial results.
    /// `@unchecked Sendable` because the NSLock makes the mutation safe — the
    /// compiler can't prove it.
    private final class ResultSink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Result] = []
        public func add(_ batch: [Result]) {
            lock.lock(); items.append(contentsOf: batch); lock.unlock()
        }
        public func drain() -> [Result] { items }
    }

    // MARK: - Public entry (async, off the main thread)

    /// Run a vault search and format the results as the string the model sees.
    /// Never throws — a miss or an unreachable vault returns an explanatory line
    /// the model can act on.
    /// `scopeRelativePath` (e.g. `projects/acme-running-retail-concept`) focuses
    /// results on the meeting's project: in-project documents (its transcripts,
    /// meetings, findings) are preferred, and only if nothing in the project
    /// matches does the search broaden to the whole vault — so "what did Group
    /// One say about their favourite store" lands on this project's transcript.
    public static func searchFormatted(query: String, scopeRelativePath: String? = nil) async -> String {
        await retrieve(query: query, scopeRelativePath: scopeRelativePath).formatted
    }

    /// Structured form of a search: the ranked records, their citeable handles,
    /// and the material the model reads, from one pass. `citeable` prints each
    /// document's handle in the material so a citation names an exact ID instead
    /// of a document name the model types from memory. Pass `citeable: false`
    /// (the default, and what `searchFormatted` does) for the existing format.
    public static func retrieve(
        query: String,
        scopeRelativePath: String? = nil,
        citeable: Bool = false
    ) async -> Retrieval {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Retrieval(
                results: [],
                citations: [],
                formatted: "No query was provided. Pass a short phrase describing what to look for.",
                scopedHit: false
            )
        }
        // Keyword scan. Scoped first; if the project has no match, broaden to
        // the whole notes folder.
        var inScope = scopeRelativePath != nil
        var results = await grep(query: trimmed, scopeRelativePath: scopeRelativePath)
        if results.isEmpty, scopeRelativePath != nil {
            inScope = false
            results = await grep(query: trimmed, scopeRelativePath: nil)
        }
        let scopedHit = inScope && !results.isEmpty
        return Retrieval(
            results: results,
            citations: citations(for: results),
            formatted: format(results, query: trimmed, scopedHit: scopedHit, citeable: citeable),
            scopedHit: scopedHit
        )
    }

    /// Assign the citeable handles in rank order. Kept beside `format` so the
    /// printed handle and the acceptable handle can never drift apart.
    public static func citations(for results: [Result]) -> [Citation] {
        results.enumerated().map { index, result in
            Citation(id: "S\(index + 1)", title: result.title, relativePath: result.relativePath)
        }
    }

    /// Async wrapper over the synchronous `search` core, off the main thread.
    private static func grep(query: String, scopeRelativePath: String?) async -> [Result] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Result], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: search(query: query, scopeRelativePath: scopeRelativePath))
            }
        }
    }

    /// Keep only results inside the scoped project; if none, return the
    /// unfiltered top (broaden) and report the miss so the caller can label it.
    public static func applyScope(_ results: [Result], scope: String?) -> (results: [Result], inScope: Bool) {
        guard let scope, !scope.isEmpty else { return (Array(results.prefix(resultLimit)), false) }
        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
        let hits = results.filter { $0.relativePath.hasPrefix(prefix) }
        if !hits.isEmpty { return (Array(hits.prefix(resultLimit)), true) }
        return (Array(results.prefix(resultLimit)), false)
    }

    // MARK: - Core

    /// Synchronous search. Locates `databases/`, scans markdown, ranks, and
    /// returns the top results. Empty when the vault can't be found or nothing
    /// matches.
    /// `scopeRelativePath` restricts the walk to a project subtree under
    /// `databases/` (e.g. `projects/foo`); nil scans the whole knowledge base.
    public static func search(query: String, scopeRelativePath: String? = nil) -> [Result] {
        guard let databases = VaultWorkstreamStore.databasesDir() else { return [] }
        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }

        // Paths stay relative to `databases/` (not the scoped root) so results
        // read the same whether or not a scope is applied.
        // A scope under a read-only project root (`work/<client>/<year>/<project>`)
        // walks that folder. No scope walks the knowledge base plus this
        // year's and last year's project folders.
        let roots = ProjectRoots.roots()
        var walkRoots: [(url: URL, isProjectRoot: Bool)] = {
            guard let scope = scopeRelativePath, !scope.isEmpty else {
                return [(databases, false)] + ProjectRoots.searchFolders(roots: roots).map { ($0, true) }
            }
            if ProjectRoots.claims(scope, roots: roots) {
                return ProjectRoots.resolve(scope, roots: roots).map { [($0, true)] } ?? []
            }
            let dir = databases.appendingPathComponent(scope, isDirectory: true)
            return [((try? dir.checkResourceIsReachable()) == true ? dir : databases, false)]
        }()

        // Phase 1 — cheap walk to collect candidate files (no content reads).
        // Reading + scoring ~7k files is the expensive part, so we do it in
        // parallel below rather than inline here.
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var candidates: [(url: URL, modified: Date)] = []
        func consider(_ url: URL) -> Bool {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true,
                  (vals.fileSize ?? 0) <= maxFileBytes else { return true }
            candidates.append((url, vals.contentModificationDate ?? .distantPast))
            return candidates.count < maxFilesScanned
        }
        walk: while !walkRoots.isEmpty {
            let walk = walkRoots.removeFirst()
            if walk.isProjectRoot {
                var more = true
                ProjectRoots.walkFiles(under: walk.url, extraSkips: skipDirComponents, keys: keys) { url in
                    more = consider(url)
                    return more
                }
                if !more { break walk }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: walk.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if skipDirComponents.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.lowercased() == "md" else { continue }
                if !consider(url) { break walk }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Phase 2 — read + score in parallel across all cores. Each core works
        // a contiguous slice into a local array, then merges once under a lock;
        // no per-file contention. Drops a ~5s sequential scan to sub-second.
        let cores = max(1, min(candidates.count, ProcessInfo.processInfo.activeProcessorCount))
        let chunk = (candidates.count + cores - 1) / cores
        let sink = ResultSink()
        DispatchQueue.concurrentPerform(iterations: cores) { c in
            let start = c * chunk
            guard start < candidates.count else { return }
            let end = min(start + chunk, candidates.count)
            var local: [Result] = []
            for i in start..<end {
                let (url, modified) = candidates[i]
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = relativePath(of: url, under: databases, roots: roots)
                let title = documentTitle(content: content, url: url)
                let (score, excerpt) = rank(terms: terms, title: title, relativePath: relative, content: content)
                guard score > 0 else { continue }
                local.append(Result(title: title, relativePath: relative, modified: modified, excerpt: excerpt, score: score))
            }
            sink.add(local)
        }

        // Highest score first; break ties by recency (fresher wins).
        return Array(
            sink.drain().sorted {
                $0.score != $1.score ? $0.score > $1.score : $0.modified > $1.modified
            }.prefix(resultLimit)
        )
    }

    /// Pure scorer for one document. Returns its score and the best excerpt.
    /// Exposed (internal) so it can be unit-tested without the filesystem.
    public static func rank(terms: [String], title: String, relativePath: String, content: String) -> (score: Int, excerpt: String) {
        let haystack = content.lowercased()
        let titleHay = title.lowercased()
        let pathHay = relativePath.lowercased()

        var score = 0
        var matchedAny = false
        for term in terms {
            let body = occurrences(of: term, in: haystack)
            if body > 0 { matchedAny = true }
            score += body
            // A query term in the title or filename is a strong relevance
            // signal — weight it well above a body mention.
            if titleHay.contains(term) { score += 25; matchedAny = true }
            if pathHay.contains(term) { score += 8; matchedAny = true }
        }
        guard matchedAny else { return (0, "") }

        // Status files are the live state of a project — nudge them up so
        // "where are we on X" surfaces the dashboard, not an old meeting note.
        if pathHay.hasSuffix("00-status.md") { score += 6 }
        if pathHay.contains("/projects/") { score += 2 }

        return (score, bestExcerpt(terms: terms, content: content))
    }

    // MARK: - Helpers

    /// Split a query into search tokens. Latin runs become whole words (length
    /// >= 2); CJK runs — which aren't space-delimited — become character bigrams
    /// (overlapping 2-grams), the standard way to get recall on Chinese text
    /// (`什么时候` → 什么, 么时, 时候). A lone CJK char stands as its own token.
    public static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        var cjk: [Character] = []
        func flushLatin() {
            if latin.count >= 2 { tokens.append(latin) }
            latin = ""
        }
        func flushCJK() {
            if cjk.count == 1 {
                tokens.append(String(cjk[0]))
            } else if cjk.count >= 2 {
                for i in 0..<(cjk.count - 1) {
                    tokens.append(String(cjk[i...(i + 1)]))
                }
            }
            cjk = []
        }
        for ch in query.lowercased() {
            if ch.isCJK {
                flushLatin()
                cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latin.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        // De-dup, drop a few high-frequency English stopwords that only add noise.
        let stop: Set<String> = ["the", "and", "for", "what", "did", "we", "about", "with", "this", "that", "our"]
        var seen = Set<String>()
        return tokens.filter { !stop.contains($0) && seen.insert($0).inserted }
    }

    private static func occurrences(of term: String, in haystack: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: term, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

    /// The line carrying the most query-term hits, trimmed to a single readable
    /// snippet. Skips markdown chrome (headings keep their text, fences drop).
    private static func bestExcerpt(terms: [String], content: String) -> String {
        var best = ""
        var bestHits = -1
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 8, !line.hasPrefix("```"), !line.hasPrefix("---") else { continue }
            let lower = line.lowercased()
            let hits = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            if hits > bestHits {
                bestHits = hits
                best = line
            }
            if hits == terms.count { break } // can't do better
        }
        if bestHits <= 0 { return "" }
        let cleaned = best
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.count > 240 ? String(cleaned.prefix(240)) + "…" : cleaned
    }

    /// Frontmatter `title:` if present, else the first `# heading`, else the
    /// de-slugged filename.
    private static func documentTitle(content: String, url: URL) -> String {
        let lines = content.components(separatedBy: .newlines)
        if lines.first == "---" {
            for line in lines.dropFirst() {
                if line == "---" { break }
                if let t = frontmatterTitle(line) { return t }
            }
        }
        if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
            return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func frontmatterTitle(_ line: String) -> String? {
        guard line.lowercased().hasPrefix("title:") else { return nil }
        let value = line.dropFirst("title:".count)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }

    private static func relativePath(of url: URL, under base: URL, roots: [ProjectRoots.Root]) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path + "/"
        if full.hasPrefix(basePath) { return String(full.dropFirst(basePath.count)) }
        return ProjectRoots.displayPath(of: url, roots: roots) ?? url.lastPathComponent
    }

    /// Render the material the model reads. Internal rather than private so the
    /// citeable and plain renderings can be tested without touching the disk.
    public static func format(
        _ results: [Result],
        query: String,
        scopedHit: Bool = false,
        citeable: Bool = false
    ) -> String {
        guard !results.isEmpty else {
            return "No vault documents matched \"\(query)\". The knowledge base may not cover this — try different or broader terms, or rely on the live transcript."
        }
        let handles = citations(for: results)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let focus = scopedHit ? " (focused on this meeting's project)" : ""
        var out = "Found \(results.count) relevant vault document\(results.count == 1 ? "" : "s")\(focus) for \"\(query)\":\n"
        for (i, r) in results.enumerated() {
            let handle = citeable ? "[\(handles[i].id)] " : ""
            out += "\n\(i + 1). \(handle)\(r.title) (\(r.relativePath), updated \(stamp.string(from: r.modified)))"
            if !r.excerpt.isEmpty { out += "\n   \(r.excerpt)" }
        }
        out += citeable
            ? "\n\nThese are from the user's knowledge vault. Cite one only by its bracketed ID, exactly as shown; say so if none actually answers the question."
            : "\n\nThese are from the user's knowledge vault. Cite the document name when you use one; say so if none actually answers the question."
        return out
    }
}

private extension Character {
    /// True for CJK ideographs / kana / hangul — scripts that aren't space
    /// delimited, so each character is treated as its own token.
    public var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK Ext A
            (0x3040...0x30FF).contains(scalar.value) ||   // Hiragana/Katakana
            (0xAC00...0xD7A3).contains(scalar.value)      // Hangul
        }
    }
}
