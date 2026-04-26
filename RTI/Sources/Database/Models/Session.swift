import Foundation
import GRDB

struct Session: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var wavPath: String?
    var notes: String?
    var title: String?
    var modeId: String?
    var calendarEventId: String?
    var calendarTitle: String?

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
    }
}
