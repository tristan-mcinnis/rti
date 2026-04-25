import Foundation
import GRDB

struct SessionSummary: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var sessionId: String
    var summaryText: String
    var actionItems: String?
    var keyTopics: String?
    var decisions: String?
    var followUps: String?
    var rawResponse: String?
    var createdAt: Date
    var regeneratedAt: Date?

    static let databaseTableName = "session_summaries"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case summaryText = "summary_text"
        case actionItems = "action_items"
        case keyTopics = "key_topics"
        case decisions
        case followUps = "follow_ups"
        case rawResponse = "raw_response"
        case createdAt = "created_at"
        case regeneratedAt = "regenerated_at"
    }
}
