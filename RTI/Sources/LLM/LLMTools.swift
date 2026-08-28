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
        [captureScreen, highlightScreenText, searchVault, recentMeetings, readDocument, grepVault, listFiles]
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
        Capture the user's connected screens. Runs OCR to return visible text \
        grouped by display, with the screen containing the mouse cursor listed \
        first as the primary screen. \
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

    private static let highlightScreenText = LLMToolDefinition(
        name: "highlight_screen_text",
        description: """
        Briefly highlight a visible text region from the most recent screen \
        capture. Use after capture_screen when the user asks where something \
        is, what to click, or asks you to point out a visible label. Pass a \
        short exact phrase from the OCR result, such as a button label, menu \
        item, heading, or field label. This only works for text that appeared \
        in the last capture_screen result.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "A short exact phrase from the most recent screen OCR to highlight.",
                ] as [String: Any],
            ] as [String: Any],
            "required": ["text"],
            "additionalProperties": false,
        ],
        execute: { argumentsJSON in
            let text = decodeField("text", from: argumentsJSON)
            return ScreenshotManager.shared.highlightTextOnLastCapture(text)
        },
        runningStatus: "Highlighting the screen…"
    )

    private static let searchVault = LLMToolDefinition(
        name: "search_vault",
        description: """
        Search Tristan's knowledge vault — past meetings, project status \
        dashboards, research findings, client notes, proposals, reports, and \
        the project's research transcripts (what consumers or experts said in \
        specific groups and interviews). When a project is set for this meeting, \
        the search is automatically focused on that project first. \
        Use this when the conversation raises a question whose answer may live \
        in the knowledge base rather than only the live transcript: project \
        status, a past decision ("what did we decide about…"), what was agreed, \
        client or stakeholder background, prior research findings, or what a \
        participant said in a research session ("what did Group 1 say about \
        their favourite store"). If the user asks "answer that", "what do we \
        know about that", or a client asks a factual question tied to the \
        selected project, search first, then answer from transcript + hits. Do \
        NOT use it for questions only about what just happened in the current \
        conversation. Returns the most relevant documents with short excerpts.
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
            let response = await VaultRetrieval.search(query: query, scopeRelativePath: scope)
            RTILog.log("search_vault '\(query)' took \(response.elapsedMS)ms", category: "vault")
            return response.formattedResults
        },
        runningStatus: "Searching the vault…"
    )

    private static let recentMeetings = LLMToolDefinition(
        name: "recent_meetings",
        description: """
        List this meeting's project's most recent meetings and sessions, newest \
        first (the latest is #1). Use this — NOT search_vault — whenever the \
        answer is the most RECENT record rather than the most topically relevant \
        one: "what was the last/latest meeting", "what did we discuss recently", \
        "recap our last session", "what happened earlier today/yesterday/this \
        week", or any follow-up about the previous conversation. search_vault \
        ranks by relevance and has no sense of time, so it will return an old \
        but on-topic note for these; this returns the actual newest records with \
        their dates. After getting the list, you can search_vault for detail on a \
        specific one if needed.
        """,
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false,
        ],
        execute: { _ in
            let scope = MeetingContextStore.shared.workstreamScopePath
            return VaultMeetings.recentFormatted(scopeRelativePath: scope)
        },
        runningStatus: "🗓️ Checking recent meetings…"
    )

    private static let readDocument = LLMToolDefinition(
        name: "read_document",
        description: """
        Read the full text of one vault document by its path (as printed by \
        search_vault, recent_meetings, grep_vault, or list_files). Use this when \
        a search/list surfaced the right file but you need its actual content to \
        answer — e.g. after recent_meetings gives you the last meeting, read it \
        to say what was discussed. Markdown only (PDFs/PPTX aren't readable; rely \
        on their search_vault summary). Long files are truncated.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Vault-relative path, e.g. 'projects/acme-running-retail-concept/transcripts/notes/rti-session-20260622-1630.md'.",
                ] as [String: Any],
            ] as [String: Any],
            "required": ["path"],
            "additionalProperties": false,
        ],
        execute: { argumentsJSON in
            let path = decodeField("path", from: argumentsJSON)
            return VaultFiles.read(relativePath: path)
        },
        runningStatus: "📄 Reading the document…"
    )

    private static let grepVault = LLMToolDefinition(
        name: "grep_vault",
        description: """
        Exact keyword search across the project's documents (case-insensitive \
        substring), returning matching files with the matching lines. The precise \
        complement to search_vault: use grep_vault when you want every literal \
        mention of a specific name, term, quote, or number ("staff", a person's \
        name, "¥500"); use search_vault when you want meaning-based relevance. \
        Focused on the current project when one is set.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The literal term or phrase to find, e.g. 'store staff' or 'no-pad'.",
                ] as [String: Any],
            ] as [String: Any],
            "required": ["query"],
            "additionalProperties": false,
        ],
        execute: { argumentsJSON in
            let query = decodeField("query", from: argumentsJSON)
            return VaultFiles.grep(query: query, scopeRelativePath: MeetingContextStore.shared.workstreamScopePath)
        },
        runningStatus: "🔦 Grepping the vault…"
    )

    private static let listFiles = LLMToolDefinition(
        name: "list_files",
        description: """
        List the documents in the current project (or the whole vault if none is \
        set), optionally filtered by a substring of the path. Use to see what \
        material exists — "what transcripts/meetings/reports do we have" — before \
        reading or searching. Pass a pattern like 'transcript' or 'report' to \
        narrow.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "Optional path substring filter, e.g. 'transcript', 'meeting', 'report'. Omit to list everything.",
                ] as [String: Any],
            ] as [String: Any],
            "additionalProperties": false,
        ],
        execute: { argumentsJSON in
            let pattern = decodeField("pattern", from: argumentsJSON)
            return VaultFiles.list(scopeRelativePath: MeetingContextStore.shared.workstreamScopePath,
                                   pattern: pattern.isEmpty ? nil : pattern)
        },
        runningStatus: "🗂️ Listing files…"
    )

    /// Pull a named string field out of tool-call arguments JSON. Tolerant: a
    /// bare string or malformed JSON falls back to the raw argument text.
    private static func decodeField(_ key: String, from argumentsJSON: String) -> String {
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj[key] as? String {
            return v
        }
        return argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

extension ToolExecutor {
    static var production: ToolExecutor {
        // The model otherwise fires several refining vault searches in one turn
        // (observed: 5), each a full query. Allow one, then make it answer from
        // what it already got.
        ToolExecutor(tools: LLMToolRegistry.all, maxCallsPerTurn: ["search_vault": 1])
    }
}
