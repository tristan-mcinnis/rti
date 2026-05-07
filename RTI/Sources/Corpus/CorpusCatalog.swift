import Foundation

/// Read-only file I/O for the markdown Corpus. Lists files, reads entries,
/// and resolves session ids to URLs. No parsing beyond frontmatter — the
/// caller decides what to do with the `CorpusEntry`.
@MainActor
enum CorpusCatalog {

    /// Every markdown file in the corpus, sorted newest-first by mtime.
    static func listFiles() -> [URL] {
        let dir = CorpusManager.shared.corpusDirectory
        return (try? CorpusReader.listMarkdownFiles(in: dir)) ?? []
    }

    /// Read a single corpus entry from disk.
    static func read(_ url: URL) throws -> CorpusEntry {
        try CorpusReader.read(url)
    }

    /// Frontmatter-only read for list views.
    static func readFrontmatter(_ url: URL) throws -> CorpusEntry.Frontmatter {
        try CorpusReader.readFrontmatter(url)
    }

    /// Resolve a session id to its markdown file path.
    static func url(forSessionId id: String) -> URL? {
        for url in listFiles() {
            guard let fm = try? readFrontmatter(url), fm.id == id else { continue }
            return url
        }
        return nil
    }

    /// All sessions parsed from markdown files.
    static func allMarkdownSessions() -> [Session] {
        var sessions: [Session] = []
        for url in listFiles() {
            guard let fm = try? readFrontmatter(url) else { continue }
            var s = Session(from: fm)
            if let durationStr = fm.duration,
               let secs = parseDuration(durationStr) {
                s.endedAt = fm.date.addingTimeInterval(secs)
            }
            sessions.append(s)
        }
        return sessions
    }

    /// Find one session by id in the markdown corpus.
    static func markdownSession(id: String) -> Session? {
        guard let url = url(forSessionId: id),
              let fm = try? readFrontmatter(url) else { return nil }
        var s = Session(from: fm)
        if let secs = fm.duration.flatMap(parseDuration) {
            s.endedAt = fm.date.addingTimeInterval(secs)
        }
        return s
    }

    // MARK: - private

    private static func parseDuration(_ raw: String) -> TimeInterval? {
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
