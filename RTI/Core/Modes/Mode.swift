import Foundation

/// A prompt-shaping mode. Built-in modes ship with the app; user modes are
/// added at runtime. Persisted as JSON (no database) since modes are small
/// config, not transcript data.
public struct Mode: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var systemPrompt: String
    public let isBuiltin: Bool
    public let createdAt: Date
    public var referenceText: String?

    public init(
        id: String,
        name: String,
        systemPrompt: String,
        isBuiltin: Bool,
        createdAt: Date,
        referenceText: String?
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.referenceText = referenceText
    }
}
