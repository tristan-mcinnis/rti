import Foundation

/// The session.json sidecar written next to each archived session. Top-level
/// (not nested in `SessionArchive`) and Foundation-only so the test bundle can
/// compile it without dragging in the archive writer's app dependencies;
/// `SessionArchive.ArchiveMetadata` remains the canonical spelling via a
/// typealias.
struct SessionArchiveMetadata: Codable {
    let sessionId: String?
    let systemAudioStartOffsetMs: Int?
    let micAudioFile: String?
    let systemAudioFile: String?
    /// The active mode's display name at session end (e.g. "Meeting",
    /// "Interview"). Nil if no mode was active.
    let mode: String?
    /// The Setup workstream picker's item name (project or client),
    /// regardless of which — unlike `workstreamSlug`/`workstream:`
    /// frontmatter (project-only, used by route-rti-session.py's routing
    /// policy). Nil if no workstream was selected.
    let workstream: String?
    /// Wall-clock session length in seconds (endedAt - startedAt).
    let durationSeconds: Int?
}
