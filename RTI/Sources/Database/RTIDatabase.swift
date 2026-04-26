import AppKit
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
            NSLog("[RTI] RTIDatabase init failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "RTI couldn't open its database"
            alert.informativeText = """
            \(error)

            RTI will quit. If this persists, remove the database file at:
            ~/Library/Application Support/RTI/rti.db
            (this will erase your session history).
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            // NSApp.terminate is async; block here so callers don't see a phantom value.
            // The terminate will fire on the next runloop tick.
            Thread.sleep(forTimeInterval: 60)
            fatalError("RTIDatabase unrecoverable")
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
        // Wait up to 5s on a locked DB before throwing instead of failing
        // immediately. The menubar opening (rebuildRecentSessionsSubmenu) and
        // the live transcript writer can briefly contend during a session.
        var config = Configuration()
        config.busyMode = .timeout(5)
        self.pool = try DatabasePool(path: dbURL.path, configuration: config)

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
        m.registerMigration("v2_chat_and_modes") { db in
            try db.create(table: "chat_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().references("sessions", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("action", .text)
                t.column("content", .text).notNull()
                t.column("had_screen_context", .integer).notNull().defaults(to: 0)
                t.column("had_transcript_context", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(
                index: "idx_chat_session_time",
                on: "chat_messages",
                columns: ["session_id", "created_at"]
            )

            try db.create(table: "modes") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("system_prompt", .text).notNull()
                t.column("is_builtin", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
            }
        }
        m.registerMigration("v3_mode_reference_text") { db in
            try db.alter(table: "modes") { t in
                t.add(column: "reference_text", .text)
            }
        }
        m.registerMigration("v4_session_summaries") { db in
            try db.create(table: "session_summaries") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().unique().references("sessions", onDelete: .cascade)
                t.column("summary_text", .text).notNull()
                t.column("action_items", .text)
                t.column("key_topics", .text)
                t.column("decisions", .text)
                t.column("follow_ups", .text)
                t.column("raw_response", .text)
                t.column("created_at", .datetime).notNull()
                t.column("regenerated_at", .datetime)
            }
        }
        m.registerMigration("v5_session_mode_and_calendar") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "mode_id", .text)
                t.add(column: "calendar_event_id", .text)
                t.add(column: "calendar_title", .text)
            }
        }
        m.registerMigration("v6_session_title") { db in
            try db.alter(table: "sessions") { t in
                t.add(column: "title", .text)
            }
        }
        return m
    }
}
