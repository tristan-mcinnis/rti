import Foundation

@MainActor
final class DossierController: ObservableObject {
    static let shared = DossierController()

    @Published private(set) var dossiers: [EntityDossier] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?

    private let request = LLMRequest()
    private var sessionId: String?

    private static let dossierPrompt = """
    You are an AI research assistant. Below is a meeting transcript.

    Extract notable entities (people, brands, companies, products, concepts) that have been mentioned. For each entity, provide:
    - name: the entity name (use the most common form mentioned)
    - type: one of [person, brand, organization, concept]
    - description: 1-2 sentences explaining what this entity is and why it matters in this conversation

    Format your response as a JSON array of objects with keys "name", "type", "description". Only include entities that are genuinely significant to the discussion. Do not wrap the JSON in markdown code blocks — return raw JSON only.

    Transcript:
    """

    private init() {}

    func reset(for sessionId: String) {
        self.sessionId = sessionId
        dossiers = []
        lastError = nil
        isGenerating = false
    }

    func clear() {
        sessionId = nil
        dossiers = []
        lastError = nil
        isGenerating = false
    }

    /// Generate dossiers from the transcript window starting at `sinceMs`
    /// (or from the start of the session when nil). Returns the `endMs`
    /// watermark of the processed window so the caller can advance and avoid
    /// re-sending the entire growing transcript on every cycle. Without
    /// windowing, a long meeting re-sends an ever-larger transcript every
    /// 2 minutes and the token cost grows quadratically.
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        guard !isGenerating else { return nil }

        let transcript = TranscriptContext.text(forSessionId: sessionId, sinceMs: sinceMs)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        // The model needs to know about the entities we already track so it
        // can return strictly NEW or significantly-updated ones — without
        // this hint it tends to repeat the existing list verbatim.
        let knownClause: String = {
            guard !dossiers.isEmpty else { return "" }
            let existing = dossiers.map { "- \($0.name) (\($0.type.rawValue))" }.joined(separator: "\n")
            return "\nEntities already tracked (only return NEW ones, or ones whose description should be expanded):\n\(existing)\n"
        }()

        let fullPrompt = Self.dossierPrompt + knownClause + "\nNew transcript window:\n" + trimmed
        let messages = [LLMMessage(role: "user", content: fullPrompt)]

        guard let response = await request.collectAsync(messages: messages, smart: true),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Dossier generation returned empty response."
            return nil
        }

        let parsed = Self.parseDossiers(from: response)
        if !parsed.isEmpty { merge(parsed) }

        // Watermark = end of the window we just processed, so the next
        // cycle picks up only fresh transcript.
        let entries = CorpusBackedStore.transcripts(forSessionId: sessionId)
        let filtered = sinceMs.map { s in entries.filter { $0.startMs >= s } } ?? entries
        return filtered.last?.startMs ?? entries.last?.startMs ?? 0
    }

    /// Merges a fresh batch into the running dossier list. Existing entries
    /// are preserved (with their stable id and ordering); newcomers are
    /// appended. When the same entity reappears with a longer description,
    /// the description is upgraded — but the id and position never move so
    /// downstream persistence (rowid-keyed) stays stable.
    private func merge(_ incoming: [EntityDossier]) {
        var byKey: [String: EntityDossier] = [:]
        var order: [String] = []
        for d in dossiers {
            byKey[d.normalizedName] = d
            order.append(d.normalizedName)
        }
        for fresh in incoming {
            let key = fresh.normalizedName
            if let existing = byKey[key] {
                if fresh.description.count > existing.description.count {
                    byKey[key] = EntityDossier(
                        id: existing.id,
                        name: existing.name,
                        type: existing.type,
                        description: fresh.description
                    )
                }
            } else {
                byKey[key] = fresh
                order.append(key)
            }
        }
        dossiers = order.compactMap { byKey[$0] }
    }

    nonisolated static func parseDossiers(from raw: String) -> [EntityDossier] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present.
        if text.hasPrefix("```") {
            if let start = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: start)...])
            }
            if text.hasSuffix("```") {
                text = String(text.prefix(text.count - 3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = text.data(using: .utf8) else { return [] }

        struct RawDossier: Decodable {
            let name: String
            let type: String
            let description: String
        }

        do {
            let decoded = try JSONDecoder().decode([RawDossier].self, from: data)
            return decoded.compactMap { r -> EntityDossier? in
                guard let type = EntityType(rawValue: r.type.lowercased()) else { return nil }
                return EntityDossier(
                    id: UUID(),
                    name: r.name,
                    type: type,
                    description: r.description
                )
            }
        } catch {
            NSLog("[RTI] Dossier JSON parse failed: \(error)")
            return []
        }
    }
}
