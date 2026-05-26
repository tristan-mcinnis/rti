import Foundation

/// Translates a natural-language panel description into a typed
/// `PanelConfig` by asking a sub-LLM for strict JSON. Extracted from
/// `LLMTools` so the tool registry stays focused on registration and
/// discovery; panel spawning gets its own test surface.
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
        You are a translator from natural-language panel descriptions to a strict JSON shape. Return raw JSON only — no prose, no code fences.

        counter (live keyword/regex match against the transcript):
        { "kind": "counter",
          "label": "Short display label (≤30 chars)",
          "match": { "type": "keyword", "value": "exact term", "caseInsensitive": true } }
        or
        { "kind": "counter",
          "label": "Short label",
          "match": { "type": "regex", "pattern": "valid NSRegularExpression pattern" } }

        Constraints:
        - Prefer "keyword" unless the user asks for a pattern.
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
            return TranslatedConfig(kind: kind, payload: PanelConfig(counter: cfg))
        }
    }
}
