import Foundation
import GRDB

/// SQLite-sidecar table for cross-session speaker corrections. Markdown is
/// canonical and never rewritten; mutations like "rename them_1 to Alex
/// everywhere" land here. Query layer applies the overlay at result-render
/// time. This is the same pattern the minutes repo uses (their overlay is
/// keyed on pyannote ids; ours is keyed on Soniox per-call ids scoped to
/// either a session or globally to the user).
struct SpeakerOverlay: Codable, FetchableRecord, PersistableRecord {
    var speakerKey: String   // "self" | "them_1" | …
    var displayName: String
    var scope: String        // "global" | "session:<id>"
    var source: String       // "manual" | "llm" | "deterministic" | "enrollment"
    var updatedAt: Date

    static let databaseTableName = "speaker_overlays"

    enum CodingKeys: String, CodingKey {
        case speakerKey = "speaker_key"
        case displayName = "display_name"
        case scope
        case source
        case updatedAt = "updated_at"
    }
}

extension SpeakerOverlay {
    /// Resolve a speaker id for a specific session. Session-scoped overlays
    /// take precedence over global ones; if neither exists, returns nil.
    static func resolve(
        speakerKey: String,
        sessionId: String,
        in db: Database
    ) throws -> SpeakerOverlay? {
        if let session = try SpeakerOverlay
            .filter(Column("speaker_key") == speakerKey)
            .filter(Column("scope") == "session:\(sessionId)")
            .fetchOne(db) {
            return session
        }
        return try SpeakerOverlay
            .filter(Column("speaker_key") == speakerKey)
            .filter(Column("scope") == "global")
            .fetchOne(db)
    }
}
