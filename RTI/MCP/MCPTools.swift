import Foundation
import GRDB

/// Implementations of the four read-only MCP tools `rti-mcp` exposes:
/// `search_corpus`, `read_meeting`, `list_meetings`, `read_live_transcript`.
///
/// Each function takes plain inputs (no JSON-RPC envelope) and returns
/// plain output, so unit tests can drive them without going through the
/// stdio dispatch layer.
struct MCPTools {
    let corpusDirectory: URL
    let liveDirectory: URL
    let dbPath: URL

    /// Lazily open + cache a read-only DB connection. The MCP binary is a
    /// short-lived process per agent invocation, so we don't bother
    /// pooling beyond this.
    private let dbWriter: DatabaseWriter?

    init(
        corpusDirectory: URL,
        liveDirectory: URL,
        dbPath: URL
    ) {
        self.corpusDirectory = corpusDirectory
        self.liveDirectory = liveDirectory
        self.dbPath = dbPath
        // Read-only: rti-mcp must never compete with the host app for the
        // single-writer SQLite lock, must never trigger schema migrations,
        // and must never corrupt the WAL on a crash.
        var config = Configuration()
        config.readonly = true
        self.dbWriter = try? DatabaseQueue(path: dbPath.path, configuration: config)
    }

    // MARK: - tool surface

