import Foundation
import GRDB
import Observation

/// Singleton catalogue of user-spawned panels. Owns persistence and the
/// SwiftUI-observable list of panels currently configured. Views observe
/// `panels` to add/remove their hosting NSPanel windows; the store does
/// not own the windows themselves — that's `WindowCoordinator`'s job.
@Observable @MainActor
final class UserPanelStore {
    static let shared = UserPanelStore()

    private(set) var panels: [UserPanel] = []

    private init() { panels = Self.loadAll() }

    /// Add a fresh panel. Persists immediately so a crash mid-session
    /// doesn't lose the user's configuration.
    func add(_ panel: UserPanel) {
        do {
            let row = try panel.toRow()
            try RTIDatabase.shared.pool.write { db in try row.insert(db) }
            panels.append(panel)
        } catch {
            NSLog("[RTI] UserPanelStore add failed: \(error)")
        }
    }

    /// Wipe every user panel and its cached cards. Used by the
    /// "Clear Current Chat" action since user panels are products of the
    /// chat session (spawned via the `spawn_panel` tool).
    func removeAll() {
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try UserPanelRow.deleteAll(db)
                try db.execute(sql: "DELETE FROM user_panel_cards")
            }
            panels.removeAll()
        } catch {
            NSLog("[RTI] UserPanelStore removeAll failed: \(error)")
        }
    }

    func remove(id: String) {
        do {
            try RTIDatabase.shared.pool.write { db in
                _ = try UserPanelRow.deleteOne(db, id: id)
                // Also drop cached cards for this panel so we don't pile
                // up orphan rows across the user's life with the app.
                try db.execute(sql: "DELETE FROM user_panel_cards WHERE panel_id = ?", arguments: [id])
            }
            panels.removeAll { $0.id == id }
        } catch {
            NSLog("[RTI] UserPanelStore remove failed: \(error)")
        }
    }

    /// Update an existing panel's config in place. Used by rename/edit
    /// from the right-click menu so we don't re-spawn the window.
    func update(_ panel: UserPanel) {
        do {
            let row = try panel.toRow()
            try RTIDatabase.shared.pool.write { db in try row.update(db) }
            if let idx = panels.firstIndex(where: { $0.id == panel.id }) {
                panels[idx] = panel
            }
        } catch {
            NSLog("[RTI] UserPanelStore update failed: \(error)")
        }
    }

    private static func loadAll() -> [UserPanel] {
        do {
            let rows = try RTIDatabase.shared.pool.read { db in
                try UserPanelRow
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            return rows.compactMap(UserPanel.init(row:))
        } catch {
            NSLog("[RTI] UserPanelStore load failed: \(error)")
            return []
        }
    }

    // MARK: - Cards (periodic_cards artifacts)

    /// Append a generated card for a periodic-cards panel within a session.
    func appendCard(panelId: String, sessionId: String, content: String) {
        let row = UserPanelCardRow(
            id: UUID().uuidString,
            panelId: panelId,
            sessionId: sessionId,
            content: content,
            createdAt: Date()
        )
        do {
            try RTIDatabase.shared.pool.write { db in try row.insert(db) }
        } catch {
            NSLog("[RTI] UserPanelStore appendCard failed: \(error)")
        }
    }

    /// Read every card a panel has produced for a session, oldest first.
    /// Called by `PeriodicCardsController.reset(for:)` and by the chat
    /// `spawn_panel` follow-ups.
    nonisolated static func cards(forPanelId panelId: String, sessionId: String) -> [UserPanelCardRow] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try UserPanelCardRow
                    .filter(Column("panel_id") == panelId)
                    .filter(Column("session_id") == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        } catch {
            NSLog("[RTI] UserPanelStore cards load failed: \(error)")
            return []
        }
    }
}
