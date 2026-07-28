import Foundation

/// A single row of the assistant chat log. User rows carry the action taken
/// and which context was attached; assistant rows carry the streamed reply.
/// Ephemeral — held in memory for the session only.
public struct ChatEntry: Identifiable, Equatable {
    public let id = UUID()
    public let role: String // "user" | "assistant"
    public var text: String
    public let action: String? // "Ask" | "Assist" — user entries only
    public let contextUsed: Bool // user entries only — transcript attached
    public let screenContextUsed: Bool // user entries only — OCR screen attached
    public let referencedPaths: [String] // user entries only — vault docs attached with @mentions

    public init(
        role: String,
        text: String,
        action: String?,
        contextUsed: Bool,
        screenContextUsed: Bool,
        referencedPaths: [String] = []
    ) {
        self.role = role
        self.text = text
        self.action = action
        self.contextUsed = contextUsed
        self.screenContextUsed = screenContextUsed
        self.referencedPaths = referencedPaths
    }
}
