import Foundation
import Observation

/// Periodically extracts notable entities (people, brands, orgs, concepts)
/// from the live transcript. Ephemeral: dossiers live in memory and merge in
/// place across ticks (the `merge()` dedup replaces what a DB unique index
/// used to do). The end-of-session `SessionArchive` writes the final set.
@Observable @MainActor
final class DossierController {
    static let shared = DossierController()

    private(set) var dossiers: [EntityDossier] = []
    var isGenerating = false
    private(set) var lastError: String?

    private let request = LLMRequest()
    private var sessionId: String?

    private static let dossierPrompt = """
    You are an AI research assistant. Below is a meeting transcript.

    Extract notable entities (people, brands, companies, products, concepts) that have been mentioned. For each entity, provide:
    - name: the entity name (use the most common form mentioned)
    - type: one of [person, brand, organization, concept]
    - description: 1-2 sentences explaining what this entity is and why it matters in this conversation

    Rules:
    - Only include entities that are genuinely significant to the discussion. Skip throwaway mentions, filler nouns, and generic concepts ("the meeting", "the team").
    - For bilingual conversations, use a single canonical name per entity in the form "English Name（本地名）", e.g. "Glico（格力高）". Never create separate entities for the same thing in different languages.
    - If an existing dossier already uses a name, reuse that exact name — don't introduce a variant.
    - Descriptions should read like something an analyst would copy into a report: specific, factual, anchored to what was said.
    - Max 8 entities per response.

    Format your response as a JSON array of objects with keys "name", "type", "description". Do not wrap the JSON in markdown code blocks — return raw JSON only.

    Transcript:
    """

    private init() {}

    /// Bind to a session and drop any prior dossiers.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        dossiers = []
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
    /// re-sending the entire growing transcript on every cycle.
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        guard !isGenerating else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        lastError = nil

        // The model needs to know about the entities we already track so it
        // can return strictly NEW or significantly-updated ones — without
        // this hint it tends to repeat the existing list verbatim.
        let knownClause: String = {
            guard !dossiers.isEmpty else { return "" }
            let existing = dossiers.map { "- \($0.name) (\($0.type.rawValue))" }.joined(separator: "\n")
            return "\nEntities already tracked (only return NEW ones, or ones whose description should be expanded):\n\(existing)\n"
        }()

        let result = await TranscriptAnalysis.run(
            sessionId: sessionId,
            sinceMs: sinceMs,
            smart: true,
            request: request,
            category: "dossiers",
            as: [RawDossier].self,
            buildPrompt: { Self.dossierPrompt + knownClause + "\nNew transcript window:\n" + $0 }
        )

        guard let result else {
            // Empty / parse fail / cancelled — leave watermark unchanged.
            return nil
        }

        let parsed = result.payload.compactMap { $0.toDossier() }
        if !parsed.isEmpty {
            merge(parsed)
        }
        return result.endMs
    }

    /// Merges a fresh batch into the running dossier list. Existing entries
    /// are preserved (with their stable id and ordering); newcomers are
    /// appended. When the same entity reappears with a longer description,
    /// the description is upgraded — but the id and position never move.
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
}

/// Wire shape for the dossier JSON. Lowercased `type` is mapped to the
/// `EntityType` enum at materialization time.
private struct RawDossier: Decodable {
    let name: String
    let type: String
    let description: String

    func toDossier() -> EntityDossier? {
        guard let type = EntityType(rawValue: type.lowercased()) else { return nil }
        return EntityDossier(id: UUID(), name: name, type: type, description: description)
    }
}
