import Foundation

/// Read-side adapter that produces the legacy `Session` / `TranscriptEntry`
/// / `SessionSummary` value types from the markdown Corpus + in-memory
/// active-session state. All UI code that previously hit SQLite for
/// session data goes through here instead.
@MainActor
enum CorpusBackedStore {

    /// Every session known to RTI: every markdown file in the corpus,
    /// plus the in-flight session if there is one. Sorted newest-first
    /// by `startedAt`.
    static func allSessions() -> [Session] {
        var sessions = CorpusCatalog.allMarkdownSessions()
        // Active session: synthesise a Session row from the in-memory
        // coordinator state if no markdown exists yet for it.
        if let active = ActiveSessionProjection.currentSession(),
           !sessions.contains(where: { $0.id == active.id }) {
            sessions.insert(active, at: 0)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Find one session by id. Looks in markdown first, then falls back
    /// to active-session state.
    static func session(id: String) -> Session? {
        if let md = CorpusCatalog.markdownSession(id: id) {
            return md
        }
        if let active = ActiveSessionProjection.currentSession(), active.id == id {
            return active
        }
        return nil
    }

    /// Resolve a session id to its markdown file path. Returns nil for
    /// in-flight sessions (no file written yet) or unknown ids.
    static func markdownURL(forSessionId id: String) -> URL? {
        CorpusCatalog.url(forSessionId: id)
    }

    /// Final transcript entries for a session. For a completed session,
    /// reads the markdown body's `## Transcript` section. For an active
    /// session, reads the live JSONL stream.
    static func transcripts(forSessionId id: String) -> [TranscriptEntry] {
        if let url = CorpusCatalog.url(forSessionId: id),
           let entry = try? CorpusCatalog.read(url) {
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

    /// Summary record for a session. For completed sessions reads the
    /// markdown body's `## Summary` section. For active sessions reads
    /// the in-memory cache populated by `SummaryController` if any.
    static func summary(forSessionId id: String) -> SessionSummary? {
        if let url = CorpusCatalog.url(forSessionId: id),
           let entry = try? CorpusCatalog.read(url) {
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

    // MARK: - parsing

    /// Parse a `## Transcript` section body into typed entries.
    /// Delegates to `TranscriptRender` so the format contract is centralised.
    static func parseTranscriptBody(_ body: String, sessionId: String, createdAt: Date) -> [TranscriptEntry] {
        TranscriptRender.entries(from: body, sessionId: sessionId, createdAt: createdAt)
    }

    static func extractSummaryBody(_ body: String) -> String {
        let marker = "## Transcript"
        let summaryEnd = body.range(of: marker)?.lowerBound ?? body.endIndex
        var summary = String(body[..<summaryEnd])
        // Strip a leading "## Summary" heading if present so callers get
        // the same shape SummaryController emits.
        if let r = summary.range(of: "## Summary") {
            summary = String(summary[r.upperBound...])
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
