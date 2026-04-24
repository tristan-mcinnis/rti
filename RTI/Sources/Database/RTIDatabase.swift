import Foundation
import GRDB

enum RTIDatabaseError: Error {
    case unableToResolveSupportDirectory
}

final class RTIDatabase {
    static let shared: RTIDatabase = {
        do {
            return try RTIDatabase()
        } catch {
            fatalError("RTIDatabase init failed: \(error)")
        }
    }()

    let pool: DatabasePool

    private init() throws {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RTIDatabaseError.unableToResolveSupportDirectory
        }
        let rtiDir = appSupport.appendingPathComponent("RTI", isDirectory: true)
        try fm.createDirectory(at: rtiDir, withIntermediateDirectories: true)

        let dbURL = rtiDir.appendingPathComponent("rti.db")
        self.pool = try DatabasePool(path: dbURL.path)

        try Self.migrator().migrate(pool)
    }

    private static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("wav_path", .text)
                t.column("notes", .text)
            }
            try db.create(table: "transcript_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("sessions", onDelete: .cascade)
                t.column("speaker_id", .text).notNull()
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("is_final", .integer).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_transcript_session_time",
                on: "transcript_entries",
                columns: ["session_id", "start_ms"]
            )
        }
        return m
    }
}
