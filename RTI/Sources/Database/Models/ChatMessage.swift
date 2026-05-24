import Foundation
import GRDB

struct ChatMessage: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var sessionId: String
    var role: String              // "user" | "assistant" | "system"
    var action: String?           // "Ask" | "Assist" — user only
    var content: String
    var hadScreenContext: Bool
    var hadTranscriptContext: Bool
    var createdAt: Date

    static let databaseTableName = "chat_messages"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case role
        case action
        case content
        case hadScreenContext = "had_screen_context"
        case hadTranscriptContext = "had_transcript_context"
        case createdAt = "created_at"
    }

    /// Every chat message for a session, oldest first. The interaction log
    /// stays in SQLite (it isn't meeting knowledge), so reads go through
    /// here rather than each call site — including SwiftUI views — hand-
    /// rolling the query and knowing the column names.
    static func forSession(_ sessionId: String) -> [ChatMessage] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try ChatMessage
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        } catch {
            RTILog.log("ChatMessage.forSession failed: \(error)", category: "chat")
            return []
        }
    }
}
