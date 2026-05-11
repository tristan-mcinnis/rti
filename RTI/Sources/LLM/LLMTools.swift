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
        and a vision model to return a description plus any visible text. \
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

/// Translates a natural-language panel description into a typed
/// `PanelConfig` by asking a sub-LLM for strict JSON. Kept separate from
/// the tool registry so the parsing/validation logic has a clean home.
@MainActor
enum PanelSpawner {

    /// Top-level entry point used by the `spawn_panel` tool. Returns the
    /// status string the model will see as the tool's result so it can
    /// confirm to the user (or report the failure mode).
    static func spawn(fromDescription description: String) async -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "I need a description of the panel you want to spawn."
        }
        // Soft cap so a session doesn't accumulate dozens of live windows
        // that all hammer the API in parallel.
        if UserPanelStore.shared.panels.count >= 8 {
            return "Panel limit reached (8). Remove one before spawning another."
        }
        do {
            let config = try await translate(description: trimmed)
            let panel = UserPanel(
                id: UUID().uuidString,
                kind: config.kind,
                config: config.payload,
                createdAt: Date()
            )
            UserPanelStore.shared.add(panel)
            if panel.kind == .periodicCards {
                PeriodicCardsController.shared.registerNewPanel(panel)
            }
            return "Spawned \(panel.kind.rawValue) panel \"\(panel.displayTitle)\"."
        } catch SpawnError.invalidJSON(let raw) {
            return "Couldn't design a valid panel config — model returned:\n\(raw.prefix(400))"
        } catch SpawnError.unknownKind(let kind) {
            return "Couldn't design panel: unknown kind \"\(kind)\"."
        } catch {
            return "Couldn't design panel: \(error.localizedDescription)"
        }
    }

    private struct TranslatedConfig {
        let kind: PanelKind
        let payload: PanelConfig
    }

    private enum SpawnError: Error {
        case invalidJSON(raw: String)
        case unknownKind(String)
    }

    /// Sub-LLM call: strict JSON output matching one of the two panel
    /// schemas. We deliberately do *not* set `smart: true` — the model
    /// only needs to pattern-match the description against two templates,
    /// and we want fast responses so the panel appears within seconds.
    private static func translate(description: String) async throws -> TranslatedConfig {
        let systemPrompt = """
        You are a translator from natural-language panel descriptions to one of two strict JSON shapes. Return raw JSON only — no prose, no code fences.

        Shape A — counter (live keyword/regex match against the transcript):
        { "kind": "counter",
          "label": "Short display label (≤30 chars)",
          "match": { "type": "keyword", "value": "exact term", "caseInsensitive": true } }
        or
        { "kind": "counter",
          "label": "Short label",
          "match": { "type": "regex", "pattern": "valid NSRegularExpression pattern" } }

        Shape B — periodic_cards (LLM re-runs a prompt every interval and appends cards):
        { "kind": "periodic_cards",
          "label": "Short display label",
          "prompt": "Concise instruction for the analyst LLM. Tell it the structure of the cards it should produce.",
          "intervalSeconds": 120 }

        Constraints:
        - intervalSeconds must be between 60 and 600.
        - For counter: prefer "keyword" unless the user asks for a pattern.
        - Always return JSON. Never apologise. Never wrap in markdown.
        """

        let user = "User description: \(description)"
        let messages: [LLMMessage] = [
            LLMMessage(role: "system", content: systemPrompt),
            LLMMessage(role: "user", content: user)
        ]
        let request = LLMRequest()
        guard let raw = await request.collectAsync(messages: messages, smart: false) else {
            throw SpawnError.invalidJSON(raw: "<empty response>")
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences in case the model ignored the instruction.
        if text.hasPrefix("```") {
            if let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            if text.hasSuffix("```") {
                text = String(text.prefix(text.count - 3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8) else {
            throw SpawnError.invalidJSON(raw: text)
        }
        // Discriminate on the `kind` field, then decode the matching
        // sub-payload. Using JSONSerialization first because the
        // higher-level decoders can't cleanly route by a single key.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = obj["kind"] as? String else {
            throw SpawnError.invalidJSON(raw: text)
        }
        guard let kind = PanelKind(rawValue: kindRaw) else {
            throw SpawnError.unknownKind(kindRaw)
        }
        switch kind {
        case .counter:
            let cfg = try JSONDecoder().decode(CounterConfig.self, from: data)
            return TranslatedConfig(kind: kind, payload: PanelConfig(counter: cfg, periodicCards: nil))
        case .periodicCards:
            let cfg = try JSONDecoder().decode(PeriodicCardsConfig.self, from: data)
            return TranslatedConfig(kind: kind, payload: PanelConfig(counter: nil, periodicCards: cfg))
        }
    }
}
