import Foundation

/// A prompt-shaping mode. Built-in modes ship with the app; user modes are
/// added at runtime. Persisted as JSON (no database) since modes are small
/// config, not transcript data.
struct Mode: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var systemPrompt: String
    let isBuiltin: Bool
    let createdAt: Date
    var referenceText: String?
}
