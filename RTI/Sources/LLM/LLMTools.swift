import Foundation
import RTICore

/// The concrete function tools the chat-overlay LLM can call. `LLMToolDefinition`
/// lives in RTICore; the tools themselves stay app-side because they touch app
/// services (e.g. screen capture).
@MainActor
enum LLMToolRegistry {
    /// All tools the chat-overlay LLM can call. Keep this small: too many
    /// tools dilutes the model's tool-choice signal.
    static var all: [LLMToolDefinition] {
        [captureScreen, searchVault]
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

    private static let searchVault = LLMToolDefinition(
        name: "search_vault",
        description: """
        Search Tristan's knowledge vault — past meetings, project status \
        dashboards, research findings, client notes, proposals, reports, and \
        the project's research transcripts (what consumers or experts said in \
        specific groups and interviews). When a project is set for this meeting, \
        the search is automatically focused on that project first. \
        Use this when the conversation raises a question whose answer lives in \
        the knowledge base rather than the live transcript: project status, a \
        past decision ("what did we decide about…"), what was agreed, client or \
        stakeholder background, prior research findings, or what a participant \
        said in a research session ("what did Group 1 say about their favourite \
        store"). Do NOT use it for questions about the current conversation — \
        the transcript already covers those. Returns the most relevant \
        documents with short excerpts.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "A short phrase describing what to look for, e.g. 'AcmeBrand store format decision' or 'Vandelay collectibles target consumer'.",
                ] as [String: Any],
            ] as [String: Any],
            "required": ["query"],
            "additionalProperties": false,
        ],
        execute: { argumentsJSON in
            let query = decodeQuery(from: argumentsJSON)
            // Focus on the meeting's project when one is picked (nil = whole vault).
            let scope = MeetingContextStore.shared.workstreamScopePath
            let start = Date()
            let result = await VaultSearch.searchFormatted(query: query, scopeRelativePath: scope)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            RTILog.log("search_vault '\(query)' took \(ms)ms", category: "vault")
            return result
        },
        runningStatus: "🔎 Searching the vault…"
    )

    /// Pull `query` out of the tool-call arguments JSON. Tolerant: a bare string
    /// or malformed JSON falls back to the raw argument text so a search still
    /// runs instead of erroring.
    private static func decodeQuery(from argumentsJSON: String) -> String {
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let q = obj["query"] as? String {
            return q
        }
        return argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}


