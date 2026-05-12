import Foundation
import GRDB
import Yams

/// File-backed project storage. Projects live as folders under the
/// corpus directory:
///
///     <corpus>/projects/<slug>/PROJECT.md
///     <corpus>/projects/<slug>/synthesis.md
///     <corpus>/projects/<slug>/chats/<conv-id>.md
///
/// This makes projects portable: iCloud-syncing the corpus dir now moves
/// projects, project chats, and synthesis with the markdown sessions.
/// The DB is reduced to an index over markdown — no authored project
/// state lives in SQLite anymore.

// MARK: - On-disk shape

/// Decoded shape of `PROJECT.md` frontmatter. The body is currently
/// unused — users can write free-form notes there and we'll preserve
/// them on round-trip.
struct ProjectEntry: Codable, Equatable {
    var id: String
    var name: String
    var instructions: String
    var members: [String]
    var createdAt: Date
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, members
        case createdAt = "created_at"
        case archivedAt = "archived_at"
    }
}

// MARK: - File store

@MainActor
enum ProjectFileLayout {
    /// Root for all project folders.
    static func root() -> URL {
        let dir = CorpusManager.shared.corpusDirectory
            .appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory for a single project, looked up by slug.
    static func dir(slug: String) -> URL {
        root().appendingPathComponent(slug, isDirectory: true)
    }

    static func projectFile(slug: String) -> URL {
        dir(slug: slug).appendingPathComponent("PROJECT.md")
    }

    static func synthesisFile(slug: String) -> URL {
        dir(slug: slug).appendingPathComponent("synthesis.md")
    }

    static func chatsDir(slug: String) -> URL {
        let d = dir(slug: slug).appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Make a URL-safe slug from a project name. Lowercase, ASCII, dashes
    /// only — `[^a-z0-9]+` collapses to `-`. Empty input becomes
    /// `untitled`. Uniqueness is handled by the caller (append `-2`, etc.).
    static func makeSlug(from name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var prevDash = false
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                prevDash = false
            } else if !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}

@MainActor
enum ProjectFileStore {
    // MARK: Reads

    /// Walk `<corpus>/projects/*/PROJECT.md` and return one
    /// `(entry, slug)` pair per project. Skips folders without a
    /// readable `PROJECT.md`.
    static func loadAll() -> [(entry: ProjectEntry, slug: String)] {
        let root = ProjectFileLayout.root()
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(ProjectEntry, String)] = []
        for folder in folders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let file = folder.appendingPathComponent("PROJECT.md")
            guard let entry = try? readProjectFile(file) else { continue }
            out.append((entry, folder.lastPathComponent))
        }
        return out
    }

    static func readProjectFile(_ url: URL) throws -> ProjectEntry {
        let raw = try String(contentsOf: url, encoding: .utf8)
        guard let yaml = extractFrontmatter(raw) else {
            throw NSError(domain: "ProjectFileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or unterminated frontmatter"])
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(ProjectEntry.self, from: yaml)
    }

    // MARK: Writes

    /// Resolve a unique slug for this project. If the preferred slug is
    /// taken by a different project id, append `-2`, `-3`, etc.
    static func resolveSlug(name: String, id: String) -> String {
        let preferred = ProjectFileLayout.makeSlug(from: name)
        let existing = loadAll()
        let takenByOthers = Set(existing.filter { $0.entry.id != id }.map(\.slug))
        if !takenByOthers.contains(preferred) { return preferred }
        var n = 2
        while takenByOthers.contains("\(preferred)-\(n)") { n += 1 }
        return "\(preferred)-\(n)"
    }

    /// Find an existing folder slug for this project id, if any. Used to
    /// detect rename (existing slug differs from preferred).
    static func currentSlug(forId id: String) -> String? {
        loadAll().first { $0.entry.id == id }?.slug
    }

    /// Atomic write of a project. Renames the folder if the slug changed
    /// (name update). Caller owns `entry` mutation and passes the canonical
    /// pre-existing slug if known.
    @discardableResult
    static func save(_ entry: ProjectEntry) throws -> String {
        let oldSlug = currentSlug(forId: entry.id)
        let newSlug = resolveSlug(name: entry.name, id: entry.id)
        if let oldSlug, oldSlug != newSlug {
            let from = ProjectFileLayout.dir(slug: oldSlug)
            let to = ProjectFileLayout.dir(slug: newSlug)
            try? FileManager.default.moveItem(at: from, to: to)
        }
        let dir = ProjectFileLayout.dir(slug: newSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = ProjectFileLayout.projectFile(slug: newSlug)
        let body = try renderProjectFile(entry)
        let tmp = url.appendingPathExtension("tmp")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return newSlug
    }

    static func delete(slug: String) {
        try? FileManager.default.removeItem(at: ProjectFileLayout.dir(slug: slug))
    }

    // MARK: - Rendering / parsing helpers

    static func renderProjectFile(_ entry: ProjectEntry) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        let yaml = try encoder.encode(entry)
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        return "---\n\(trimmed)\n---\n\n# \(entry.name)\n"
    }

