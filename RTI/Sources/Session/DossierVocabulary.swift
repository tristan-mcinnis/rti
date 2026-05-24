import Foundation
import GRDB

/// Pulls proper nouns the user has encountered in past meetings — the names,
/// brands, and organizations RTI already extracted into `entity_dossiers` —
/// to feed Soniox as `context.terms`. Closing the loop: entities surfaced by
/// analysis bias transcription of those same entities next time.
enum DossierVocabulary {
    /// Soniox caps the whole context at ~8,000 tokens / ~10,000 chars; names
    /// are short, so a generous term cap plus a char budget keeps us clear.
    private static let maxTerms = 400
    private static let maxChars = 8_000

    /// One name per distinct entity (normalised), most-recently-seen first so
    /// truncation drops the stalest names. Empty on any failure — biasing is
    /// best-effort and must never block a recording from starting.
    static func terms(pool: DatabasePool) -> [String] {
        let names: [String]
        do {
            names = try pool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT name FROM entity_dossiers
                    GROUP BY name_normalized
                    ORDER BY MAX(updated_at) DESC
                    """)
            }
        } catch {
            RTILog.log("DossierVocabulary: query failed: \(error)", category: "soniox")
            return []
        }

        var result: [String] = []
        var charCount = 0
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.count >= maxTerms || charCount + trimmed.count > maxChars { break }
            result.append(trimmed)
            charCount += trimmed.count
        }
        return result
    }
}
