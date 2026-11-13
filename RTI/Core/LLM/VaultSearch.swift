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
        private var items: [Hit] = []
        func add(_ batch: [Hit]) {
            lock.lock(); items.append(contentsOf: batch); lock.unlock()
        }
        func drain() -> [Hit] { items }
    }

    /// One scored file before its excerpt is read.
    private struct Hit {
        let result: Result
        let url: URL
    }

    /// How hard one search may work. `search_vault` (`.tool`) runs at the
    /// user's request on every core with no limit. Auto's background search
    /// (`.auto`) must never compete with a call on an 8 GB M1 (2026-11-13
    /// audit: one unscoped Auto scan took 92 s and 437 CPU-seconds): it runs
    /// at `.utility` on two workers and stops after 300 ms with what it has.
    /// The walk may use only the first half of the limit (`walkShare`), so a
    /// large folder of decks and images still leaves time to read; each
    /// worker reads at least `minimumReadsPerWorker` files even past the
    /// limit, so a cold cache always warms. Cancellation stops both at once.
    public struct Budget: Sendable, Equatable {
        public let qos: DispatchQoS.QoSClass
        /// nil means one worker per active core.
        public let workers: Int?
        /// nil means no limit.
        public let timeLimit: TimeInterval?

        public init(qos: DispatchQoS.QoSClass, workers: Int?, timeLimit: TimeInterval?) {
            self.qos = qos
            self.workers = workers
            self.timeLimit = timeLimit
        }

        public static let tool = Budget(qos: .userInitiated, workers: nil, timeLimit: nil)
        public static let auto = Budget(qos: .utility, workers: 2, timeLimit: 0.3)

        /// Share of `timeLimit` the walk may use; the rest is kept for reading.
        static let walkShare = 0.5
        /// Files each worker reads before the time limit can stop it.
        static let minimumReadsPerWorker = 8
    }

    /// The documents one session has read, keyed by path and checked against
    /// the file's modification date and size, so a repeat search reads and
    /// lowercases only what changed. In memory only, dropped with the
    /// session: it is not an index and is never written to disk. It keeps
    /// one copy of each file (the lowercased text that scoring reads; the
    /// excerpt is read again from disk for the few results), and stops
    /// adding files past `byteLimit` (16 MB by default), so a large project
    /// folder cannot grow it without bound on an 8 GB Mac.
    /// `@unchecked Sendable` because `lock` guards `documents`.
    public final class DocumentCache: @unchecked Sendable {
        struct Document {
            let modified: Date
            let size: Int
            let title: String
            let lowered: String
        }

        public static let defaultByteLimit = 16 * 1024 * 1024
        private let byteLimit: Int
        private let lock = NSLock()
        private var documents: [String: Document] = [:]
        private var readCount = 0
        private var storedBytes = 0

        public init(byteLimit: Int = DocumentCache.defaultByteLimit) {
            self.byteLimit = byteLimit
        }

        /// Files read from disk so far, for tests.
        public var reads: Int {
            lock.withLock { readCount }
        }

        /// Bytes of text held, for tests.
        public var bytes: Int {
            lock.withLock { storedBytes }
        }

        func document(at url: URL, modified: Date, size: Int) -> Document? {
            let key = url.path
            if let hit = lock.withLock({ documents[key] }), hit.modified == modified, hit.size == size { return hit }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let document = Document(modified: modified, size: size, title: VaultSearch.documentTitle(content: content, url: url),
                                    lowered: content.lowercased())
            let cost = document.lowered.utf8.count
            lock.withLock {
                readCount += 1
                let previous = documents[key]?.lowered.utf8.count ?? 0
                if storedBytes - previous + cost <= byteLimit {
                    documents[key] = document
                    storedBytes += cost - previous
                } else if previous > 0 {
                    // Changed and now too big to keep: drop the stale copy.
                    documents[key] = nil
                    storedBytes -= previous
                }
            }
            return document
        }
    }

    /// Set once to stop a running scan: the caller's task was cancelled.
    /// `@unchecked Sendable` because `lock` guards `stopped`.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.withLock { stopped }
        }

        func stop() {
            lock.withLock { stopped = true }
        }
    }

    // MARK: - Public entry (async, off the main thread)

    /// Structured form of a search: the ranked records, their citeable handles,
    /// and the material the model reads, from one pass. `citeable` prints each
    /// document's handle in the material so a citation names an exact ID instead
    /// of a document name the model types from memory. Pass `citeable: false`
    /// (the default) for the existing format. `broaden` (default true) lets a
    /// scoped search with no hit fall back to the whole notes folder, as the
    /// `search_vault` tool does. With `broaden: false` a scoped search stays in
    /// its scope: no fallback, and a scope that does not resolve finds nothing.
    public static func retrieve(
        query: String,
        scopeRelativePath: String? = nil,
        citeable: Bool = false,
        broaden: Bool = true,
        budget: Budget = .tool,
        cache: DocumentCache? = nil
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
        // the whole notes folder (unless the caller asked to stay in scope).
        var inScope = scopeRelativePath != nil
        var results = await grep(query: trimmed, scopeRelativePath: scopeRelativePath, broaden: broaden,
                                 budget: budget, cache: cache)
        if results.isEmpty, scopeRelativePath != nil, broaden {
            inScope = false
            results = await grep(query: trimmed, scopeRelativePath: nil, budget: budget, cache: cache)
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

    /// Async wrapper over the synchronous `search` core, off the main thread
    /// at the budget's QoS. Cancelling the calling task stops the scan.
    private static func grep(query: String, scopeRelativePath: String?, broaden: Bool = true,
                             budget: Budget, cache: DocumentCache?) async -> [Result] {
        let flag = StopFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[Result], Never>) in
                DispatchQueue.global(qos: budget.qos).async {
                    cont.resume(returning: search(query: query, scopeRelativePath: scopeRelativePath, broaden: broaden,
                                                  budget: budget, cache: cache, isCancelled: { flag.isStopped }))
                }
            }
        } onCancel: {
            flag.stop()
        }
    }

    // MARK: - Core

    /// Synchronous search. Locates `databases/`, scans markdown, ranks, and
    /// returns the top results. Empty when the vault can't be found or nothing
    /// matches.
    /// `scopeRelativePath` restricts the walk to a project subtree under
    /// `databases/` (e.g. `projects/foo`); nil scans the whole knowledge base.
    /// A scope folder that does not exist widens to the whole knowledge base
    /// only when `broaden` is true; with false it finds nothing. `now` is the
    /// budget's clock, replaced only by tests.
    public static func search(
        query: String,
        scopeRelativePath: String? = nil,
        broaden: Bool = true,
        budget: Budget = .tool,
        cache: DocumentCache? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> [Result] {
        let start = now()
        let deadline = budget.timeLimit.map { start + UInt64($0 * 1_000_000_000) }
        let walkDeadline = budget.timeLimit.map { start + UInt64($0 * Budget.walkShare * 1_000_000_000) }
        @Sendable func past(_ limit: UInt64?) -> Bool {
            limit.map { now() >= $0 } ?? false
        }
        let walkShouldStop: () -> Bool = { isCancelled() || past(walkDeadline) }
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
            if (try? dir.checkResourceIsReachable()) == true { return [(dir, false)] }
            return broaden ? [(databases, false)] : []
        }()

        // Phase 1 — cheap walk to collect candidate files (no content reads).
        // Reading + scoring ~7k files is the expensive part, so we do it in
        // parallel below rather than inline here.
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var candidates: [(url: URL, modified: Date)] = []
        var sizes: [Int] = []
        func consider(_ url: URL) -> Bool {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true,
                  (vals.fileSize ?? 0) <= maxFileBytes else { return true }
            candidates.append((url, vals.contentModificationDate ?? .distantPast))
            sizes.append(vals.fileSize ?? 0)
            return candidates.count < maxFilesScanned
        }
        walk: while !walkRoots.isEmpty {
            let walk = walkRoots.removeFirst()
            if walk.isProjectRoot {
                var more = true
                ProjectRoots.walkFiles(under: walk.url, extraSkips: skipDirComponents, keys: keys,
                                       shouldStop: walkShouldStop) { url in
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
                // Every enumerated item, not only the markdown, so a folder of
                // decks and images cannot outrun the budget.
                if walkShouldStop() { break walk }
                if skipDirComponents.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.lowercased() == "md" else { continue }
                if !consider(url) { break walk }
            }
        }
        guard !candidates.isEmpty else { return [] }
        // Newest first, so a search stopped by its budget has read the
        // freshest notes.
        let order = candidates.indices.sorted { candidates[$0].modified > candidates[$1].modified }

        // Phase 2 — read + score in parallel. Each worker takes every n-th
        // file into a local array, then merges once under a lock; no per-file
        // contention. A budget caps the workers and stops them at its time
        // limit, keeping what was scored so far. A cache skips files read
        // earlier in the session and unchanged since.
        let available = budget.workers.map { min($0, ProcessInfo.processInfo.activeProcessorCount) }
            ?? ProcessInfo.processInfo.activeProcessorCount
        let workers = max(1, min(candidates.count, available))
        let sink = ResultSink()
        let files = order.map { candidates[$0] }
        let fileSizes = order.map { sizes[$0] }
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var local: [Hit] = []
            var readHere = 0
            for i in stride(from: worker, to: files.count, by: workers) {
                if isCancelled() { break }
                if readHere >= Budget.minimumReadsPerWorker, past(deadline) { break }
                readHere += 1
                let (url, modified) = files[i]
                let title: String
                let lowered: String
                if let cache {
                    guard let document = cache.document(at: url, modified: modified, size: fileSizes[i]) else { continue }
                    (title, lowered) = (document.title, document.lowered)
                } else {
                    guard let read = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    (title, lowered) = (documentTitle(content: read, url: url), read.lowercased())
                }
                let relative = relativePath(of: url, under: databases, roots: roots)
                let score = score(terms: terms, title: title, relativePath: relative, lowered: lowered)
                guard score > 0 else { continue }
                local.append(Hit(result: Result(title: title, relativePath: relative, modified: modified,
                                                excerpt: "", score: score), url: url))
            }
            sink.add(local)
        }

        // Highest score first; break ties by recency (fresher wins). Only the
        // results read their excerpt, from disk, in the original case.
        let top = sink.drain().sorted {
            $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.result.modified > $1.result.modified
        }.prefix(resultLimit)
        return top.map { hit in
            let result = hit.result
            guard !isCancelled(), let content = try? String(contentsOf: hit.url, encoding: .utf8) else { return result }
            return Result(title: result.title, relativePath: result.relativePath, modified: result.modified,
                          excerpt: bestExcerpt(terms: terms, content: content), score: result.score)
        }
    }

    /// Pure scorer for one document. Returns its score and the best excerpt.
    /// Exposed (internal) so it can be unit-tested without the filesystem.
    public static func rank(terms: [String], title: String, relativePath: String, content: String) -> (score: Int, excerpt: String) {
        rank(terms: terms, title: title, relativePath: relativePath, content: content, lowered: content.lowercased())
    }

    /// `rank` with the lowercased content supplied, so a cached document is
    /// not lowercased again on every search.
    static func rank(terms: [String], title: String, relativePath: String, content: String,
                     lowered haystack: String) -> (score: Int, excerpt: String) {
        let score = score(terms: terms, title: title, relativePath: relativePath, lowered: haystack)
        return score > 0 ? (score, bestExcerpt(terms: terms, content: content)) : (0, "")
    }

    /// The score alone, from the lowercased text: what the scan needs for
    /// every file. Zero means no match.
    static func score(terms: [String], title: String, relativePath: String, lowered haystack: String) -> Int {
        let titleHay = title.lowercased()
        let pathHay = relativePath.lowercased()

        let fileHay = (pathHay as NSString).lastPathComponent

        var score = 0
        var covered = 0
        for term in terms {
            let word = searchStem(term)
            let body = occurrences(of: word, in: haystack)
            var hit = body > 0
            score += body
            // A query term in the title or filename is a strong relevance
            // signal — weight it well above a body mention.
            if occurrences(of: word, in: titleHay) > 0 { score += 25; hit = true }
            if occurrences(of: word, in: fileHay) > 0 {
                score += 8
                hit = true
            } else if occurrences(of: word, in: pathHay) > 0 {
                // A folder name lifts a real match but never makes one: every
                // file under `acme-running` would otherwise match "running".
                score += 8
            }
            if hit { covered += 1 }
        }
        guard covered > 0, covered >= requiredCoverage(termCount: terms.count) else { return 0 }

        // Status files are the live state of a project — nudge them up so
        // "where are we on X" surfaces the dashboard, not an old meeting note.
        if pathHay.hasSuffix("00-status.md") { score += 6 }
        if pathHay.contains("/projects/") { score += 2 }
        return score
    }

    // MARK: - Helpers

    /// Split a query into search tokens. Latin runs become whole words (length
    /// >= 2); CJK runs — which aren't space-delimited — become character bigrams
    /// (overlapping 2-grams), the standard way to get recall on Chinese text
    /// (`什么时候` → 什么, 么时, 时候). A lone CJK char stands as its own token.
    public static func tokenize(_ query: String) -> [String] {
        // De-dup, drop a few high-frequency English stopwords that only add noise.
        let stop: Set<String> = ["the", "and", "for", "what", "did", "we", "about", "with", "this", "that", "our", "tell", "me", "give", "have", "done", "some", "from"]
        var seen = Set<String>()
        return rawTokens(query).filter { !stop.contains($0) && seen.insert($0).inserted }
    }

    /// Every search token in order, repeats and stopwords kept: the shared
    /// split under `tokenize` and `AutoVaultQuery`, which counts repeats.
    static func rawTokens(_ query: String) -> [String] {
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
        return tokens
    }

    /// About 60% of the query must appear, so one common word cannot pull a
    /// document in. Capped for "Answer latest", which queries with a whole
    /// transcript window.
    private static func requiredCoverage(termCount: Int) -> Int {
        min((termCount * 3 + 4) / 5, 4)
    }

    /// "consumers" should find "consumer". Matches run from the start of a
    /// word, so the shorter form still finds the plural.
    private static func searchStem(_ term: String) -> String {
        term.count > 4 && term.hasSuffix("s") && !term.hasSuffix("ss") ? String(term.dropLast()) : term
    }

    /// Hits that start a word, so "mira" finds "Mira" but not "Almira". A term
    /// of three letters or fewer must be the whole word ("ai" is not "aim").
    /// Chinese has no word boundaries, so its bigrams match anywhere.
    private static func occurrences(of term: String, in haystack: String) -> Int {
        guard let first = term.first else { return 0 }
        func isWordChar(_ ch: Character) -> Bool { (ch.isLetter || ch.isNumber) && !ch.isCJK }
        let bounded = !first.isCJK
        let wholeWord = bounded && term.count <= 3
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: term, range: idx..<haystack.endIndex) {
            idx = r.upperBound
            if bounded, r.lowerBound > haystack.startIndex, isWordChar(haystack[haystack.index(before: r.lowerBound)]) { continue }
            if wholeWord, r.upperBound < haystack.endIndex, isWordChar(haystack[r.upperBound]) { continue }
            count += 1
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
    fileprivate static func documentTitle(content: String, url: URL) -> String {
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

extension Character {
    /// True for CJK ideographs / kana / hangul — scripts that aren't space
    /// delimited, so each character is treated as its own token.
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK Ext A
            (0x3040...0x30FF).contains(scalar.value) ||   // Hiragana/Katakana
            (0xAC00...0xD7A3).contains(scalar.value)      // Hangul
        }
    }
}
