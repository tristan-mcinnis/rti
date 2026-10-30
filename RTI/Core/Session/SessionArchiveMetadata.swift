import Foundation

/// The session.json sidecar written next to each archived session. Top-level
/// (not nested in `SessionArchive`) and Foundation-only so the test bundle can
/// compile it without dragging in the archive writer's app dependencies;
/// `SessionArchive.ArchiveMetadata` remains the canonical spelling via a
/// typealias.
public struct SessionArchiveMetadata: Codable {
    public let sessionId: String?
    public let systemAudioStartOffsetMs: Int?
    public let micAudioFile: String?
    public let systemAudioFile: String?
    /// The active mode's display name at session end (e.g. "Meeting",
    /// "Interview"). Nil if no mode was active.
    public let mode: String?
    /// The Setup workstream picker's item name (project or client),
    /// regardless of which — unlike `workstreamSlug`/`workstream:`
    /// frontmatter (project-only). Nil if no workstream was selected.
    public let workstream: String?
    /// Wall-clock session length in seconds (endedAt - startedAt).
    public let durationSeconds: Int?
    /// The calendar event picked in Prepare, if any. The Sessions window
    /// uses it as a title when the title file and the vault note have none
    /// (`SessionTitleResolver` rule 4). Defaults to nil, so existing call
    /// sites and legacy `session.json` files are unchanged.
    public var calendarTitle: String? = nil
    /// A known capture/write/close failure. Retained audio needs review before processing.
    public var recordingError: String? = nil

    public init(
        sessionId: String?,
        systemAudioStartOffsetMs: Int?,
        micAudioFile: String?,
        systemAudioFile: String?,
        mode: String?,
        workstream: String?,
        durationSeconds: Int?,
        calendarTitle: String? = nil,
        recordingError: String? = nil
    ) {
        self.sessionId = sessionId
        self.systemAudioStartOffsetMs = systemAudioStartOffsetMs
        self.micAudioFile = micAudioFile
        self.systemAudioFile = systemAudioFile
        self.mode = mode
        self.workstream = workstream
        self.durationSeconds = durationSeconds
        self.calendarTitle = calendarTitle
        self.recordingError = recordingError
    }
}
