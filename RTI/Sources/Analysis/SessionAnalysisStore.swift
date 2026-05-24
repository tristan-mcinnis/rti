import Foundation
import GRDB

/// Read/write seam for analysis records keyed by `session_id`. Owns the
/// GRDB pool access and failure-logging that the analysis controllers
/// (Notes, Dossiers, Themes, Discussion Guide) each hand-rolled once.
/// Generic over any GRDB record whose table has a `session_id` column.
///
/// Reads return nil/[] on failure: analysis state is a derived index, so a
/// missing row just means "no analysis yet." Writes log and swallow — a
/// failed persist must never crash a live session. `category` is the
/// `RTILog` category so a failure still names the analyzer that hit it.
enum SessionAnalysisStore {
    private static let sessionColumn = Column("session_id")

    /// The single row for a session, or nil. For tables with one row per
    /// session (themes, discussion guides).
    static func loadOne<Row: FetchableRecord & TableRecord>(
        _ type: Row.Type,
        sessionId: String,
        category: String
    ) -> Row? {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try Row.filter(sessionColumn == sessionId).fetchOne(db)
            }
        } catch {
            RTILog.log("SessionAnalysisStore load \(Row.databaseTableName) failed: \(error)", category: category)
            return nil
        }
    }

    /// Every row for a session, ordered by `created_at` ascending. For
    /// tables with many rows per session (notes, dossiers).
    static func loadAll<Row: FetchableRecord & TableRecord>(
        _ type: Row.Type,
        sessionId: String,
        category: String
    ) -> [Row] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try Row.filter(sessionColumn == sessionId)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
        } catch {
            RTILog.log("SessionAnalysisStore loadAll \(Row.databaseTableName) failed: \(error)", category: category)
            return []
        }
    }

    /// Upsert a row (`save` — insert, or update on primary-key conflict).
    static func save<Row: PersistableRecord>(_ row: Row, category: String) {
        do {
            try RTIDatabase.shared.pool.write { db in try row.save(db) }
        } catch {
            RTILog.log("SessionAnalysisStore save \(Row.databaseTableName) failed: \(error)", category: category)
        }
    }

    /// Insert a new row with no conflict resolution — for append-only
    /// tables (notes).
    static func insert<Row: PersistableRecord>(_ row: Row, category: String) {
        do {
            try RTIDatabase.shared.pool.write { db in try row.insert(db) }
        } catch {
            RTILog.log("SessionAnalysisStore insert \(Row.databaseTableName) failed: \(error)", category: category)
        }
    }

    /// Delete the row whose primary key is `sessionId`. For one-row-per-
    /// session tables keyed on `session_id` (discussion guides).
    static func deleteOne<Row: PersistableRecord>(
        _ type: Row.Type,
        sessionId: String,
        category: String
    ) {
        do {
            _ = try RTIDatabase.shared.pool.write { db in
                try Row.deleteOne(db, key: sessionId)
            }
        } catch {
            RTILog.log("SessionAnalysisStore delete \(Row.databaseTableName) failed: \(error)", category: category)
        }
    }
}
