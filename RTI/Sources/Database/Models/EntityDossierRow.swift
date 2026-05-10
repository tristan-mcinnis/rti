import Foundation
import GRDB

/// Persistence shape for `EntityDossier`. Stored under `entity_dossiers`,
/// uniqued by `(session_id, name_normalized)` so re-running generation for
/// the same entity upserts the description in place rather than creating
/// duplicates.
struct EntityDossierRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var sessionId: String
    var name: String
    var nameNormalized: String
    var type: String         // person | brand | organization | concept
    var description: String
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "entity_dossiers"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case name
        case nameNormalized = "name_normalized"
        case type
        case description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
