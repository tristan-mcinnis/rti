import Foundation
import GRDB

struct Session: Codable, FetchableRecord, PersistableRecord, Identifiable {
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

    static let databaseTableName = "sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case wavPath = "wav_path"
        case notes
        case title
        case modeId = "mode_id"
        case calendarEventId = "calendar_event_id"
        case calendarTitle = "calendar_title"
        case transcriptQuality = "transcript_quality"
    }
}
