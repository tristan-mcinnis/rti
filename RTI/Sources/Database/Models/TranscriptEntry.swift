import Foundation
import GRDB

struct TranscriptEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var sessionId: String
    var speakerId: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double
    var isFinal: Bool
    var createdAt: Date

    static let databaseTableName = "transcript_entries"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case speakerId = "speaker_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case confidence
        case isFinal = "is_final"
        case createdAt = "created_at"
    }
}
