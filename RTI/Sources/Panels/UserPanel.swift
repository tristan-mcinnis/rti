import Foundation
import GRDB

/// In-memory representation of one configured panel. Translates to/from
/// `UserPanelRow` for persistence; carries a strongly-typed `PanelConfig`
/// for the renderer so widget views don't reparse JSON on every redraw.
struct UserPanel: Identifiable, Equatable {
    let id: String
    let kind: PanelKind
    var config: PanelConfig
    let createdAt: Date

    /// Human-friendly title pulled from the appropriate config field.
    /// Used in window titles, the panel manager list, and the right-click
    /// menu so we never show a raw uuid to the user.
    var displayTitle: String {
        switch kind {
        case .counter:
            return config.counter?.label ?? "Counter"
        case .periodicCards:
            return config.periodicCards?.label ?? "Panel"
        }
    }
}

/// GRDB row backing `UserPanel`. The whole `PanelConfig` is serialised to
/// a `config_json` TEXT column so we can grow widget configs without a
/// per-field migration.
struct UserPanelRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var kind: String
    var configJSON: String
    var createdAt: Date

    static let databaseTableName = "user_panels"

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case configJSON = "config_json"
        case createdAt = "created_at"
    }
}

extension UserPanel {
    /// Try to materialise a row into a domain object. Returns nil when the
    /// stored kind or JSON shape can't be decoded — caller should drop
    /// invalid rows rather than crash so a single bad spawn can't render
    /// the app unstartable.
    init?(row: UserPanelRow) {
        guard let kind = PanelKind(rawValue: row.kind) else { return nil }
        guard let data = row.configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(PanelConfig.self, from: data) else {
            return nil
        }
        self.id = row.id
        self.kind = kind
        self.config = config
        self.createdAt = row.createdAt
    }

    func toRow() throws -> UserPanelRow {
        let data = try JSONEncoder().encode(config)
        return UserPanelRow(
            id: id,
            kind: kind.rawValue,
            configJSON: String(data: data, encoding: .utf8) ?? "{}",
            createdAt: createdAt
        )
    }
}

/// Periodic-cards artefacts. One row per generated card, keyed by panel.
/// Lifecycle matches the existing `generated_notes` table — derived data
/// off the canonical transcript that we cache so the user can re-read
/// and export across sessions.
struct UserPanelCardRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var panelId: String
    var sessionId: String
    var content: String
    var createdAt: Date

    static let databaseTableName = "user_panel_cards"

    enum CodingKeys: String, CodingKey {
        case id
        case panelId = "panel_id"
        case sessionId = "session_id"
        case content
        case createdAt = "created_at"
    }
}
