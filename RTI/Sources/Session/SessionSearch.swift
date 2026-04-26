import Foundation
import GRDB

struct SessionSearchResult: Identifiable {
    let id: String
    let session: Session
    let snippet: String
}

enum SessionSearch {
    static func search(query: String, limit: Int = 50) -> [SessionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = makeFTSQuery(from: trimmed)

        do {
            return try RTIDatabase.shared.pool.read { db in
                // FTS5 ranks by bm25 (lower = better). Pull matched rows with a
                // pre-built snippet from the FTS engine itself.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT session_id,
                           snippet(session_search, 3, '«', '»', '…', 12) AS snip,
                           bm25(session_search) AS rank
                    FROM session_search
                    WHERE session_search MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """, arguments: [ftsQuery, limit * 4])

                // Collapse to one row per session, keeping the best-ranked snippet.
                var bestSnippetBySession: [String: String] = [:]
                var orderedSessionIds: [String] = []
                for row in rows {
                    guard let sessionId: String = row["session_id"] else { continue }
                    if bestSnippetBySession[sessionId] == nil {
                        bestSnippetBySession[sessionId] = (row["snip"] as String?) ?? ""
                        orderedSessionIds.append(sessionId)
                    }
                    if orderedSessionIds.count >= limit { break }
                }
                guard !orderedSessionIds.isEmpty else { return [] }

                let sessions = try Session
                    .filter(orderedSessionIds.contains(Column("id")))
                    .fetchAll(db)
                let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

                return orderedSessionIds.compactMap { id in
                    guard let session = byId[id] else { return nil }
                    let snip = bestSnippetBySession[id] ?? ""
                    return SessionSearchResult(id: id, session: session, snippet: snip)
                }
            }
        } catch {
            NSLog("[RTI] SessionSearch failed: \(error)")
            return []
        }
    }

    /// Map a free-text query into FTS5 syntax. Splits on whitespace, escapes
    /// each token with surrounding quotes, and appends `*` for prefix matches.
    /// All tokens AND together so "open question" matches rows containing both.
    private static func makeFTSQuery(from raw: String) -> String {
        let tokens = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "\"\(raw)\"" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

}
