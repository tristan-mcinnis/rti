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

/// The behavioural family a mode belongs to. Drives which quick actions the
/// overlay surfaces and which summary shape a session gets — so the app's
/// functions adapt to whether you're in a meeting, sitting in on fieldwork,
/// or coding, instead of being meeting-shaped everywhere. Derived from the
/// built-in id when possible, otherwise inferred from the mode name so user
/// modes ("FGD observer", "IDI") still classify sensibly.
public enum ModeKind {
    case meeting, interview, coding, other
}

public extension Mode {
    var kind: ModeKind {
        switch id {
        case "builtin.meeting": return .meeting
        case "builtin.interview": return .interview
        case "builtin.coding": return .coding
        default:
            let n = name.lowercased()
            if ["interview", "fgd", "idi", "fieldwork", "observ", "listen", "respondent", "focus group"].contains(where: n.contains) { return .interview }
            if ["meeting", "call", "standup", "stand-up", "sync", "review", "workshop"].contains(where: n.contains) { return .meeting }
            if ["cod", "dev", "program", "engineer", "debug"].contains(where: n.contains) { return .coding }
            return .other
        }
    }
}
