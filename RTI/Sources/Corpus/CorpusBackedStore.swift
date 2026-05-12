import Foundation

/// Read adapter for the markdown Corpus + in-memory active-session state.
/// All UI code that needs session data goes through here. Collapses the
/// former `CorpusCatalog` (thin read-only wrapper) and `CorpusBackedStore`
/// (read adapter) into a single module — one interface for "read the Corpus."
@MainActor
enum CorpusBackedStore {

    // MARK: - Session listing

    /// Every markdown file in the corpus, sorted newest-first by mtime.
    /// Does not include the in-flight active session.
    nonisolated static func allMarkdownSessions() -> [Session] {
        let urls = (try? CorpusReader.listMarkdownFiles(in: corpusDir)) ?? []
        var sessions: [Session] = []
        for url in urls {
            guard let fm = try? CorpusReader.readFrontmatter(url) else { continue }
            var s = Session(from: fm)
            if let secs = fm.duration.flatMap({ parseDuration($0) }) {
                s.endedAt = fm.date.addingTimeInterval(secs)
            }
            sessions.append(s)
        }
        return sessions
    }

    /// Every session known to RTI: every markdown file in the corpus,
    /// plus the in-flight session if there is one. Sorted newest-first
    /// by `startedAt`.
    static func allSessions() -> [Session] {
        var sessions = allMarkdownSessions()
        if let active = ActiveSessionProjection.currentSession(),
           !sessions.contains(where: { $0.id == active.id }) {
            sessions.insert(active, at: 0)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Find one session by id. Looks in markdown first, then falls back
    /// to active-session state.
    static func session(id: String) -> Session? {
        if let url = url(forSessionId: id),
           let fm = try? CorpusReader.readFrontmatter(url) {
            var s = Session(from: fm)
            if let secs = fm.duration.flatMap({ parseDuration($0) }) {
                s.endedAt = fm.date.addingTimeInterval(secs)
            }
            return s
        }
        if let active = ActiveSessionProjection.currentSession(), active.id == id {
            return active
        }
        return nil
    }

    /// Resolve a session id to its markdown file path. Returns nil for
    /// in-flight sessions (no file written yet) or unknown ids.
    static func markdownURL(forSessionId id: String) -> URL? {
        url(forSessionId: id)
    }

    // MARK: - Transcript

    /// Final transcript entries for a session. For a completed session,
    /// reads the markdown body's `## Transcript` section. For an active
    /// session, reads the live JSONL stream.
    nonisolated static func transcripts(forSessionId id: String) -> [TranscriptEntry] {
        if let url = url(forSessionId: id),
           let entry = try? CorpusReader.read(url) {
            return TranscriptRender.entries(from: entry.body, sessionId: id, createdAt: entry.frontmatter.date)
        }
        // Active session — read JSONL.
        let liveURL = CorpusManager.shared.liveDirectory.appendingPathComponent("\(id).jsonl")
        guard FileManager.default.fileExists(atPath: liveURL.path),
              let events = try? LiveJSONLReader.readAll(liveURL) else {
            return []
        }
        return TranscriptRender.entries(from: events, sessionId: id)
    }

    // MARK: - Summary

    /// Summary record for a session. For completed sessions reads the
    /// markdown body's `## Summary` section. For active sessions reads
    /// the in-memory cache populated by `SummaryController` if any.
    static func summary(forSessionId id: String) -> SessionSummary? {
        if let url = url(forSessionId: id),
           let entry = try? CorpusReader.read(url) {
            let summaryText = extractSummaryBody(entry.body)
            guard !summaryText.isEmpty else { return nil }
            let parsed = SummaryController.parseSections(from: summaryText)
            return SessionSummary(
                id: id,
                sessionId: id,
                summaryText: summaryText,
                actionItems: parsed["Action Items"],
                keyTopics: parsed["Key Topics"],
                decisions: parsed["Decisions Made"],
                followUps: SummaryFormatting.combineFollowUps(openQuestions: parsed["Open Questions"], nextSteps: parsed["Next Steps"]),
                rawResponse: summaryText,
                createdAt: entry.frontmatter.date,
                regeneratedAt: nil
            )
        }
        return SummaryController.shared.cachedSummary(forSessionId: id)
    }

    // MARK: - Internal lookups

    /// Resolve a session id to its markdown URL by scanning frontmatter.
    private nonisolated static func url(forSessionId id: String) -> URL? {
        let urls = (try? CorpusReader.listMarkdownFiles(in: corpusDir)) ?? []
        for url in urls {
            guard let fm = try? CorpusReader.readFrontmatter(url), fm.id == id else { continue }
            return url
        }
        return nil
    }

    private nonisolated static let corpusDir: URL = {
        if let custom = UserDefaults.standard.string(forKey: "rti.corpus.path"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("meetings", isDirectory: true)
    }()

    // MARK: - Parsing

    /// Parse a `## Transcript` section body into typed entries.
    static func parseTranscriptBody(_ body: String, sessionId: String, createdAt: Date) -> [TranscriptEntry] {
        TranscriptRender.entries(from: body, sessionId: sessionId, createdAt: createdAt)
    }

    static func extractSummaryBody(_ body: String) -> String {
        let marker = "## Transcript"
        let summaryEnd = body.range(of: marker)?.lowerBound ?? body.endIndex
        var summary = String(body[..<summaryEnd])
        if let r = summary.range(of: "## Summary") {
            summary = String(summary[r.upperBound...])
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseDuration(_ raw: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var hadAny = false
        var num = ""
        for ch in raw {
            if ch.isNumber {
                num.append(ch)
            } else if ch == "h" {
                total += (Double(num) ?? 0) * 3600
                num = ""
                hadAny = true
            } else if ch == "m" {
                total += (Double(num) ?? 0) * 60
                num = ""
                hadAny = true
            } else {
                num = ""
            }
        }
        return hadAny ? total : nil
    }
}