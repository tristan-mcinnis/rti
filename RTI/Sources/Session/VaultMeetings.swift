import Foundation

/// Date-sorted access to a project's meetings and sessions — the recency-aware
/// half of vault retrieval. Semantic search (`VaultSearch`) answers "what do we
/// know about X"; it ranks by relevance and has no date dimension, so it cannot
/// answer "what happened last / most recently" — the relevant-but-old doc beats
/// the recent one (verified: a "last meeting" query returns a month-old kickoff,
/// not today's session). This fills that gap: it lists the project's meetings
/// and session notes newest-first, straight off disk — local, instant, no Neon,
/// no cold-start.
enum VaultMeetings {
    struct Meeting {
        /// Sort key: `yyyymmddHHMM` parsed from the filename (HHMM = 0000 when
        /// the name carries only a date). Newest sorts highest.
        let stamp: String
        let displayDate: String   // yyyy-mm-dd
        let title: String
        let relativePath: String
        let kind: String          // "meeting" | "session"
        let excerpt: String
    }

    /// The project's meetings + session notes, newest first. `scopeRelativePath`
    /// is the project directory under `databases/` (e.g. `projects/foo`); nil
    /// returns empty — recency needs a project to scope to.
    static func recent(scopeRelativePath: String?, limit: Int = 6) -> [Meeting] {
        guard let scope = scopeRelativePath, !scope.isEmpty,
              let dbs = VaultWorkstreamStore.databasesDir() else { return [] }
        let slug = (scope as NSString).lastPathComponent
        var found: [Meeting] = []

        // 1) Meeting notes in databases/meetings linked to this project (the
        //    project slug appears in the note, normally in its `projects:` list).
        let meetingsDir = dbs.appendingPathComponent("meetings", isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: meetingsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(slug) else { continue }
                if let m = make(url: url, under: dbs, text: text, kind: "meeting") { found.append(m) }
            }
        }

        // 2) The project's own session transcript notes — the record of the
        //    meetings/sessions actually held on this project (RTI writes these).
        let notesDir = dbs.appendingPathComponent(scope, isDirectory: true)
            .appendingPathComponent("transcripts/notes", isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: notesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let m = make(url: url, under: dbs, text: text, kind: "session") { found.append(m) }
            }
        }

        return Array(found.sorted { $0.stamp > $1.stamp }.prefix(limit))
    }

    /// Format the recency list as the string the model sees.
    static func recentFormatted(scopeRelativePath: String?, limit: Int = 6) -> String {
        guard scopeRelativePath != nil else {
            return "No project is set for this meeting, so there's no project to list recent meetings for. Pick a project in Setup, or use search_vault for a topic-based lookup."
        }
        let items = recent(scopeRelativePath: scopeRelativePath, limit: limit)
        guard !items.isEmpty else {
            return "No meetings or session notes found for this project yet."
        }
        var out = "This project's most recent meetings and sessions, newest first (the latest is #1):\n"
        for (i, m) in items.enumerated() {
            out += "\n\(i + 1). \(m.title) — \(m.displayDate) (\(m.kind), \(m.relativePath))"
            if !m.excerpt.isEmpty { out += "\n   \(m.excerpt)" }
        }
        out += "\n\nThese are sorted by date. For \"the last/latest meeting\" use #1. Note a raw session note is a transcript, not a synthesised summary."
        return out
    }

    // MARK: - Helpers

    private static func make(url: URL, under base: URL, text: String, kind: String) -> Meeting? {
        guard let stamp = parseStamp(url.lastPathComponent) else { return nil }
        let rel = relativePath(of: url, under: base)
        return Meeting(
            stamp: stamp,
            displayDate: "\(stamp.prefix(4))-\(stamp.dropFirst(4).prefix(2))-\(stamp.dropFirst(6).prefix(2))",
            title: title(from: text, url: url),
            relativePath: rel,
            kind: kind,
            excerpt: excerpt(from: text)
        )
    }

    /// `yyyymmddHHMM` from a filename carrying `20YYMMDD` and an optional `-HHMM`
    /// (e.g. `rti-session-20260622-1630.md` → `202606221630`; a date-only name →
    /// `…0000`). nil when the name has no date. Pure — unit-tested.
    static func parseStamp(_ filename: String) -> String? {
        guard let dr = filename.range(of: "20[0-9]{6}", options: .regularExpression) else { return nil }
        let date = String(filename[dr])
        let rest = filename[dr.upperBound...]
        if let tr = rest.range(of: "[0-9]{4}", options: .regularExpression),
           rest[..<tr.lowerBound].allSatisfy({ !$0.isNumber }) {
            return date + String(rest[tr])
        }
        return date + "0000"
    }

    /// Frontmatter `title:`, else first `# heading`, else de-slugged filename.
    private static func title(from text: String, url: URL) -> String {
        let lines = text.components(separatedBy: .newlines)
        if lines.first == "---" {
            for line in lines.dropFirst() {
                if line == "---" { break }
                if line.lowercased().hasPrefix("title:") {
                    let v = line.dropFirst("title:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !v.isEmpty { return v }
                }
            }
        }
        if let h = lines.first(where: { $0.hasPrefix("# ") }) {
            return String(h.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
    }

    /// First substantive body line(s) after frontmatter, trimmed to a snippet.
    private static func excerpt(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines[(end + 1)...])
        }
        let body = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 12 && !$0.hasPrefix("#") && !$0.hasPrefix("---") && !$0.hasPrefix("```") }
        guard let line = body else { return "" }
        let cleaned = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        return cleaned.count > 240 ? String(cleaned.prefix(240)) + "…" : cleaned
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path + "/"
        return full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : url.lastPathComponent
    }
}
