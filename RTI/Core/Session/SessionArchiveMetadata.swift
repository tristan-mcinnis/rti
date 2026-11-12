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
    /// What Soniox should know about this session, for the transcript upgrade.
    /// Nil in `session.json` files written before 2026-11-04.
    public var speechContext: SonioxContext? = nil
    public var groupID: String?
    public var guidePath: String?
    public var guideSourcePath: String?
    public var rosterPath: String?
    /// The roster at recording time, for later seat edits even if its source moves.
    public var guideRoster: [GuideSeat]?

    public var schemaVersion: Int?
    public var evidenceFile: String?
    public var noteIDs: [String]?
    public var markerSpans: [MarkerSpan]?
    public var turns: [SessionAnnotatedTurn]?
    public var stimulusPackageRevision: String?
    public var speakerPolicy: SessionSpeakerPolicy?

    private enum CodingKeys: String, CodingKey {
        case sessionId, systemAudioStartOffsetMs, micAudioFile, systemAudioFile, mode, workstream
        case durationSeconds, calendarTitle, recordingError, speechContext
        case schemaVersion, evidenceFile, noteIDs, markerSpans, turns, stimulusPackageRevision, speakerPolicy
        case groupID = "group_id"
        case guidePath = "guide_path"
        case guideSourcePath = "guide_source_path"
        case rosterPath = "roster_path"
        case guideRoster = "guide_roster"
    }

    public init(
        sessionId: String?,
        systemAudioStartOffsetMs: Int?,
        micAudioFile: String?,
        systemAudioFile: String?,
        mode: String?,
        workstream: String?,
        durationSeconds: Int?,
        calendarTitle: String? = nil,
        recordingError: String? = nil,
        speechContext: SonioxContext? = nil,
        groupID: String? = nil,
        guidePath: String? = nil,
        guideSourcePath: String? = nil,
        rosterPath: String? = nil,
        guideRoster: [GuideSeat]? = nil
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
        self.speechContext = speechContext
        self.groupID = groupID
        self.guidePath = guidePath
        self.guideSourcePath = guideSourcePath
        self.rosterPath = rosterPath
        self.guideRoster = guideRoster
    }
}