    private static func extractFrontmatter(_ raw: String) -> String? {
        var src = raw
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }
        let lines = src.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        var end: Int?
        for i in 1..<lines.count where lines[i] == "---" {
            end = i
            break
        }
        guard let end else { return nil }
        return lines[1..<end].joined(separator: "\n")
    }
}

// MARK: - Chat store (markdown-backed)

/// One conversation in a project's `chats/` folder. Frontmatter is the
/// source of truth on read; the body below the YAML is a human-readable
/// render regenerated on every save.
struct ProjectChatEntry: Codable {
    var id: String
    var projectId: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    struct Message: Codable {
        var role: String
        var text: String
        var createdAt: Date
        var citations: [Citation]

        struct Citation: Codable {
            var sessionId: String
            var title: String

            enum CodingKeys: String, CodingKey {
                case sessionId = "session_id"
                case title
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, text, citations
            case createdAt = "created_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case projectId = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

@MainActor
enum ProjectChatFileStore {
    static func list(projectSlug: String) -> [ProjectChatEntry] {
        let dir = ProjectFileLayout.chatsDir(slug: projectSlug)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [ProjectChatEntry] = []
        for url in urls where url.pathExtension == "md" {
            guard let entry = try? read(url) else { continue }
            out.append(entry)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func read(_ url: URL) throws -> ProjectChatEntry {
        let raw = try String(contentsOf: url, encoding: .utf8)
        guard let yaml = ProjectFileStore_extractFrontmatter(raw) else {
            throw NSError(domain: "ProjectChatFileStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing or unterminated frontmatter"])
        }
        return try YAMLDecoder().decode(ProjectChatEntry.self, from: yaml)
    }

    static func save(_ entry: ProjectChatEntry, projectSlug: String) {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        guard let yaml = try? encoder.encode(entry) else { return }
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        var body = "# \(entry.title)\n\n"
        for m in entry.messages {
            body += "## \(m.role == "user" ? "You" : "RTI")\n\n\(m.text)\n\n"
            if m.role == "assistant", !m.citations.isEmpty {
                let names = m.citations.map { "[\($0.title)]" }.joined(separator: ", ")
                body += "_Sources: \(names)_\n\n"
            }
        }
        let file = ProjectFileLayout.chatsDir(slug: projectSlug)
            .appendingPathComponent("\(entry.id).md")
        let full = "---\n\(trimmed)\n---\n\n\(body)"
        let tmp = file.appendingPathExtension("tmp")
        try? full.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    static func delete(projectSlug: String, conversationId: String) {
        let file = ProjectFileLayout.chatsDir(slug: projectSlug)
            .appendingPathComponent("\(conversationId).md")
        try? FileManager.default.removeItem(at: file)
    }
}

/// Shared helper — same logic as `ProjectFileStore.extractFrontmatter`,
/// exposed so the chat store can reuse it without violating encapsulation
/// (Swift doesn't let `enum`s expose private statics across files).
@MainActor
func ProjectFileStore_extractFrontmatter(_ raw: String) -> String? {
    var src = raw
    if src.hasPrefix("\u{FEFF}") { src.removeFirst() }
    let lines = src.components(separatedBy: "\n")
    guard lines.first == "---" else { return nil }
    var end: Int?
    for i in 1..<lines.count where lines[i] == "---" {
        end = i
        break
    }
    guard let end else { return nil }
    return lines[1..<end].joined(separator: "\n")
}

// MARK: - One-shot DB → files migrator

/// Reads legacy DB-backed projects + JSON chats + App-Support synthesis
/// and writes them into the corpus markdown layout. Runs once on first
/// launch after this change; marker stored in UserDefaults.
@MainActor
enum ProjectMigrator {
    private static let migrationFlagKey = "rti.projects.migratedToMarkdownV1"

    static var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: migrationFlagKey)
    }

    /// Run the migration if we haven't already. Idempotent. Logs and
    /// silently moves on if any individual project fails — the failure
    /// won't poison the rest.
    static func runIfNeeded() {
        if hasMigrated { return }
        let legacy = readLegacyDBProjects()
        if legacy.isEmpty {
            // Nothing to migrate; still set the flag so we don't probe
            // the DB on every boot.
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            RTILog.log("migrator — nothing to migrate, marking complete", category: "projects")
            return
        }
        for legacyProject in legacy {
            do {
                try migrate(legacyProject)
            } catch {
                RTILog.log("migrator — failed for \(legacyProject.id): \(error)", category: "projects")
            }
        }
        UserDefaults.standard.set(true, forKey: migrationFlagKey)
        RTILog.log("migrator — migrated \(legacy.count) project\(legacy.count == 1 ? "" : "s") to markdown", category: "projects")
    }

    /// Force a migration regardless of the flag. Used by tests / manual
    /// recovery; not wired to UI.
    static func forceRun() {
        UserDefaults.standard.set(false, forKey: migrationFlagKey)
        runIfNeeded()
    }

    private struct LegacyProject {
        let id: String
        let name: String
        let instructions: String
        let createdAt: Date
        let archivedAt: Date?
        let memberIds: [String]
    }

    private static func readLegacyDBProjects() -> [LegacyProject] {
        do {
            return try RTIDatabase.shared.pool.read { db in
                guard try db.tableExists("projects") else { return [] }
                let rows = try ProjectRow.fetchAll(db)
                var out: [LegacyProject] = []
                for row in rows {
                    let memberIds = (try? ProjectSessionRow
                        .filter(Column("project_id") == row.id)
                        .order(Column("added_at").desc)
                        .fetchAll(db)
                        .map(\.sessionId)) ?? []
                    out.append(LegacyProject(
                        id: row.id,
                        name: row.name,
                        instructions: row.instructions,
                        createdAt: row.createdAt,
                        archivedAt: row.archivedAt,
                        memberIds: memberIds
                    ))
                }
                return out
            }
        } catch {
            RTILog.log("migrator — DB read failed: \(error)", category: "projects")
            return []
        }
    }

    private static func migrate(_ legacy: LegacyProject) throws {
        let entry = ProjectEntry(
            id: legacy.id,
            name: legacy.name,
            instructions: legacy.instructions,
            members: legacy.memberIds,
            createdAt: legacy.createdAt,
            archivedAt: legacy.archivedAt
        )
        let slug = try ProjectFileStore.save(entry)
        migrateChats(projectId: legacy.id, projectSlug: slug)
        migrateSynthesis(projectId: legacy.id, projectSlug: slug)
        RTILog.log("migrator — wrote \(slug) (\(legacy.memberIds.count) members)", category: "projects")
    }

    private static func migrateChats(projectId: String, projectSlug: String) {
        let legacyDir = legacyChatsDir(projectId: projectId)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let legacy = try? decoder.decode(ProjectChatConversation.self, from: data)
            else { continue }
            let entry = ProjectChatEntry(
                id: legacy.id,
                projectId: legacy.projectId,
                title: legacy.title,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                messages: legacy.messages.map { msg in
                    .init(
                        role: msg.role,
                        text: msg.text,
                        createdAt: msg.createdAt,
                        citations: msg.citations.map { .init(sessionId: $0.sessionId, title: $0.title) }
                    )
                }
            )
            ProjectChatFileStore.save(entry, projectSlug: projectSlug)
        }
    }

    private static func migrateSynthesis(projectId: String, projectSlug: String) {
        let legacy = legacySynthesisFile(projectId: projectId)
        guard let body = try? String(contentsOf: legacy, encoding: .utf8) else { return }
        let target = ProjectFileLayout.synthesisFile(slug: projectSlug)
        let stamped = "---\nproject_id: \(projectId)\ngenerated_at: \(ISO8601DateFormatter().string(from: Date()))\n---\n\n" + body
        try? stamped.write(to: target, atomically: true, encoding: .utf8)
    }

    private static func legacyChatsDir(projectId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("RTI/projects-chat", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
    }

    private static func legacySynthesisFile(projectId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("RTI/projects-insights", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("synthesis.md")
    }
}

// MARK: - Synthesis artifact

/// Latest-wins synthesis file under `<corpus>/projects/<slug>/synthesis.md`.
/// Has a tiny frontmatter (project id + generated timestamp) so the UI
/// can show "Generated X ago".
struct ProjectSynthesisArtifact {
    var projectId: String
    var generatedAt: Date
    var body: String
}

@MainActor
enum ProjectSynthesisFileStore {
    static func read(projectSlug: String) -> ProjectSynthesisArtifact? {
        let url = ProjectFileLayout.synthesisFile(slug: projectSlug)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if let yaml = ProjectFileStore_extractFrontmatter(raw) {
            // Re-derive body by trimming the frontmatter block off the raw text.
            let body = stripFrontmatter(raw)
            var generatedAt = Date(timeIntervalSince1970: 0)
            var projectId = ""
            for line in yaml.components(separatedBy: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "project_id" { projectId = val }
                if key == "generated_at" {
                    generatedAt = ISO8601DateFormatter().date(from: val) ?? generatedAt
                }
            }
            return ProjectSynthesisArtifact(projectId: projectId, generatedAt: generatedAt, body: body)
        }
        // No frontmatter — best-effort read.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        return ProjectSynthesisArtifact(projectId: "", generatedAt: mtime, body: raw)
    }

    static func write(projectSlug: String, projectId: String, body: String) {
        let url = ProjectFileLayout.synthesisFile(slug: projectSlug)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let full = "---\nproject_id: \(projectId)\ngenerated_at: \(stamp)\n---\n\n\(body)\n"
        let tmp = url.appendingPathExtension("tmp")
        try? full.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func stripFrontmatter(_ raw: String) -> String {
        var src = raw
        if src.hasPrefix("\u{FEFF}") { src.removeFirst() }
        let lines = src.components(separatedBy: "\n")
        guard lines.first == "---" else { return raw }
        var end: Int?
        for i in 1..<lines.count where lines[i] == "---" {
            end = i
            break
        }
        guard let end else { return raw }
        var bodyStart = end + 1
        if bodyStart < lines.count, lines[bodyStart].isEmpty { bodyStart += 1 }
        return bodyStart < lines.count ? lines[bodyStart...].joined(separator: "\n") : ""
    }
}
