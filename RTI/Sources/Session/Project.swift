import Foundation
import GRDB
import Observation

/// A user-defined grouping of sessions with shared instructions. The
/// canonical record is now markdown — one `PROJECT.md` per project under
/// `<corpus>/projects/<slug>/` (see `ProjectFiles.swift`). The DB tables
/// `projects` and `project_sessions` remain only so the one-shot
/// migrator (`ProjectMigrator`) can read them on the upgrade path; nothing
/// in the running app writes them anymore.

struct Project: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var instructions: String
    var memberIds: [String]
    var createdAt: Date
    var archivedAt: Date?
}

// MARK: - Legacy DB row shapes (migrator-only)

/// Legacy DB row. Kept on disk via the `v15_projects` migration. The
/// `ProjectMigrator` reads from here on first launch after the
/// markdown-projects upgrade; nothing else in the running app touches it.
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
}

/// Legacy DB join row. Same migrator-only status as `ProjectRow`.
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

// MARK: - Public store

@Observable @MainActor
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var projects: [Project] = []

    /// In-memory map of project id → folder slug. Lets us rename folders
    /// when the user renames a project without re-scanning disk every
    /// time membership changes.
    private var slugIndex: [String: String] = [:]

    private init() {
        ProjectMigrator.runIfNeeded()
        reload()
        // Re-scan on corpus-dir change so the user can swap roots and see
        // the right projects without restarting. Singleton holds the
        // observer for its (process-long) lifetime.
        NotificationCenter.default.addObserver(
            forName: .rtiSessionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    // Singleton — never deallocates, so no deinit/observer cleanup.

    func reload() {
        let loaded = ProjectFileStore.loadAll()
        slugIndex = Dictionary(uniqueKeysWithValues: loaded.map { ($0.entry.id, $0.slug) })
        let active = loaded
            .map { Self.makeProject(from: $0.entry) }
            .filter { $0.archivedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
        projects = active
        RTILog.log("reload — \(projects.count) project\(projects.count == 1 ? "" : "s") from disk", category: "projects")
    }

    // MARK: Mutations

    @discardableResult
    func create(name: String, instructions: String = "") -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = Project(
            id: "proj.\(UUID().uuidString)",
            name: trimmed,
            instructions: instructions,
            memberIds: [],
            createdAt: Date(),
            archivedAt: nil
        )
        do {
            let slug = try ProjectFileStore.save(Self.entry(from: project))
            slugIndex[project.id] = slug
            RTILog.log("created — id=\(project.id.suffix(8)) name=\"\(project.name)\" slug=\(slug)", category: "projects")
            reload()
            return project
        } catch {
            RTILog.log("create failed: \(error)", category: "projects")
            return nil
        }
    }

    func update(id: String, name: String? = nil, instructions: String? = nil) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            project.name = name
        }
        if let instructions { project.instructions = instructions }
        persist(project, log: { (renamed: Bool) in
            if let name { RTILog.log("rename — id=\(id.suffix(8)) → \"\(name)\"\(renamed ? " (folder renamed)" : "")", category: "projects") }
            if let instructions { RTILog.log("instructions updated — id=\(id.suffix(8)) chars=\(instructions.count)", category: "projects") }
        })
    }

    func archive(id: String) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.archivedAt = Date()
        persist(project, log: { _ in
            RTILog.log("archived — id=\(id.suffix(8))", category: "projects")
        })
    }

    // MARK: Membership

    func sessionIds(forProject projectId: String) -> [String] {
        projects.first { $0.id == projectId }?.memberIds ?? []
    }

    func addSession(_ sessionId: String, toProject projectId: String) {
        guard var project = projects.first(where: { $0.id == projectId }) else { return }
        // Move to the head — recency-ordered so the side panel reads
        // newest-first without an explicit sort step.
        project.memberIds.removeAll { $0 == sessionId }
        project.memberIds.insert(sessionId, at: 0)
        persist(project, log: { _ in
            RTILog.log("add session — project=\(projectId.suffix(8)) session=\(sessionId.suffix(8))", category: "projects")
        })
    }

    func removeSession(_ sessionId: String, fromProject projectId: String) {
        guard var project = projects.first(where: { $0.id == projectId }) else { return }
        project.memberIds.removeAll { $0 == sessionId }
        persist(project, log: { _ in
            RTILog.log("remove session — project=\(projectId.suffix(8)) session=\(sessionId.suffix(8))", category: "projects")
        })
    }

    /// IDs in this project's membership that no longer have a markdown
    /// file in the corpus. Surfaces orphans introduced by deletion or by
    /// switching to a different corpus dir that doesn't contain these
    /// sessions.
    func orphanedMemberIds(forProject projectId: String) -> [String] {
        let ids = sessionIds(forProject: projectId)
        guard !ids.isEmpty else { return [] }
        let live = Set(CorpusBackedStore.allMarkdownSessions().map(\.id))
        return ids.filter { !live.contains($0) }
    }

    /// Slug for an active project, if known. Used by code that writes
    /// artifacts adjacent to `PROJECT.md` (synthesis, chats).
    func slug(forProject projectId: String) -> String? {
        slugIndex[projectId]
    }

    // MARK: - Internals

    private func persist(_ project: Project, log: (Bool) -> Void) {
        do {
            let oldSlug = slugIndex[project.id]
            let newSlug = try ProjectFileStore.save(Self.entry(from: project))
            let renamed = oldSlug != newSlug
            slugIndex[project.id] = newSlug
            log(renamed)
            reload()
        } catch {
            RTILog.log("persist failed for \(project.id.suffix(8)): \(error)", category: "projects")
        }
    }

    private static func entry(from project: Project) -> ProjectEntry {
        ProjectEntry(
            id: project.id,
            name: project.name,
            instructions: project.instructions,
            members: project.memberIds,
            createdAt: project.createdAt,
            archivedAt: project.archivedAt
        )
    }

    private static func makeProject(from entry: ProjectEntry) -> Project {
        Project(
            id: entry.id,
            name: entry.name,
            instructions: entry.instructions,
            memberIds: entry.members,
            createdAt: entry.createdAt,
            archivedAt: entry.archivedAt
        )
    }
}
