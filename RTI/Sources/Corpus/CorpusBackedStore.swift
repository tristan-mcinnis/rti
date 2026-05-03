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
        let dir = CorpusManager.shared.corpusDirectory
        var sessions: [Session] = []
        if let urls = try? CorpusReader.listMarkdownFiles(in: dir) {
            for url in urls {
                guard let fm = try? CorpusReader.readFrontmatter(url) else { continue }
                var s = Session(from: fm)
                // The frontmatter has a `duration` string but no precise
                // `endedAt` — derive from start + duration if we want
                // sortable durations later. For now leave nil; UI shows
                // the duration text from frontmatter when present.
                if let durationStr = fm.duration,
                   let secs = parseDuration(durationStr) {
                    s.endedAt = fm.date.addingTimeInterval(secs)
                }
                sessions.append(s)
            }
        }
        // Active session: synthesise a Session row from the in-memory
        // coordinator state if no markdown exists yet for it.
        if let active = activeSession(),
           !sessions.contains(where: { $0.id == active.id }) {
            sessions.insert(active, at: 0)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Find one session by id. Looks in markdown first, then falls back
    /// to active-session state.
    static func session(id: String) -> Session? {
        if let url = markdownURL(forSessionId: id),
           let fm = try? CorpusReader.readFrontmatter(url) {
            var s = Session(from: fm)
            if let secs = fm.duration.flatMap(parseDuration) {
                s.endedAt = fm.date.addingTimeInterval(secs)
            }
            return s
        }
        if let active = activeSession(), active.id == id {
            return active
        }
        return nil
    }

    /// Resolve a session id to its markdown file path. Returns nil for
    /// in-flight sessions (no file written yet) or unknown ids.
    static func markdownURL(forSessionId id: String) -> URL? {
        let dir = CorpusManager.shared.corpusDirectory
        guard let urls = try? CorpusReader.listMarkdownFiles(in: dir) else { return nil }
        for url in urls {
            if let fm = try? CorpusReader.readFrontmatter(url), fm.id == id {
                return url
            }
        }
        return nil
    }

    /// Final transcript entries for a session. For a completed session,
    /// reads the markdown body's `## Transcript` section. For an active
    /// session, reads the live JSONL stream.
    static func transcripts(forSessionId id: String) -> [TranscriptEntry] {
        if let url = markdownURL(forSessionId: id),
           let entry = try? CorpusReader.read(url) {
            return parseTranscriptBody(entry.body, sessionId: id, createdAt: entry.frontmatter.date)
        }
        // Active session — read JSONL.
        let liveURL = CorpusManager.shared.liveDirectory.appendingPathComponent("\(id).jsonl")
        guard FileManager.default.fileExists(atPath: liveURL.path),
              let events = try? LiveJSONLReader.readAll(liveURL) else {
            return []
        }
        return jsonlToTranscriptEntries(events, sessionId: id)
    }

    /// Summary record for a session. For completed sessions reads the
    /// markdown body's `## Summary` section. For active sessions reads
    /// the in-memory cache populated by `SummaryController` if any.
    static func summary(forSessionId id: String) -> SessionSummary? {
        if let url = markdownURL(forSessionId: id),
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
                followUps: combineFollowUps(open: parsed["Open Questions"], next: parsed["Next Steps"]),
                rawResponse: summaryText,
                createdAt: entry.frontmatter.date,
                regeneratedAt: nil
            )
        }
        return SummaryController.shared.cachedSummary(forSessionId: id)
    }

    // MARK: - parsing

    /// Parse a `## Transcript` section body into typed entries. Lines of
    /// the form `[speaker m:ss] text` produce one entry each. Anything
    /// before the `## Transcript` heading is ignored.
    static func parseTranscriptBody(_ body: String, sessionId: String, createdAt: Date) -> [TranscriptEntry] {
        let marker = "## Transcript"
        let transcript: String
        if let r = body.range(of: marker) {
            transcript = String(body[r.upperBound...])
        } else {
            transcript = ""
        }
        var entries: [TranscriptEntry] = []
        for line in transcript.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            // `[speaker m:ss] text` or `[speaker h:mm:ss] text`
            guard let close = trimmed.firstIndex(of: "]") else { continue }
            let header = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let speaker = String(parts[0])
            let stamp = String(parts[1])
            let startMs = parseTimestamp(stamp)
            entries.append(TranscriptEntry(
                id: UUID().uuidString,
                sessionId: sessionId,
                speakerId: speaker == "note" ? "note" : speaker,
                startMs: startMs,
                endMs: startMs,
                text: rest,
                confidence: 1.0,
                isFinal: true,
                createdAt: createdAt
            ))
        }
        return entries
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

    // MARK: - private

    private static func activeSession() -> Session? {
        guard let id = SessionCoordinator.shared.currentSessionId,
              let startedAt = SessionCoordinator.shared.startedAt else {
            return nil
        }
        return Session(
            id: id,
            startedAt: startedAt,
            endedAt: SessionCoordinator.shared.endedAt,
            wavPath: nil,
            notes: nil,
            title: nil,
            modeId: nil,
            calendarEventId: nil,
            calendarTitle: nil,
            transcriptQuality: nil
        )
    }

    private static func parseDuration(_ raw: String) -> TimeInterval? {
        // `42m` or `1h 5m` or `2h`. Just enough to produce an `endedAt`
        // for sort ordering.
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

    private static func parseTimestamp(_ stamp: String) -> Int {
        // `m:ss` or `h:mm:ss`. Returns milliseconds.
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return (parts[0] * 60 + parts[1]) * 1000
        case 3: return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        default: return 0
        }
    }

    private static func combineFollowUps(open: String?, next: String?) -> String? {
        var parts: [String] = []
        if let o = open, o != "None.", !o.isEmpty { parts.append("## Open Questions\n\(o)") }
        if let n = next, n != "None.", !n.isEmpty { parts.append("## Next Steps\n\(n)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func jsonlToTranscriptEntries(
        _ events: [LiveJSONLWriter.Event],
        sessionId: String
    ) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        for event in events {
            switch event {
            case .word(let ts, let speaker, let text, let isFinal, let confidence, let channel):
                guard isFinal else { continue }
                let label = SpeakerLabelMapping.rawLabel(speaker: speaker, channel: channel)
                out.append(TranscriptEntry(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    speakerId: label,
                    startMs: ts,
                    endMs: ts,
                    text: text,
                    confidence: confidence,
                    isFinal: true,
                    createdAt: Date()
                ))
            case .note(let ts, let text):
                out.append(TranscriptEntry(
                    id: UUID().uuidString,
                    sessionId: sessionId,
                    speakerId: "note",
                    startMs: ts,
                    endMs: ts,
                    text: text,
                    confidence: 1.0,
                    isFinal: true,
                    createdAt: Date()
                ))
            case .chat:
                continue   // chat is in a separate table; not a transcript line
            }
        }
        return out
    }
}
