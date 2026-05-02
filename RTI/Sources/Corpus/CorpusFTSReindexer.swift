import Foundation
import GRDB

/// Walks a Corpus directory and populates the `session_search` FTS5 index
/// from markdown files. The index is derivable from `~/meetings/`; deleting
/// `rti.db` and rebuilding loses no Corpus data.
///
/// Designed to run on app launch (background, low priority) and after each
/// session-end markdown write. File-watcher integration is left to the
/// caller; this module is purely the rebuild logic.
enum CorpusFTSReindexer {

    /// Rebuild the FTS index from a corpus directory. Wipes the
    /// `kind='transcript'` and `kind='summary'` rows (because they came
    /// from the old SQLite tables which no longer exist post-migration)
    /// and re-inserts from markdown.
    ///
    /// Chat messages remain in SQLite and are *not* touched by this method
    /// — they're indexed via existing GRDB triggers.
    static func reindex(
        from directory: URL,
        in dbWriter: DatabaseWriter
    ) throws {
        let urls = (try? CorpusReader.listMarkdownFiles(in: directory)) ?? []
        try dbWriter.write { db in
            try db.execute(sql: """
                DELETE FROM session_search WHERE kind IN ('transcript', 'summary')
            """)
            for url in urls {
                guard let entry = try? CorpusReader.read(url) else { continue }
                let id = entry.frontmatter.id
                let body = entry.body
                let (summary, transcript) = splitBody(body)
                if !summary.isEmpty {
                    try db.execute(sql: """
                        INSERT INTO session_search(session_id, kind, row_id, text)
                        VALUES (?, 'summary', ?, ?)
                    """, arguments: [id, id, summary])
                }
                if !transcript.isEmpty {
                    try db.execute(sql: """
                        INSERT INTO session_search(session_id, kind, row_id, text)
                        VALUES (?, 'transcript', ?, ?)
                    """, arguments: [id, id, transcript])
                }
            }
        }
    }

    /// Split a body string at the `## Transcript` heading. Everything before
    /// is summary content; everything after is transcript text.
    static func splitBody(_ body: String) -> (summary: String, transcript: String) {
        let marker = "## Transcript"
        guard let range = body.range(of: marker) else {
            return (body, "")
        }
        let summary = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptStart = body.index(range.upperBound, offsetBy: 0)
        let transcript = String(body[transcriptStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, transcript)
    }
}
