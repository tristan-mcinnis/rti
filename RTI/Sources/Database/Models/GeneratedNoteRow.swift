import Foundation
import GRDB

/// Persistence shape for `GeneratedNote`. Stored under `generated_notes`,
/// keyed by session id (text — the same key the markdown corpus uses).
/// Unlike chat messages there's no FK because the canonical sessions table
/// was dropped in v11; this is a derived index.
struct GeneratedNoteRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var sessionId: String
    var rangeStartMs: Int
    var rangeEndMs: Int
    var content: String
    var createdAt: Date

    static let databaseTableName = "generated_notes"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case rangeStartMs = "range_start_ms"
        case rangeEndMs = "range_end_ms"
        case content
        case createdAt = "created_at"
    }
}
