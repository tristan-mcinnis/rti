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
        [captureScreen, spawnPanel]
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

    private static let spawnPanel = LLMToolDefinition(
        name: "spawn_panel",
        description: """
        Create a new live counter panel that floats over the user's screen \
        and counts keyword/regex matches against the streaming transcript \
        with a live sparkline. Use this when the user asks to "track", \
        "count", "watch", "create a panel for", "show a panel of", \
        "monitor", or otherwise spawn a live monitor of how many times \
        something is mentioned in the meeting. \
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


