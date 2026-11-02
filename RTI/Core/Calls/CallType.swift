import Foundation

/// The kind of call being recorded. One choice, made before the call, that
/// sets how RTI answers, which actions the ✦ menu shows, whether a live turn
/// may search, and what the `/meeting` run is told afterwards.
public enum CallType: String, CaseIterable, Identifiable, Sendable {
    case client
    case research
    case `internal`
    case personal

    /// When a turn during a recording may reach the vault.
    public enum ToolAccess: Sendable {
        case whenAsked, never
    }

    public var id: String {
        rawValue
    }

    public var name: String {
        switch self {
        case .client: "Client call"
        case .research: "Research"
        case .internal: "Internal"
        case .personal: "Personal"
        }
    }

    /// The system prompt, editable in Settings > Prompts.
    public var prompt: PromptID {
        switch self {
        case .client: .callClient
        case .research: .callResearch
        case .internal: .callInternal
        case .personal: .callPersonal
        }
    }

    /// True when the user is usually observing rather than speaking.
    public var listens: Bool {
        self == .research
    }

    public var toolAccess: ToolAccess {
        self == .personal ? .never : .whenAsked
    }

    /// The ✦ menu, in order. The rest stay in the palette and on their hotkeys.
    public var menuActionIDs: [String] {
        switch self {
        case .client: ["assist", "answerLatest", "quickRecap", "recap"]
        case .research: ["probe", "keyTensions", "followups", "quickRecap", "recap"]
        case .internal: ["quickRecap", "recap", "assist", "answerLatest"]
        case .personal: ["answerLatest", "quickRecap", "recap"]
        }
    }

    public var menuActions: [AssistantAction] {
        menuActionIDs.compactMap(AssistantAction.byID)
    }

    /// The front matter line the `/meeting` skill reads from the sidecar.
    public var sidecarField: String {
        "call_type: \(rawValue)"
    }

    /// The remembered choice, or a client call when nothing usable is stored.
    public static func resolve(stored: String?) -> CallType {
        stored.flatMap(CallType.init(rawValue:)) ?? .client
    }
}
