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

    func generate(sessionId: String) async {
        guard !isGenerating else { return }

        let transcript = TranscriptContext.text(forSessionId: sessionId)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true
        lastError = nil
        defer { isGenerating = false }

        let fullPrompt = Self.dossierPrompt + "\n" + trimmed
        let messages = [LLMMessage(role: "user", content: fullPrompt)]

        guard let response = await request.collectAsync(messages: messages, smart: true),
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Dossier generation returned empty response."
            return
        }

        let parsed = Self.parseDossiers(from: response)
        guard !parsed.isEmpty else {
            lastError = "Could not parse dossier response."
            return
        }

        merge(parsed)
    }

    private func merge(_ incoming: [EntityDossier]) {
        var existingByName: [String: EntityDossier] = [:]
        for d in dossiers {
            existingByName[d.normalizedName] = d
        }

        var updated: [EntityDossier] = []
        for incomingDossier in incoming {
            let key = incomingDossier.normalizedName
            if var existing = existingByName[key] {
                existing.mentions += 1
                // Keep the newer description if it's longer/more detailed.
                if incomingDossier.description.count > existing.description.count {
                    existing = EntityDossier(
                        id: existing.id,
                        name: existing.name,
                        type: incomingDossier.type,
                        description: incomingDossier.description,
                        mentions: existing.mentions,
                        firstMentionedMs: existing.firstMentionedMs
                    )
                }
                existingByName[key] = existing
            } else {
                existingByName[key] = incomingDossier
            }
        }

        // Preserve stable ordering: existing first, then new ones appended.
        var seen: Set<String> = []
        for d in dossiers {
            if let updatedD = existingByName[d.normalizedName], !seen.contains(d.normalizedName) {
                updated.append(updatedD)
                seen.insert(d.normalizedName)
            }
        }
        for d in incoming where !seen.contains(d.normalizedName) {
            updated.append(d)
            seen.insert(d.normalizedName)
        }

        dossiers = updated
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
                    description: r.description,
                    mentions: 1,
                    firstMentionedMs: 0
                )
            }
        } catch {
            NSLog("[RTI] Dossier JSON parse failed: \(error)")
            return []
        }
    }
}
