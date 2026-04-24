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
}
