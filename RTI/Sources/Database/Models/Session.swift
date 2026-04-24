import Foundation
import GRDB

struct Session: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var wavPath: String?
    var notes: String?

    static let databaseTableName = "sessions"

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case wavPath = "wav_path"
        case notes
    }
}
