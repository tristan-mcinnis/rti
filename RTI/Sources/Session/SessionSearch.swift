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
        let pattern = "%\(trimmed)%"

        do {
            return try RTIDatabase.shared.pool.read { db in
                // Find matching session IDs from all text sources
                let transcriptIds = try String.fetchAll(db, sql: """
                    SELECT DISTINCT session_id FROM transcript_entries
                    WHERE text LIKE ? AND is_final = 1
                    """, arguments: [pattern])

                let summaryIds = try String.fetchAll(db, sql: """
                    SELECT DISTINCT session_id FROM session_summaries
                    WHERE summary_text LIKE ? OR action_items LIKE ? OR key_topics LIKE ?
                    OR decisions LIKE ? OR follow_ups LIKE ?
                    """, arguments: [pattern, pattern, pattern, pattern, pattern])

                let chatIds = try String.fetchAll(db, sql: """
                    SELECT DISTINCT session_id FROM chat_messages
                    WHERE content LIKE ?
                    """, arguments: [pattern])

                var sessionIds = Set(transcriptIds)
                sessionIds.formUnion(summaryIds)
                sessionIds.formUnion(chatIds)

                guard !sessionIds.isEmpty else { return [] }

                // Fetch sessions
                let sessions = try Session
                    .filter(sessionIds.contains(Column("id")))
                    .order(Column("started_at").desc)
                    .limit(limit)
                    .fetchAll(db)

                // Build snippets
                return sessions.map { session in
                    let snippet = buildSnippet(db: db, sessionId: session.id, query: trimmed)
                    return SessionSearchResult(id: session.id, session: session, snippet: snippet)
                }
            }
        } catch {
            NSLog("[RTI] SessionSearch failed: \(error)")
            return []
        }
    }

    private static func buildSnippet(db: Database, sessionId: String, query: String) -> String {
        do {
            // Try transcript first
            if let text = try String.fetchOne(db, sql: """
                SELECT text FROM transcript_entries
                WHERE session_id = ? AND is_final = 1 AND text LIKE ?
                ORDER BY start_ms DESC
                LIMIT 1
                """, arguments: [sessionId, "%\(query)%"]) {
                return truncate(text, around: query)
            }
            // Then summary
            if let text = try String.fetchOne(db, sql: """
                SELECT summary_text FROM session_summaries
                WHERE session_id = ? AND summary_text LIKE ?
                LIMIT 1
                """, arguments: [sessionId, "%\(query)%"]) {
                return truncate(text, around: query)
            }
            // Then chat
            if let text = try String.fetchOne(db, sql: """
                SELECT content FROM chat_messages
                WHERE session_id = ? AND content LIKE ?
                ORDER BY created_at DESC
                LIMIT 1
                """, arguments: [sessionId, "%\(query)%"]) {
                return truncate(text, around: query)
            }
        } catch {
            NSLog("[RTI] buildSnippet failed: \(error)")
        }
        return ""
    }

    private static func truncate(_ text: String, around query: String, maxLength: Int = 140) -> String {
        let lower = text.lowercased()
        let qLower = query.lowercased()
        guard let range = lower.range(of: qLower) else { return String(text.prefix(maxLength)) }
        let start = text.index(range.lowerBound, offsetBy: 0, limitedBy: text.startIndex) ?? text.startIndex
        let prefixStart = text.index(start, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let suffixEnd = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
        var result = String(text[prefixStart..<suffixEnd])
        if prefixStart > text.startIndex { result = "…" + result }
        if suffixEnd < text.endIndex { result += "…" }
        return result
    }
}
