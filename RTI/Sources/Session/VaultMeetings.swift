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
        /// A real content blurb — the Overview / summary / key-points text, not
        /// the file's meta-preamble. Generous (up to ~1600 chars) so the most
        /// recent meeting can be answered inline without a second lookup.
        let summary: String
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
            // The most recent meeting gets its full summary so "what did we
            // discuss last time" is answerable from this one call; the rest get
            // a short preview (read_document on its path for the full content).
            if !m.summary.isEmpty {
                let blurb = i == 0 ? m.summary : (m.summary.count > 240 ? String(m.summary.prefix(240)) + "…" : m.summary)
                out += "\n   \(blurb)"
            }
        }
        out += "\n\nSorted by date — for \"the last/latest meeting\" use #1. For the full content of any entry, call read_document with its path."
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
            summary: summary(from: text, maxChars: 1600)
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

    /// A real content blurb — not the file's meta-preamble. Prefers the text
    /// under an Overview / Summary / Key-points / Takeaway heading (where the
    /// auto-generated meeting summary lives), skipping headings, fences, and the
    /// "use this as signal / analyze the transcript" disclaimer lines that open a
    /// field-notes file. Concatenated up to `maxChars`. Exposed for testing.
    static func summary(from text: String, maxChars: Int) -> String {
        var lines = text.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines[(end + 1)...])
        }
        let metaCues = ["hypothesis layer", "evidence layer", "use this as signal",
                        "auto-generated", "generated notes", "the assistant's live flags"]
        func isMeta(_ s: String) -> Bool { let lo = s.lowercased(); return metaCues.contains { lo.contains($0) } }

        // Jump to the first summary-ish section heading, if any.
        var start = 0
        for (i, l) in lines.enumerated() where l.hasPrefix("#") {
            let lo = l.lowercased()
            if lo.contains("overview") || lo.contains("summary") || lo.contains("key point") || lo.contains("takeaway") {
                start = i + 1
                break
            }
        }
        var out = ""
        for raw in lines[start...] {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("```") || t == "---" || isMeta(t) { continue }
            let clean = t.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard clean.count >= 4 else { continue }
            out += (out.isEmpty ? "" : " ") + clean
            if out.count >= maxChars { break }
        }
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…" : out
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let full = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path + "/"
        return full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)) : url.lastPathComponent
    }
}
