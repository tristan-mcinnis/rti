import Foundation
import GRDB
import Observation

@Observable @MainActor
final class DossierController: AnalysisController {
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

    /// Load any existing dossiers for the session from the database.
    /// Called when a session begins (start of recording) and when the user
    /// switches to a past session in the detail view.
    func reset(for sessionId: String) {
        self.sessionId = sessionId
        lastError = nil
        isGenerating = false
        dossiers = Self.loadDossiers(forSessionId: sessionId)
    }

    /// Drop the in-memory cursor + cached dossiers without touching the
    /// database. Use when the active session is unloaded.
    func clear() {
        sessionId = nil
        dossiers = []
        lastError = nil
        isGenerating = false
    }

    /// Read the persisted dossiers for an arbitrary session, ordered by
    /// first creation. Used by `reset(for:)` and by tools/views that want
    /// dossiers without going through the singleton's mutable state.
    nonisolated static func loadDossiers(forSessionId sessionId: String) -> [EntityDossier] {
        SessionAnalysisStore.loadAll(EntityDossierRow.self, sessionId: sessionId, category: "dossier")
            .compactMap { row -> EntityDossier? in
                guard let type = EntityType(rawValue: row.type) else { return nil }
                return EntityDossier(
                    id: UUID(uuidString: row.id) ?? UUID(),
                    name: row.name,
                    type: type,
                    description: row.description
                )
            }
    }

    /// Generate dossiers from the transcript window starting at `sinceMs`
    /// (or from the start of the session when nil). Returns the `endMs`
    /// watermark of the processed window so the caller can advance and avoid
    /// re-sending the entire growing transcript on every cycle.
    func generate(sessionId: String, sinceMs: Int? = nil) async -> Int? {
        await withGenerationGuard {
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
                persistAll(sessionId: sessionId)
            }
            return result.endMs
        }
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

    /// Upsert every in-memory dossier into the database for `sessionId`.
    /// The schema's `(session_id, name_normalized)` unique index makes this
    /// idempotent: re-running upgrades the description in place.
    private func persistAll(sessionId: String) {
        let now = Date()
        let snapshot = dossiers
        do {
            try RTIDatabase.shared.pool.write { db in
                for d in snapshot {
                    try db.execute(sql: """
                        INSERT INTO entity_dossiers
                          (id, session_id, name, name_normalized, type, description, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_id, name_normalized) DO UPDATE SET
                          name = excluded.name,
                          type = excluded.type,
                          description = excluded.description,
                          updated_at = excluded.updated_at
                        """, arguments: [
                            d.id.uuidString,
                            sessionId,
                            d.name,
                            d.normalizedName,
                            d.type.rawValue,
                            d.description,
                            now,
                            now
                        ])
                }
            }
        } catch {
            RTILog.log("persist entity_dossiers failed: \(error)", category: "dossier")
        }
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
