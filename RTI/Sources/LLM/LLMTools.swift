import Foundation

/// Function tools the model can invoke during a chat turn. Each tool has a
/// JSON-schema describing its parameters (sent to the provider) and an async
/// `execute` block that runs locally and returns a string the model sees as
/// the tool's result.
///
/// Adding a new tool is a one-shot: append a `LLMToolDefinition` to
/// `LLMToolRegistry.all` and the controller picks it up automatically.
struct LLMToolDefinition {
    let name: String
    let description: String
    /// JSON-schema for the function's parameters, as a Foundation
    /// dictionary. Serialised once when building the request body.
    let parameters: [String: Any]
    /// Locally executes the tool. Returns the result text the model will
    /// see in the next turn. Throwing converts to an error string the model
    /// can recover from.
    let execute: @Sendable @MainActor (_ argumentsJSON: String) async throws -> String
    /// Optional human-readable status shown in the UI while the tool runs
    /// (e.g. "📷 Looking at your screen…"). Falls back to the tool name.
    let runningStatus: String?
}

@MainActor
enum LLMToolRegistry {
    /// All tools the chat-overlay LLM can call. Keep this small: too many
    /// tools dilutes the model's tool-choice signal.
    static var all: [LLMToolDefinition] {
        [captureScreen, readNotes, readDossiers, spawnPanel]
    }

    static func tool(named name: String) -> LLMToolDefinition? {
        all.first { $0.name == name }
    }

    /// Tools encoded as the wire-format JSON array OpenAI expects under the
    /// top-level `tools` field. Returned as `Data` rather than
    /// `[[String: Any]]` so it can cross actor boundaries (Any is not
    /// Sendable). Returns nil when no tools are registered.
    static func wireFormatData() -> Data? {
        let arr: [[String: Any]] = all.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            ]
        }
        guard !arr.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: arr, options: [])
    }

    // MARK: - Tools

    private static let captureScreen = LLMToolDefinition(
        name: "capture_screen",
        description: """
        Capture what the user is currently looking at on screen. Runs OCR \
        to return any visible text. \
        Use this whenever the user asks about their screen, what they're \
        looking at, what's visible, what an app is showing, or asks you to \
        read or summarise something on their display. Do not ask the user \
        to attach a screenshot — call this tool instead.
        """,
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false
        ],
        execute: { _ in
            try await ScreenshotManager.shared.captureAndDescribe()
        },
        runningStatus: "📷 Looking at your screen…"
    )

    private static let readNotes = LLMToolDefinition(
        name: "read_notes",
        description: """
        Read the auto-generated meeting notes for the current session. \
        Use this when the user asks about "the notes", "what we noted", \
        "key points", "action items", "decisions", "open questions", or \
        anything that the running notes summariser would have captured. \
        Returns the most recent notes first, each with a timestamp and \
        markdown-formatted body covering Key Points, Decisions Made, \
        Action Items, and Open Questions.
        """,
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false
        ],
        execute: { _ in
            guard let sessionId = SessionCoordinator.shared.currentSessionId else {
                return "No active session — there are no notes to read yet."
            }
            let notes = NotesGenerationController.loadNotes(forSessionId: sessionId)
            guard !notes.isEmpty else {
                return "No notes have been generated for the current session yet."
            }
            let parts = notes.reversed().map { n -> String in
                let when = n.timestamp.formatted(date: .omitted, time: .shortened)
                return "## Note from \(when)\n\n\(n.content)"
            }
            return parts.joined(separator: "\n\n---\n\n")
        },
        runningStatus: "📒 Reading notes…"
    )

    private static let readDossiers = LLMToolDefinition(
        name: "read_dossiers",
        description: """
        Read the entity dossiers (people, brands, organizations, concepts) \
        the analysis pass has tracked across the current session. Use this \
        when the user asks who someone is, who/what was mentioned, what \
        the entities are, or asks about a specific name they remember from \
        the conversation. Returns each entity with its type and a brief \
        description.
        """,
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false
        ],
        execute: { _ in
            guard let sessionId = SessionCoordinator.shared.currentSessionId else {
                return "No active session — there are no dossiers to read yet."
            }
            let dossiers = DossierController.loadDossiers(forSessionId: sessionId)
            guard !dossiers.isEmpty else {
                return "No dossiers have been generated for the current session yet."
            }
            let grouped = Dictionary(grouping: dossiers) { $0.type }
                .sorted { $0.key.displayName < $1.key.displayName }
            let sections: [String] = grouped.map { (type, items) in
                let body: [String] = items.map { "- **\($0.name)** — \($0.description)" }
                return "## \(type.displayName)\n\(body.joined(separator: "\n"))"
            }
            return sections.joined(separator: "\n\n")
        },
        runningStatus: "🗂️ Reading dossiers…"
    )

    private static let spawnPanel = LLMToolDefinition(
        name: "spawn_panel",
        description: """
        Create a new live analysis panel that floats over the user's \
        screen. Use this when the user asks to "track", "count", "watch", \
        "create a panel for", "show a panel of", "monitor", or otherwise \
        spawn a new live monitor of something happening in the meeting. \
        Two panel kinds are supported:
          • counter — counts keyword/regex matches against the streaming \
            transcript with a live sparkline. Use for "track how many \
            times X is mentioned".
          • periodic_cards — runs a custom prompt every couple of minutes \
            against the recent transcript window and appends results as \
            cards. Use for "extract quotes", "find contradictions", \
            "list questions", or anything that needs the LLM to \
            re-evaluate the transcript on a schedule.
        The argument `description` is the user's natural-language request; \
        the tool translates it into a typed panel config and opens the \
        window.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "description": [
                    "type": "string",
                    "description": "The user's plain-English description of the panel they want."
                ]
            ],
            "required": ["description"],
            "additionalProperties": false
        ],
        execute: { argumentsJSON in
            let description: String
            if let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = obj["description"] as? String {
                description = d
            } else {
                description = argumentsJSON  // model may pass raw text
            }
            return await PanelSpawner.spawn(fromDescription: description)
        },
        runningStatus: "🪄 Designing a panel…"
    )
}


