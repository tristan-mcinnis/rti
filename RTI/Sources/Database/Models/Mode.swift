import Foundation
import GRDB

struct Mode: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var systemPrompt: String
    var isBuiltin: Bool
    var createdAt: Date

    static let databaseTableName = "modes"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case systemPrompt = "system_prompt"
        case isBuiltin = "is_builtin"
        case createdAt = "created_at"
    }
}
