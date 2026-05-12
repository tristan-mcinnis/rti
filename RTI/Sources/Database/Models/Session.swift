import Foundation

/// In-memory value type representing a session for the UI layer. No
/// longer GRDB-backed — the canonical store is the markdown file under
/// `~/meetings/` plus in-memory state for the active session.
struct Session: Identifiable, Hashable {
    var id: String
    var startedAt: Date
    var endedAt: Date? = nil
    var wavPath: String? = nil
    var notes: String? = nil
    var title: String? = nil
    var modeId: String? = nil
    var calendarEventId: String? = nil
    var calendarTitle: String? = nil
    var transcriptQuality: String? = nil
    /// Snapshot of the project (id + readable name) at session-render time.
    /// Mirrored into markdown frontmatter; canonical membership lives in
    /// `project_sessions`.
    var projectId: String? = nil
    var projectName: String? = nil
}

extension Session {
    /// Build from a parsed markdown frontmatter. Fields not in frontmatter
    /// (`notes`, `calendarEventId`) are left nil.
    init(from frontmatter: CorpusEntry.Frontmatter) {
        self.id = frontmatter.id
        self.startedAt = frontmatter.date
        self.endedAt = nil
        self.wavPath = frontmatter.wavPath
        self.notes = nil
        self.title = frontmatter.title
        self.modeId = frontmatter.mode
        self.calendarEventId = nil
        self.calendarTitle = nil
        self.transcriptQuality = frontmatter.transcriptQuality
        self.projectId = frontmatter.projectId
        self.projectName = frontmatter.project
    }
}
