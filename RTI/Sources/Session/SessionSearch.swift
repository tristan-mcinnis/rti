import Foundation
import GRDB

enum SessionSearch {
    static func search(query: String, limit: Int = 50) -> [SessionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = makeFTSQuery(from: trimmed)

        let bestSnippetBySession: [String: String]
        let orderedSessionIds: [String]
        do {
            (bestSnippetBySession, orderedSessionIds) = try RTIDatabase.shared.pool.read { db in
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

                var bestSnippet: [String: String] = [:]
                var ordered: [String] = []
                for row in rows {
                    guard let sessionId: String = row["session_id"] else { continue }
                    if bestSnippet[sessionId] == nil {
                        bestSnippet[sessionId] = (row["snip"] as String?) ?? ""
                        ordered.append(sessionId)
                    }
                    if ordered.count >= limit { break }
                }
                return (bestSnippet, ordered)
            }
        } catch {
            NSLog("[RTI] SessionSearch failed: \(error)")
            return []
        }

        // Resolve session ids to Session structs via the markdown corpus.
        // Build a lookup once to avoid O(N × M) directory scans.
        let sessionById = Dictionary(
            uniqueKeysWithValues: CorpusBackedStore.allMarkdownSessions().map { ($0.id, $0) }
        )
        return orderedSessionIds.compactMap { id in
            guard let session = sessionById[id] else { return nil }
            let snip = bestSnippetBySession[id] ?? ""
            return SessionSearchResult(id: id, session: session, snippet: snip)
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