    static let descriptors: [ToolListing.ToolDescriptor] = [
        .init(
            name: "search_corpus",
            description: "Full-text search across the user's meeting Corpus. Returns matching sessions with snippets.",
            inputSchema: AnyCodable([
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "default": 10],
                    "since": ["type": "string", "description": "ISO-8601 lower bound on session date."],
                    "until": ["type": "string", "description": "ISO-8601 upper bound on session date."]
                ],
                "required": ["query"]
            ])
        ),
        .init(
            name: "read_meeting",
            description: "Read a single meeting by file path or by date+slug. Returns parsed frontmatter and body.",
            inputSchema: AnyCodable([
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "date": ["type": "string"],
                    "slug": ["type": "string"]
                ]
            ])
        ),
        .init(
            name: "list_meetings",
            description: "List recent meetings (frontmatter only). Sorted newest first.",
            inputSchema: AnyCodable([
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "default": 20],
                    "since": ["type": "string"],
                    "until": ["type": "string"]
                ]
            ])
        ),
        .init(
            name: "read_live_transcript",
            description: "Read events from the in-flight session's JSONL stream. Returns empty when no session is active. Agents poll this for real-time coaching.",
            inputSchema: AnyCodable([
                "type": "object",
                "properties": [
                    "since_line": ["type": "integer", "default": 0]
                ]
            ])
        )
    ]

    // MARK: - search_corpus

    func searchCorpus(arguments: [String: Any]) -> ToolCallResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return ToolCallResult(text: "Missing required `query` argument.", isError: true)
        }
        let limit = (arguments["limit"] as? Int) ?? 10
        let since = parseISO(arguments["since"] as? String)
        let until = parseISO(arguments["until"] as? String)

        guard let db = dbWriter else {
            return ToolCallResult(text: "Could not open RTI database at \(dbPath.path)", isError: true)
        }

        do {
            // Use FTS5 if the index exists; fall back to scanning markdown
            // files when it doesn't (e.g. fresh install before any reindex).
            let indexHits = try db.read { db -> [(sessionId: String, snippet: String)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT session_id, snippet(session_search, -1, '<<', '>>', '…', 12) AS snip,
                           bm25(session_search) AS score
                    FROM session_search
                    WHERE session_search MATCH ?
                    ORDER BY score
                    LIMIT ?
                """, arguments: [query, limit * 2])
                return rows.map { (
                    sessionId: $0["session_id"] as String,
                    snippet: $0["snip"] as String
                ) }
            }
            // Resolve session ids back to corpus file paths via frontmatter id.
            let urls = (try? CorpusReader.listMarkdownFiles(in: corpusDirectory)) ?? []
            let byId: [String: (URL, CorpusEntry.Frontmatter)] = urls.reduce(into: [:]) { acc, url in
                if let fm = try? CorpusReader.readFrontmatter(url) {
                    acc[fm.id] = (url, fm)
                }
            }
            var results: [[String: Any]] = []
            var seen = Set<String>()
            for hit in indexHits {
                guard !seen.contains(hit.sessionId) else { continue }
                seen.insert(hit.sessionId)
                guard let (url, fm) = byId[hit.sessionId] else { continue }
                if let since, fm.date < since { continue }
                if let until, fm.date > until { continue }
                results.append([
                    "path": url.path,
                    "id": fm.id,
                    "date": isoString(fm.date),
                    "title": fm.title ?? "",
                    "snippet": hit.snippet
                ])
                if results.count >= limit { break }
            }
            return jsonResult(["results": results])
        } catch {
            return ToolCallResult(text: "Search failed: \(error)", isError: true)
        }
    }

    // MARK: - read_meeting

    func readMeeting(arguments: [String: Any]) -> ToolCallResult {
        let url: URL
        if let path = arguments["path"] as? String {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let dateStr = arguments["date"] as? String,
                  let slug = arguments["slug"] as? String,
                  parseISO(dateStr) != nil {
            let dateOnly = String(dateStr.prefix(10))
            // Reject slugs that contain path separators or `..` segments
            // before they reach `appendingPathComponent`.
            guard isSafeSlug(slug) else {
                return ToolCallResult(text: "Invalid slug.", isError: true)
            }
            url = corpusDirectory.appendingPathComponent("\(dateOnly)-\(slug).md")
        } else {
            return ToolCallResult(text: "Provide either `path` or both `date` and `slug`.", isError: true)
        }
        // Containment: every read must resolve under the corpus root. Without
        // this, an external agent could request `~/.ssh/id_rsa` or
        // `../../etc/passwd` via the `path` argument.
        guard isWithinCorpus(url) else {
            return ToolCallResult(text: "Path is outside the configured corpus directory.", isError: true)
        }
        do {
            let entry = try CorpusReader.read(url)
            let payload: [String: Any] = [
                "path": url.path,
                "frontmatter": frontmatterToDict(entry.frontmatter),
                "body": entry.body
            ]
            return jsonResult(payload)
        } catch {
            return ToolCallResult(text: "Could not read meeting: \(error)", isError: true)
        }
    }

    /// True iff `url` resolves inside `corpusDirectory` after symlink/`..`
    /// normalisation. Anchors the prefix on a trailing `/` so that
    /// `~/meetings-other/foo.md` cannot satisfy a `~/meetings/` containment
    /// check by string-prefix coincidence.
    private func isWithinCorpus(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = corpusDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        return resolved == root || resolved.hasPrefix(rootWithSlash)
    }

    private func isSafeSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, !slug.contains("/"), !slug.contains("\\"), slug != "..", !slug.contains("..") else {
            return false
        }
        return true
    }

    // MARK: - list_meetings

    func listMeetings(arguments: [String: Any]) -> ToolCallResult {
        let limit = (arguments["limit"] as? Int) ?? 20
        let since = parseISO(arguments["since"] as? String)
        let until = parseISO(arguments["until"] as? String)
        do {
            let urls = try CorpusReader.listMarkdownFiles(in: corpusDirectory)
            var meetings: [[String: Any]] = []
            for url in urls {
                guard let fm = try? CorpusReader.readFrontmatter(url) else { continue }
                if let since, fm.date < since { continue }
                if let until, fm.date > until { continue }
                meetings.append([
                    "path": url.path,
                    "id": fm.id,
                    "date": isoString(fm.date),
                    "title": fm.title ?? "",
                    "attendees": fm.attendees ?? [],
                    "key_topics": fm.keyTopics ?? []
                ])
                if meetings.count >= limit { break }
            }
            return jsonResult(["meetings": meetings])
        } catch {
            return ToolCallResult(text: "Could not list meetings: \(error)", isError: true)
        }
    }

    // MARK: - read_live_transcript

    func readLiveTranscript(arguments: [String: Any]) -> ToolCallResult {
        let sinceLine = (arguments["since_line"] as? Int) ?? 0
        // Find the most recently-modified JSONL file in the live directory.
        // Multiple in-flight sessions are theoretically possible (mic + system
        // were once separate writers); we pick the freshest.
        guard let active = newestLiveJSONL() else {
            return jsonResult(["session_id": NSNull(), "events": [], "next_line": 0])
        }
        do {
            let result = try LiveJSONLReader.readSince(active, sinceLine: sinceLine)
            let id = active.deletingPathExtension().lastPathComponent
            // Events as plain dicts so JSON encoding is straightforward.
            let payload: [String: Any] = [
                "session_id": id,
                "events": result.events.map(eventToDict),
                "next_line": result.nextLine
            ]
            return jsonResult(payload)
        } catch {
            return ToolCallResult(text: "Could not read live transcript: \(error)", isError: true)
        }
    }

    // MARK: - private

    private func newestLiveJSONL() -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: liveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lm > rm
            }
            .first
    }

    private func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: raw) { return d }
        // Date-only `YYYY-MM-DD`.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func jsonResult(_ payload: [String: Any]) -> ToolCallResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let str = String(data: data, encoding: .utf8) ?? "{}"
            return ToolCallResult(text: str)
        } catch {
            return ToolCallResult(text: "Failed to serialise result: \(error)", isError: true)
        }
    }

    private func frontmatterToDict(_ fm: CorpusEntry.Frontmatter) -> [String: Any] {
        var d: [String: Any] = [
            "id": fm.id,
            "date": isoString(fm.date)
        ]
        if let v = fm.capturedAt { d["captured_at"] = isoString(v) }
        if let v = fm.duration { d["duration"] = v }
        if let v = fm.title { d["title"] = v }
        if let v = fm.mode { d["mode"] = v }
        if let v = fm.attendees { d["attendees"] = v }
        if let v = fm.keyTopics { d["key_topics"] = v }
        if let v = fm.transcriptQuality { d["transcript_quality"] = v }
        if let v = fm.wavPath { d["wav_path"] = v }
        if let map = fm.speakerMap {
            d["speaker_map"] = map.mapValues { entry -> [String: String] in
                ["name": entry.name, "source": entry.source]
            }
        }
        return d
    }

    private func eventToDict(_ event: LiveJSONLWriter.Event) -> [String: Any] {
        switch event {
        case .word(let ts, let speaker, let text, let isFinal, let confidence, let channel):
            return ["t": "word", "ts": ts, "speaker": speaker, "text": text,
                    "is_final": isFinal, "confidence": confidence, "channel": channel]
        case .note(let ts, let text):
            return ["t": "note", "ts": ts, "text": text]
        case .chat(let ts, let role, let content):
            return ["t": "chat", "ts": ts, "role": role, "content": content]
        }
    }
}
