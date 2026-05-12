import Combine
import Foundation
import GRDB

/// A user-defined grouping of sessions with shared instructions. Lives
/// in between per-session Q&A and full-corpus Q&A: chat and analysis
/// inside a project see only the project's member sessions and apply
/// the user's project-specific system prompt.

struct Project: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var instructions: String
    var createdAt: Date
    var archivedAt: Date?
}

struct ProjectRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"

    var id: String
    var name: String
    var instructions: String
    var createdAt: Date
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, instructions
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }

    func toProject() -> Project {
        Project(id: id, name: name, instructions: instructions, createdAt: createdAt, archivedAt: archivedAt)
    }
}

struct ProjectSessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project_sessions"

    var projectId: String
    var sessionId: String
    var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case sessionId = "session_id"
        case addedAt = "added_at"
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published private(set) var projects: [Project] = []

    private init() {
        reload()
    }

    func reload() {
        do {
            let rows = try RTIDatabase.shared.pool.read { db in
                try ProjectRow
                    .filter(Column("archived_at") == nil)
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
            projects = rows.map { $0.toProject() }
        } catch {
            NSLog("[RTI] ProjectStore reload failed: \(error)")
        }
    }

    @discardableResult
    func create(name: String, instructions: String = "") -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(
            id: "proj.\(UUID().uuidString)",
            name: trimmed,
            instructions: instructions,
            createdAt: Date(),
            archivedAt: nil
        )
        let row = ProjectRow(
            id: project.id,
            name: project.name,
            instructions: project.instructions,
            createdAt: project.createdAt,
            archivedAt: nil
        )
        do {
            try RTIDatabase.shared.pool.write { db in try row.insert(db) }
            reload()
            return project
        } catch {
            NSLog("[RTI] ProjectStore create failed: \(error)")
            return nil
        }
    }

    func update(id: String, name: String? = nil, instructions: String? = nil) {
        do {
            try RTIDatabase.shared.pool.write { db in
                guard var row = try ProjectRow.fetchOne(db, key: id) else { return }
                if let name { row.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let instructions { row.instructions = instructions }
                try row.update(db)
            }
            reload()
        } catch {
            NSLog("[RTI] ProjectStore update failed: \(error)")
        }
    }

    /// Soft-delete via archived_at — keeps the chat history files findable
    /// if the user undoes. We never hard-delete unless the user really
    /// hits "Delete forever" (not yet exposed in UI).
    func archive(id: String) {
        do {
            try RTIDatabase.shared.pool.write { db in
                guard var row = try ProjectRow.fetchOne(db, key: id) else { return }
                row.archivedAt = Date()
                try row.update(db)
            }
            reload()
        } catch {
            NSLog("[RTI] ProjectStore archive failed: \(error)")
        }
    }

    // MARK: - Membership

    func sessionIds(forProject projectId: String) -> [String] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                try ProjectSessionRow
                    .filter(Column("project_id") == projectId)
                    .order(Column("added_at").desc)
                    .fetchAll(db)
                    .map(\.sessionId)
            }
        } catch {
            NSLog("[RTI] ProjectStore sessionIds failed: \(error)")
            return []
        }
    }

    func addSession(_ sessionId: String, toProject projectId: String) {
        let row = ProjectSessionRow(projectId: projectId, sessionId: sessionId, addedAt: Date())
        do {
            try RTIDatabase.shared.pool.write { db in
                // Replace any prior membership row so addedAt updates.
                _ = try ProjectSessionRow
                    .filter(Column("project_id") == projectId)
                    .filter(Column("session_id") == sessionId)
                    .deleteAll(db)
                try row.insert(db)
            }
            objectWillChange.send()
        } catch {
            NSLog("[RTI] ProjectStore addSession failed: \(error)")
        }
    }

    func removeSession(_ sessionId: String, fromProject projectId: String) {
        do {
            _ = try RTIDatabase.shared.pool.write { db in
                try ProjectSessionRow
                    .filter(Column("project_id") == projectId)
                    .filter(Column("session_id") == sessionId)
                    .deleteAll(db)
            }
            objectWillChange.send()
        } catch {
            NSLog("[RTI] ProjectStore removeSession failed: \(error)")
        }
    }
}
